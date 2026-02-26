import Foundation
import NimbusNetworkCore

/// Configuration for `DownloadManager`.
public struct DownloadManagerConfiguration {
    public let sessionIdentifier: String
    public let retryPolicy: RetryPolicy?
    public let sessionClient: any DownloadSessionClient
    public let sleeper: any TaskSleeping
    public let randomSource: any RandomnessSource
    public let fileManager: FileManager

    public init(
        sessionIdentifier: String = "com.nimbus.transfer.download",
        retryPolicy: RetryPolicy? = nil,
        sessionClient: (any DownloadSessionClient)? = nil,
        sleeper: any TaskSleeping = DefaultTaskSleeper(),
        randomSource: any RandomnessSource = SystemRandomnessSource(),
        fileManager: FileManager = .default
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.retryPolicy = retryPolicy
        self.sessionClient = sessionClient ?? URLSessionDownloadClient(identifier: sessionIdentifier)
        self.sleeper = sleeper
        self.randomSource = randomSource
        self.fileManager = fileManager
    }
}

/// Background-capable download manager with retry, pause/resume, and progress streaming.
public final class DownloadManager {
    private final class Record {
        let id: UUID
        let sourceURL: URL
        let destinationURL: URL
        let retryPolicy: RetryPolicy?
        let continuation: AsyncStream<TransferProgress>.Continuation

        var status: TransferTaskStatus
        var currentTaskID: Int
        var attempt: Int
        var resumeData: Data?
        var rangeStart: Int64
        var pendingLocation: URL?

        init(
            id: UUID,
            sourceURL: URL,
            destinationURL: URL,
            retryPolicy: RetryPolicy?,
            continuation: AsyncStream<TransferProgress>.Continuation,
            taskID: Int,
            rangeStart: Int64
        ) {
            self.id = id
            self.sourceURL = sourceURL
            self.destinationURL = destinationURL
            self.retryPolicy = retryPolicy
            self.continuation = continuation
            self.status = .queued
            self.currentTaskID = taskID
            self.attempt = 1
            self.rangeStart = rangeStart
        }
    }

    private let configuration: DownloadManagerConfiguration
    private let queue = DispatchQueue(label: "com.nimbus.transfer.download.manager")

    private var records: [UUID: Record] = [:]
    private var taskToRecord: [Int: UUID] = [:]
    private var pausedTaskIDs: Set<Int> = []
    private var cancelledTaskIDs: Set<Int> = []

    public init(configuration: DownloadManagerConfiguration = DownloadManagerConfiguration()) {
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
    public func startDownload(url: URL, destination: URL, retryPolicy: RetryPolicy? = nil) -> DownloadTaskHandle {
        let id = UUID()
        var continuation: AsyncStream<TransferProgress>.Continuation!
        let progressStream = AsyncStream<TransferProgress> { continuation = $0 }

        let rangeStart = existingFileSize(at: destination)
        let taskID: Int
        if rangeStart > 0 {
            var request = URLRequest(url: url)
            request.setValue("bytes=\(rangeStart)-", forHTTPHeaderField: "Range")
            taskID = configuration.sessionClient.createDownloadTask(with: request)
        } else {
            taskID = configuration.sessionClient.createDownloadTask(from: url)
        }

        let record = Record(
            id: id,
            sourceURL: url,
            destinationURL: destination,
            retryPolicy: retryPolicy ?? configuration.retryPolicy,
            continuation: continuation,
            taskID: taskID,
            rangeStart: rangeStart
        )

        queue.sync {
            record.status = .running
            records[id] = record
            taskToRecord[taskID] = id
        }

        configuration.sessionClient.resume(taskID: taskID)

        return DownloadTaskHandle(
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
            let currentTaskID = record.currentTaskID
            self.configuration.sessionClient.pause(taskID: currentTaskID) { resumeData in
                self.queue.async {
                    record.resumeData = resumeData
                }
            }
        }
    }

    public func resume(taskID id: UUID) {
        queue.async {
            self.resumeInternal(taskID: id)
        }
    }

    public func status(for id: UUID) -> TransferTaskStatus {
        queue.sync {
            records[id]?.status ?? .failed
        }
    }

    private func resumeInternal(taskID id: UUID) {
        guard let record = records[id] else { return }
        guard record.status == .paused || record.status == .failed || record.status == .queued else {
            return
        }

        let newTaskID: Int
        if let resumeData = record.resumeData {
            newTaskID = configuration.sessionClient.createDownloadTask(with: resumeData)
            record.resumeData = nil
            record.rangeStart = existingFileSize(at: record.destinationURL)
        } else {
            let partialBytes = existingFileSize(at: record.destinationURL)
            if partialBytes > 0 {
                var request = URLRequest(url: record.sourceURL)
                request.setValue("bytes=\(partialBytes)-", forHTTPHeaderField: "Range")
                newTaskID = configuration.sessionClient.createDownloadTask(with: request)
                record.rangeStart = partialBytes
            } else {
                newTaskID = configuration.sessionClient.createDownloadTask(from: record.sourceURL)
                record.rangeStart = 0
            }
        }

        taskToRecord[newTaskID] = id
        record.currentTaskID = newTaskID
        record.status = .running
        configuration.sessionClient.resume(taskID: newTaskID)
    }

    private func handle(_ event: DownloadSessionEvent) {
        queue.async {
            switch event {
            case let .progress(taskID, _, totalBytesWritten, totalBytesExpected):
                self.handleProgress(taskID: taskID, totalBytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpected)
            case let .finished(taskID, location):
                self.handleFinished(taskID: taskID, location: location)
            case let .completed(taskID, error):
                self.handleCompleted(taskID: taskID, error: error)
            }
        }
    }

    private func handleProgress(taskID: Int, totalBytesWritten: Int64, totalBytesExpected: Int64) {
        guard let id = taskToRecord[taskID], let record = records[id] else { return }
        let adjustedCompleted = totalBytesWritten + record.rangeStart
        let adjustedTotal = totalBytesExpected > 0 ? totalBytesExpected + record.rangeStart : nil
        record.continuation.yield(.init(completedBytes: adjustedCompleted, totalBytes: adjustedTotal))
    }

    private func handleFinished(taskID: Int, location: URL) {
        guard let id = taskToRecord[taskID], let record = records[id] else { return }
        record.pendingLocation = location
    }

    private func handleCompleted(taskID: Int, error: Error?) {
        guard let id = taskToRecord.removeValue(forKey: taskID), let record = records[id] else { return }

        if cancelledTaskIDs.remove(taskID) != nil {
            record.status = .cancelled
            record.continuation.finish()
            return
        }

        if pausedTaskIDs.remove(taskID) != nil {
            if let resumeData = resumeData(from: error) {
                record.resumeData = resumeData
            }
            record.status = .paused
            return
        }

        if let error {
            if let resumeData = resumeData(from: error) {
                record.resumeData = resumeData
            }

            if shouldRetry(record: record, error: error) {
                record.status = .failed
                scheduleRetry(for: record.id)
                return
            }

            record.status = .failed
            record.continuation.finish()
            return
        }

        guard let location = record.pendingLocation else {
            record.status = .failed
            record.continuation.finish()
            return
        }

        do {
            try persistDownloadedFile(from: location, for: record)
            record.status = .completed
            let finalSize = existingFileSize(at: record.destinationURL)
            record.continuation.yield(.init(completedBytes: finalSize, totalBytes: finalSize))
            record.continuation.finish()
        } catch {
            if shouldRetry(record: record, error: error) {
                record.status = .failed
                scheduleRetry(for: record.id)
                return
            }
            record.status = .failed
            record.continuation.finish()
        }
    }

    private func scheduleRetry(for id: UUID) {
        guard let record = records[id],
              let retryPolicy = record.retryPolicy else {
            return
        }

        let delay = retryPolicy.delay(forAttempt: record.attempt, randomSource: configuration.randomSource)
        record.attempt += 1
        Task { [weak self] in
            guard let self else { return }
            await self.configuration.sleeper.sleep(seconds: delay)
            self.queue.async {
                self.resumeInternal(taskID: id)
            }
        }
    }

    private func shouldRetry(record: Record, error: Error) -> Bool {
        guard let retryPolicy = record.retryPolicy else { return false }

        if retryPolicy.shouldRetry(error: error, attempt: record.attempt) {
            return true
        }

        if let networkError = error as? NetworkError {
            return retryPolicy.shouldRetry(error: networkError, attempt: record.attempt)
        }

        return false
    }

    private func persistDownloadedFile(from location: URL, for record: Record) throws {
        let fileManager = configuration.fileManager
        let destination = record.destinationURL

        if record.rangeStart > 0,
           fileManager.fileExists(atPath: destination.path) {
            let appendData = try Data(contentsOf: location)
            guard let handle = try? FileHandle(forWritingTo: destination) else {
                throw NetworkError.backgroundTransfer(URLError(.cannotCreateFile))
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: appendData)
            try handle.close()
            try? fileManager.removeItem(at: location)
            return
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let destinationDirectory = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destinationDirectory.path) {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }
        try fileManager.moveItem(at: location, to: destination)
    }

    private func resumeData(from error: Error?) -> Data? {
        guard let nsError = error as NSError? else { return nil }
        return nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    }

    private func existingFileSize(at url: URL) -> Int64 {
        guard let attributes = try? configuration.fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }
}

extension DownloadManager: @unchecked Sendable {}
