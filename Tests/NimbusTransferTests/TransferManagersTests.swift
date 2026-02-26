import XCTest
@testable import NimbusTransfer
@testable import NimbusNetworkCore

final class TransferManagersTests: XCTestCase {
    struct UploadEndpoint: Endpoint {
        let baseURL: URL
        let path: String
        let method: HTTPMethod
        var headers: [String: String] = [:]
        var queryItems: [URLQueryItem] = []
        var timeout: TimeInterval? = nil
        var body: (any Encodable)? = nil
        var bodyData: Data? = nil
        var contentType: String? = HTTPContentType.octetStream
        var accept: String? = HTTPContentType.json
        var cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData
        var responseDecoder: JSONDecoder? = nil
        var requestEncoder: JSONEncoder? = nil
        var retryPolicy: RetryPolicy? = nil
    }

    final class ImmediateSleeper: TaskSleeping {
        func sleep(seconds: TimeInterval) async {}
    }

    struct ZeroRandom: RandomnessSource {
        func nextUnit() -> Double { 0.5 }
    }

    final class MockDownloadSessionClient: DownloadSessionClient {
        let identifier: String
        var eventHandler: (@Sendable (DownloadSessionEvent) -> Void)?
        var backgroundEventsDidFinish: (@Sendable () -> Void)?

        private(set) var createdURLTasks: [URL] = []
        private(set) var createdRequestTasks: [URLRequest] = []
        private(set) var createdResumeDataTasks: [Data] = []
        private(set) var resumedTaskIDs: [Int] = []
        private(set) var cancelledTaskIDs: [Int] = []
        private(set) var pausedTaskIDs: [Int] = []
        var pauseResumeData: Data? = Data("resume-data".utf8)

        private var nextTaskID = 1

        init(identifier: String = "download.test") {
            self.identifier = identifier
        }

        func createDownloadTask(from url: URL) -> Int {
            createdURLTasks.append(url)
            defer { nextTaskID += 1 }
            return nextTaskID
        }

        func createDownloadTask(with request: URLRequest) -> Int {
            createdRequestTasks.append(request)
            defer { nextTaskID += 1 }
            return nextTaskID
        }

        func createDownloadTask(with resumeData: Data) -> Int {
            createdResumeDataTasks.append(resumeData)
            defer { nextTaskID += 1 }
            return nextTaskID
        }

        func resume(taskID: Int) {
            resumedTaskIDs.append(taskID)
        }

        func cancel(taskID: Int) {
            cancelledTaskIDs.append(taskID)
        }

        func pause(taskID: Int, completion: @escaping (Data?) -> Void) {
            pausedTaskIDs.append(taskID)
            completion(pauseResumeData)
        }

        func emit(_ event: DownloadSessionEvent) {
            eventHandler?(event)
        }
    }

    final class MockUploadSessionClient: UploadSessionClient {
        let identifier: String
        var eventHandler: (@Sendable (UploadSessionEvent) -> Void)?
        var backgroundEventsDidFinish: (@Sendable () -> Void)?

        private(set) var createdRequests: [URLRequest] = []
        private(set) var createdFileURLs: [URL] = []
        private(set) var resumedTaskIDs: [Int] = []
        private(set) var cancelledTaskIDs: [Int] = []

        private var nextTaskID = 1

        init(identifier: String = "upload.test") {
            self.identifier = identifier
        }

        func createUploadTask(request: URLRequest, fileURL: URL) -> Int {
            createdRequests.append(request)
            createdFileURLs.append(fileURL)
            defer { nextTaskID += 1 }
            return nextTaskID
        }

        func resume(taskID: Int) {
            resumedTaskIDs.append(taskID)
        }

        func cancel(taskID: Int) {
            cancelledTaskIDs.append(taskID)
        }

        func emit(_ event: UploadSessionEvent) {
            eventHandler?(event)
        }
    }

    final class MockResumableStrategy: ResumableUploadStrategy {
        private(set) var capturedUploadedBytes: [Int64] = []
        var requestToReturn: URLRequest?

        func resumeRequest(for originalRequest: URLRequest, fileURL: URL, uploadedBytes: Int64) async throws -> URLRequest? {
            capturedUploadedBytes.append(uploadedBytes)
            return requestToReturn
        }
    }

    func testDownloadStartPauseResumeAndCancelFlow() async throws {
        let client = MockDownloadSessionClient()
        let manager = DownloadManager(
            configuration: .init(
                sessionIdentifier: client.identifier,
                retryPolicy: nil,
                sessionClient: client,
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom()
            )
        )

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("download-flow.bin")
        try? FileManager.default.removeItem(at: destination)

        let handle = manager.startDownload(url: URL(string: "https://example.com/file")!, destination: destination)

        XCTAssertEqual(handle.status, .running)
        XCTAssertEqual(client.createdURLTasks.count, 1)
        XCTAssertEqual(client.resumedTaskIDs, [1])

        handle.pause()
        try await waitUntil { handle.status == .paused }
        XCTAssertEqual(client.pausedTaskIDs, [1])

        handle.resume()
        try await waitUntil { client.createdResumeDataTasks.count == 1 }
        XCTAssertEqual(client.resumedTaskIDs, [1, 2])

        handle.cancel()
        try await waitUntil { handle.status == .cancelled }
        XCTAssertEqual(client.cancelledTaskIDs, [2])
    }

    func testDownloadProgressEmissionOrderAndCompletion() async throws {
        let client = MockDownloadSessionClient()
        let manager = DownloadManager(
            configuration: .init(
                sessionIdentifier: client.identifier,
                retryPolicy: nil,
                sessionClient: client,
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom()
            )
        )

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("download-progress.bin")
        try? FileManager.default.removeItem(at: destination)

        let handle = manager.startDownload(url: URL(string: "https://example.com/file")!, destination: destination)

        var progressEvents: [TransferProgress] = []
        let collector = Task {
            for await progress in handle.progressStream {
                progressEvents.append(progress)
            }
        }

        client.emit(.progress(taskID: 1, bytesWritten: 50, totalBytesWritten: 50, totalBytesExpected: 100))

        let tempLocation = FileManager.default.temporaryDirectory.appendingPathComponent("download-temp-\(UUID().uuidString)")
        try Data("abcdefghij".utf8).write(to: tempLocation)

        client.emit(.finished(taskID: 1, location: tempLocation))
        client.emit(.completed(taskID: 1, error: nil))

        _ = await collector.value

        XCTAssertEqual(progressEvents.first?.completedBytes, 50)
        XCTAssertEqual(progressEvents.first?.totalBytes, 100)
        XCTAssertEqual(progressEvents.last?.fractionCompleted, 1)
        XCTAssertEqual(handle.status, .completed)

        let downloadedData = try Data(contentsOf: destination)
        XCTAssertEqual(downloadedData, Data("abcdefghij".utf8))
    }

    func testDownloadRetryBehaviorForTransientFailure() async throws {
        let retryPolicy = RetryPolicy(
            maxAttempts: 2,
            retryableStatusCodes: [],
            retryableURLErrorCodes: [.networkConnectionLost],
            delayStrategy: ExponentialJitterBackoff(baseDelay: 0, maximumDelay: 0, jitterFactor: 0)
        )

        let client = MockDownloadSessionClient()
        let manager = DownloadManager(
            configuration: .init(
                sessionIdentifier: client.identifier,
                retryPolicy: retryPolicy,
                sessionClient: client,
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom()
            )
        )

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("download-retry.bin")
        try? FileManager.default.removeItem(at: destination)

        let handle = manager.startDownload(url: URL(string: "https://example.com/retry")!, destination: destination)

        client.emit(.completed(taskID: 1, error: URLError(.networkConnectionLost)))
        try await waitUntil { client.createdURLTasks.count + client.createdRequestTasks.count + client.createdResumeDataTasks.count >= 2 }

        let retryTaskID = client.resumedTaskIDs.last ?? 2
        let tempLocation = FileManager.default.temporaryDirectory.appendingPathComponent("download-retry-temp-\(UUID().uuidString)")
        try Data("retry-success".utf8).write(to: tempLocation)
        client.emit(.finished(taskID: retryTaskID, location: tempLocation))
        client.emit(.completed(taskID: retryTaskID, error: nil))

        try await waitUntil { handle.status == .completed }
        XCTAssertEqual(handle.status, .completed)
    }

    func testBackgroundEventHandlerRoutingForDownloadManager() {
        let client = MockDownloadSessionClient(identifier: "download.background")
        let manager = DownloadManager(
            configuration: .init(
                sessionIdentifier: client.identifier,
                retryPolicy: nil,
                sessionClient: client,
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom()
            )
        )

        let expectation = expectation(description: "Background completion handler called")
        NimbusBackgroundEvents.shared.handleEventsForBackgroundURLSession(identifier: client.identifier) {
            expectation.fulfill()
        }

        client.backgroundEventsDidFinish?()
        wait(for: [expectation], timeout: 1)
        _ = manager
    }

    func testUploadStartPauseResumeAndCancelFlow() async throws {
        let uploadClient = MockUploadSessionClient()
        let manager = UploadManager(
            configuration: .init(
                sessionIdentifier: uploadClient.identifier,
                retryPolicy: nil,
                sessionClient: uploadClient,
                resumableUploadStrategy: DefaultResumableUploadStrategy(),
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom()
            )
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-flow.bin")
        try Data("payload".utf8).write(to: fileURL)

        let endpoint = UploadEndpoint(baseURL: URL(string: "https://example.com")!, path: "upload", method: .post)
        let handle = manager.startUpload(fileURL: fileURL, to: endpoint)

        XCTAssertEqual(handle.status, .running)
        XCTAssertEqual(uploadClient.createdRequests.count, 1)

        handle.pause()
        try await waitUntil { handle.status == .paused }

        handle.resume()
        try await waitUntil { uploadClient.createdRequests.count == 2 }

        handle.cancel()
        try await waitUntil { handle.status == .cancelled }
        XCTAssertEqual(uploadClient.cancelledTaskIDs.last, 2)
    }

    func testUploadRetryAndResumableStrategyPath() async throws {
        let retryPolicy = RetryPolicy(
            maxAttempts: 2,
            retryableStatusCodes: [500],
            retryableURLErrorCodes: [.networkConnectionLost],
            delayStrategy: ExponentialJitterBackoff(baseDelay: 0, maximumDelay: 0, jitterFactor: 0)
        )

        let uploadClient = MockUploadSessionClient()
        let strategy = MockResumableStrategy()
        let manager = UploadManager(
            configuration: .init(
                sessionIdentifier: uploadClient.identifier,
                retryPolicy: retryPolicy,
                sessionClient: uploadClient,
                resumableUploadStrategy: strategy,
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom()
            )
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-retry.bin")
        try Data("retry-body".utf8).write(to: fileURL)

        let endpoint = UploadEndpoint(baseURL: URL(string: "https://example.com")!, path: "upload", method: .put)
        let handle = manager.startUpload(fileURL: fileURL, to: endpoint)

        uploadClient.emit(.progress(taskID: 1, bytesSent: 100, totalBytesSent: 100, totalBytesExpected: 200))

        var resumedRequest = URLRequest(url: URL(string: "https://example.com/upload")!)
        resumedRequest.httpMethod = "PUT"
        resumedRequest.setValue("100", forHTTPHeaderField: "Upload-Offset")
        strategy.requestToReturn = resumedRequest

        uploadClient.emit(.completed(taskID: 1, response: nil, data: nil, error: URLError(.networkConnectionLost)))
        try await waitUntil { uploadClient.createdRequests.count == 2 }

        XCTAssertEqual(strategy.capturedUploadedBytes, [100])
        XCTAssertEqual(uploadClient.createdRequests.last?.value(forHTTPHeaderField: "Upload-Offset"), "100")

        let successResponse = HTTPURLResponse(url: URL(string: "https://example.com/upload")!, statusCode: 201, httpVersion: nil, headerFields: nil)
        uploadClient.emit(.completed(taskID: 2, response: successResponse, data: Data(), error: nil))

        try await waitUntil { handle.status == .completed }
        XCTAssertEqual(handle.status, .completed)
    }

    func testUploadDefaultFallbackWhenResumeStrategyReturnsNil() async throws {
        let retryPolicy = RetryPolicy(
            maxAttempts: 2,
            retryableStatusCodes: [500],
            retryableURLErrorCodes: [.networkConnectionLost],
            delayStrategy: ExponentialJitterBackoff(baseDelay: 0, maximumDelay: 0, jitterFactor: 0)
        )

        let uploadClient = MockUploadSessionClient()
        let manager = UploadManager(
            configuration: .init(
                sessionIdentifier: uploadClient.identifier,
                retryPolicy: retryPolicy,
                sessionClient: uploadClient,
                resumableUploadStrategy: DefaultResumableUploadStrategy(),
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom()
            )
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-fallback.bin")
        try Data("fallback".utf8).write(to: fileURL)

        let endpoint = UploadEndpoint(baseURL: URL(string: "https://example.com")!, path: "upload", method: .post)
        _ = manager.startUpload(fileURL: fileURL, to: endpoint)

        uploadClient.emit(.completed(taskID: 1, response: nil, data: nil, error: URLError(.networkConnectionLost)))
        try await waitUntil { uploadClient.createdRequests.count == 2 }

        XCTAssertNil(uploadClient.createdRequests[1].value(forHTTPHeaderField: "Upload-Offset"))
        XCTAssertEqual(uploadClient.createdRequests[0].url, uploadClient.createdRequests[1].url)
    }

    func testUploadProgressStreamEmissionAndCompletion() async throws {
        let uploadClient = MockUploadSessionClient()
        let manager = UploadManager(
            configuration: .init(
                sessionIdentifier: uploadClient.identifier,
                retryPolicy: nil,
                sessionClient: uploadClient,
                resumableUploadStrategy: DefaultResumableUploadStrategy(),
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom()
            )
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-progress.bin")
        try Data("upload-progress".utf8).write(to: fileURL)

        let endpoint = UploadEndpoint(baseURL: URL(string: "https://example.com")!, path: "upload", method: .post)
        let handle = manager.startUpload(fileURL: fileURL, to: endpoint)

        var collected: [TransferProgress] = []
        let collector = Task {
            for await progress in handle.progressStream {
                collected.append(progress)
            }
        }

        uploadClient.emit(.progress(taskID: 1, bytesSent: 10, totalBytesSent: 10, totalBytesExpected: 20))
        uploadClient.emit(.progress(taskID: 1, bytesSent: 10, totalBytesSent: 20, totalBytesExpected: 20))

        let response = HTTPURLResponse(url: URL(string: "https://example.com/upload")!, statusCode: 200, httpVersion: nil, headerFields: nil)
        uploadClient.emit(.completed(taskID: 1, response: response, data: Data(), error: nil))

        _ = await collector.value

        XCTAssertEqual(collected.first?.completedBytes, 10)
        XCTAssertEqual(collected.first?.totalBytes, 20)
        XCTAssertEqual(collected.last?.fractionCompleted, 1)
        XCTAssertEqual(handle.status, .completed)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        interval: UInt64 = 10_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        enum WaitTimeoutError: Error { case timeout }
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return }
            try await Task.sleep(nanoseconds: interval)
        }
        XCTFail("Condition was not met within timeout")
        throw WaitTimeoutError.timeout
    }
}
