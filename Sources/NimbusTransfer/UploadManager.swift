import Foundation
import NimbusNetworkCore

/// Strategy hook for server-cooperative resumable uploads.
public protocol ResumableUploadStrategy {
    func resumeRequest(
        for originalRequest: URLRequest,
        fileURL: URL,
        uploadedBytes: Int64
    ) async throws -> URLRequest?
}

/// Default upload strategy that falls back to retrying full-file uploads.
public struct DefaultResumableUploadStrategy: ResumableUploadStrategy {
    public init() {}

    public func resumeRequest(
        for originalRequest: URLRequest,
        fileURL: URL,
        uploadedBytes: Int64
    ) async throws -> URLRequest? {
        nil
    }
}

/// Configuration for `UploadManager`.
public struct UploadManagerConfiguration {
    public let sessionIdentifier: String
    public let retryPolicy: RetryPolicy?
    public let sessionClient: any UploadSessionClient
    public let resumableUploadStrategy: any ResumableUploadStrategy
    public let sleeper: any TaskSleeping
    public let randomSource: any RandomnessSource

    public init(
        sessionIdentifier: String = "com.nimbus.transfer.upload",
        retryPolicy: RetryPolicy? = nil,
        sessionClient: (any UploadSessionClient)? = nil,
        resumableUploadStrategy: any ResumableUploadStrategy = DefaultResumableUploadStrategy(),
        sleeper: any TaskSleeping = DefaultTaskSleeper(),
        randomSource: any RandomnessSource = SystemRandomnessSource()
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.retryPolicy = retryPolicy
        self.sessionClient = sessionClient ?? URLSessionUploadClient(identifier: sessionIdentifier)
        self.resumableUploadStrategy = resumableUploadStrategy
        self.sleeper = sleeper
        self.randomSource = randomSource
    }
}

/// Background-capable upload manager with retry, progress, and resumable-strategy hooks.
public final class UploadManager {
    private final class Record {
        let id: UUID
        let fileURL: URL
        let endpoint: any Endpoint
        let baseRequest: URLRequest
        let retryPolicy: RetryPolicy?
        let resumableUploadStrategy: any ResumableUploadStrategy
        let continuation: AsyncStream<TransferProgress>.Continuation

        var status: TransferTaskStatus
        var currentTaskID: Int
        var attempt: Int
        var lastUploadedBytes: Int64

        init(
            id: UUID,
            fileURL: URL,
            endpoint: any Endpoint,
            baseRequest: URLRequest,
            retryPolicy: RetryPolicy?,
            resumableUploadStrategy: any ResumableUploadStrategy,
            continuation: AsyncStream<TransferProgress>.Continuation,
            taskID: Int
        ) {
            self.id = id
            self.fileURL = fileURL
            self.endpoint = endpoint
            self.baseRequest = baseRequest
            self.retryPolicy = retryPolicy
            self.resumableUploadStrategy = resumableUploadStrategy
            self.continuation = continuation
            self.status = .queued
            self.currentTaskID = taskID
            self.attempt = 1
            self.lastUploadedBytes = 0
        }
    }

    private let configuration: UploadManagerConfiguration
    private let queue = DispatchQueue(label: "com.nimbus.transfer.upload.manager")

    private var records: [UUID: Record] = [:]
    private var taskToRecord: [Int: UUID] = [:]
    private var pausedTaskIDs: Set<Int> = []
    private var cancelledTaskIDs: Set<Int> = []

    public init(configuration: UploadManagerConfiguration = UploadManagerConfiguration()) {
        self.configuration = configuration

        self.configuration.sessionClient.eventHandler = { [weak self] event in
            self?.handle(event)
        }
        self.configuration.sessionClient.backgroundEventsDidFinish = { [weak self] in
            guard let self else { return }
            NimbusBackgroundEvents.shared.completeEvents(for: self.configuration.sessionIdentifier)
        }
    }

    @discardableResult
    public func startUpload(
        fileURL: URL,
        to endpoint: any Endpoint,
        retryPolicy: RetryPolicy? = nil,
        resumableUploadStrategy: (any ResumableUploadStrategy)? = nil
    ) -> UploadTaskHandle {
        let id = UUID()
        var continuation: AsyncStream<TransferProgress>.Continuation!
        let progressStream = AsyncStream<TransferProgress> { continuation = $0 }

        let request: URLRequest
        do {
            request = try buildRequest(for: endpoint)
        } catch {
            continuation.finish()
            return UploadTaskHandle(
                id: id,
                progressStream: progressStream,
                statusProvider: { .failed },
                cancelHandler: {},
                pauseHandler: {},
                resumeHandler: {}
            )
        }

        let taskID = configuration.sessionClient.createUploadTask(request: request, fileURL: fileURL)

        let record = Record(
            id: id,
            fileURL: fileURL,
            endpoint: endpoint,
            baseRequest: request,
            retryPolicy: retryPolicy ?? configuration.retryPolicy,
            resumableUploadStrategy: resumableUploadStrategy ?? configuration.resumableUploadStrategy,
            continuation: continuation,
            taskID: taskID
        )

        queue.sync {
            record.status = .running
            records[id] = record
            taskToRecord[taskID] = id
        }

        configuration.sessionClient.resume(taskID: taskID)

        return UploadTaskHandle(
            id: id,
            progressStream: progressStream,
            statusProvider: { [weak self] in
                self?.status(for: id) ?? .failed
            },
            cancelHandler: { [weak self] in
                self?.cancel(taskID: id)
            },
            pauseHandler: { [weak self] in
                self?.pause(taskID: id)
            },
            resumeHandler: { [weak self] in
                self?.resume(taskID: id)
            }
        )
    }

    public func cancel(taskID id: UUID) {
        queue.async {
            guard let record = self.records[id] else { return }
            self.cancelledTaskIDs.insert(record.currentTaskID)
            record.status = .cancelled
            self.configuration.sessionClient.cancel(taskID: record.currentTaskID)
            record.continuation.finish()
        }
    }

    public func pause(taskID id: UUID) {
        queue.async {
            guard let record = self.records[id], record.status == .running else { return }
            self.pausedTaskIDs.insert(record.currentTaskID)
            record.status = .paused
            self.configuration.sessionClient.cancel(taskID: record.currentTaskID)
        }
    }

    public func resume(taskID id: UUID) {
        queue.async {
            self.restartUpload(for: id)
        }
    }

    public func status(for id: UUID) -> TransferTaskStatus {
        queue.sync {
            records[id]?.status ?? .failed
        }
    }

    private func restartUpload(for id: UUID, request overrideRequest: URLRequest? = nil) {
        guard let record = records[id] else { return }
        guard record.status == .paused || record.status == .failed || record.status == .queued else {
            return
        }

        let request = overrideRequest ?? record.baseRequest
        let taskID = configuration.sessionClient.createUploadTask(request: request, fileURL: record.fileURL)
        taskToRecord[taskID] = id
        record.currentTaskID = taskID
        record.status = .running
        configuration.sessionClient.resume(taskID: taskID)
    }

    private func handle(_ event: UploadSessionEvent) {
        queue.async {
            switch event {
            case let .progress(taskID, _, totalBytesSent, totalBytesExpected):
                self.handleProgress(taskID: taskID, totalBytesSent: totalBytesSent, totalBytesExpected: totalBytesExpected)
            case let .completed(taskID, response, data, error):
                self.handleCompletion(taskID: taskID, response: response, data: data, error: error)
            }
        }
    }

    private func handleProgress(taskID: Int, totalBytesSent: Int64, totalBytesExpected: Int64) {
        guard let id = taskToRecord[taskID], let record = records[id] else { return }
        record.lastUploadedBytes = totalBytesSent
        let expected = totalBytesExpected > 0 ? totalBytesExpected : nil
        record.continuation.yield(.init(completedBytes: totalBytesSent, totalBytes: expected))
    }

    private func handleCompletion(taskID: Int, response: HTTPURLResponse?, data: Data?, error: Error?) {
        guard let id = taskToRecord.removeValue(forKey: taskID), let record = records[id] else { return }

        if cancelledTaskIDs.remove(taskID) != nil {
            record.status = .cancelled
            record.continuation.finish()
            return
        }

        if pausedTaskIDs.remove(taskID) != nil {
            record.status = .paused
            return
        }

        if let error {
            if shouldRetry(record: record, error: error, statusCode: nil) {
                record.status = .failed
                scheduleRetry(for: record.id)
                return
            }
            record.status = .failed
            record.continuation.finish()
            return
        }

        if let statusCode = response?.statusCode,
           !(200...299).contains(statusCode) {
            if shouldRetry(record: record, error: nil, statusCode: statusCode) {
                record.status = .failed
                scheduleRetry(for: record.id)
                return
            }
            record.status = .failed
            record.continuation.finish()
            return
        }

        if let responseData = data, !responseData.isEmpty {
            _ = responseData
        }

        record.status = .completed
        record.continuation.yield(.init(completedBytes: record.lastUploadedBytes, totalBytes: record.lastUploadedBytes))
        record.continuation.finish()
    }

    private func scheduleRetry(for id: UUID) {
        guard let record = records[id],
              let retryPolicy = record.retryPolicy else {
            return
        }

        let delay = retryPolicy.delay(forAttempt: record.attempt, randomSource: configuration.randomSource)
        record.attempt += 1
        let baseRequest = record.baseRequest
        let fileURL = record.fileURL
        let uploadedBytes = record.lastUploadedBytes
        let strategy = record.resumableUploadStrategy

        Task { [weak self] in
            guard let self else { return }
            await self.configuration.sleeper.sleep(seconds: delay)

            let resumedRequest = try? await strategy.resumeRequest(
                for: baseRequest,
                fileURL: fileURL,
                uploadedBytes: uploadedBytes
            )

            self.queue.async {
                self.restartUpload(for: id, request: resumedRequest)
            }
        }
    }

    private func shouldRetry(record: Record, error: Error?, statusCode: Int?) -> Bool {
        guard let retryPolicy = record.retryPolicy else { return false }

        if let statusCode,
           retryPolicy.shouldRetry(statusCode: statusCode, attempt: record.attempt) {
            return true
        }

        if let error,
           retryPolicy.shouldRetry(error: error, attempt: record.attempt) {
            return true
        }

        return false
    }

    private func buildRequest(for endpoint: any Endpoint) throws -> URLRequest {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty {
            components.path = endpointPath.isEmpty ? "/" : "/\(endpointPath)"
        } else if endpointPath.isEmpty {
            components.path = "/\(basePath)"
        } else {
            components.path = "/\(basePath)/\(endpointPath)"
        }

        components.queryItems = endpoint.queryItems.isEmpty ? nil : endpoint.queryItems

        guard let url = components.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.cachePolicy = endpoint.cachePolicy

        if let timeout = endpoint.timeout {
            request.timeoutInterval = timeout
        }

        for (header, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: header)
        }

        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue(endpoint.contentType ?? HTTPContentType.octetStream, forHTTPHeaderField: "Content-Type")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil, let accept = endpoint.accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }

        return request
    }
}

extension UploadManager: @unchecked Sendable {}
