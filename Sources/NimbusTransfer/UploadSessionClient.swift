import Foundation

/// Events emitted by an upload session client.
public enum UploadSessionEvent: Sendable {
    case progress(taskID: Int, bytesSent: Int64, totalBytesSent: Int64, totalBytesExpected: Int64)
    case completed(taskID: Int, response: HTTPURLResponse?, data: Data?, error: Error?)
}

/// Abstraction for upload session implementations.
public protocol UploadSessionClient: AnyObject {
    var identifier: String { get }
    var eventHandler: (@Sendable (UploadSessionEvent) -> Void)? { get set }
    var backgroundEventsDidFinish: (@Sendable () -> Void)? { get set }

    func createUploadTask(request: URLRequest, fileURL: URL) -> Int
    func resume(taskID: Int)
    func cancel(taskID: Int)
}

/// `URLSession`-backed implementation of `UploadSessionClient`.
public final class URLSessionUploadClient: NSObject, UploadSessionClient {
    public let identifier: String
    public var eventHandler: (@Sendable (UploadSessionEvent) -> Void)?
    public var backgroundEventsDidFinish: (@Sendable () -> Void)?

    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private lazy var session: URLSession = {
        URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var tasks: [Int: URLSessionUploadTask] = [:]
    private var responseData: [Int: Data] = [:]

    public init(identifier: String) {
        self.identifier = identifier
        self.configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        self.configuration.sessionSendsLaunchEvents = true
        self.configuration.isDiscretionary = false
        super.init()
        _ = session
    }

    public init(configuration: URLSessionConfiguration, identifier: String) {
        self.identifier = identifier
        self.configuration = configuration
        super.init()
        _ = session
    }

    public func createUploadTask(request: URLRequest, fileURL: URL) -> Int {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        let taskID = task.taskIdentifier
        lock.lock()
        tasks[taskID] = task
        lock.unlock()
        return taskID
    }

    public func resume(taskID: Int) {
        guard let task = task(for: taskID) else { return }
        task.resume()
    }

    public func cancel(taskID: Int) {
        guard let task = task(for: taskID) else { return }
        task.cancel()
    }

    private func task(for taskID: Int) -> URLSessionUploadTask? {
        lock.lock()
        let task = tasks[taskID]
        lock.unlock()
        return task
    }

    private func appendData(_ data: Data, for taskID: Int) {
        lock.lock()
        responseData[taskID, default: Data()].append(data)
        lock.unlock()
    }

    private func removeData(for taskID: Int) -> Data? {
        lock.lock()
        let data = responseData.removeValue(forKey: taskID)
        lock.unlock()
        return data
    }

    private func removeTask(for taskID: Int) {
        lock.lock()
        tasks.removeValue(forKey: taskID)
        lock.unlock()
    }
}

extension URLSessionUploadClient: URLSessionTaskDelegate, URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        appendData(data, for: dataTask.taskIdentifier)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        eventHandler?(
            .progress(
                taskID: task.taskIdentifier,
                bytesSent: bytesSent,
                totalBytesSent: totalBytesSent,
                totalBytesExpected: totalBytesExpectedToSend
            )
        )
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = removeData(for: task.taskIdentifier)
        let response = task.response as? HTTPURLResponse
        eventHandler?(.completed(taskID: task.taskIdentifier, response: response, data: data, error: error))
        removeTask(for: task.taskIdentifier)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundEventsDidFinish?()
    }
}
