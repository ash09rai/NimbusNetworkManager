import Foundation

/// Events emitted by a download session client.
public enum DownloadSessionEvent: Sendable {
    case progress(taskID: Int, bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpected: Int64)
    case finished(taskID: Int, location: URL)
    case completed(taskID: Int, error: Error?)
}

/// Abstraction for download session implementations.
public protocol DownloadSessionClient: AnyObject {
    var identifier: String { get }
    var eventHandler: (@Sendable (DownloadSessionEvent) -> Void)? { get set }
    var backgroundEventsDidFinish: (@Sendable () -> Void)? { get set }

    func createDownloadTask(from url: URL) -> Int
    func createDownloadTask(with request: URLRequest) -> Int
    func createDownloadTask(with resumeData: Data) -> Int
    func resume(taskID: Int)
    func cancel(taskID: Int)
    func pause(taskID: Int, completion: @escaping (Data?) -> Void)
}

/// `URLSession`-backed implementation of `DownloadSessionClient`.
public final class URLSessionDownloadClient: NSObject, DownloadSessionClient {
    public let identifier: String
    public var eventHandler: (@Sendable (DownloadSessionEvent) -> Void)?
    public var backgroundEventsDidFinish: (@Sendable () -> Void)?

    private let lock = NSLock()
    private lazy var session: URLSession = {
        URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private let configuration: URLSessionConfiguration
    private var tasks: [Int: URLSessionDownloadTask] = [:]

    public init(identifier: String) {
        self.identifier = identifier
        self.configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        self.configuration.sessionSendsLaunchEvents = true
        self.configuration.isDiscretionary = false
        super.init()
        _ = session
    }

    public init(configuration: URLSessionConfiguration, identifier: String) {
        self.configuration = configuration
        self.identifier = identifier
        super.init()
        _ = session
    }

    public func createDownloadTask(from url: URL) -> Int {
        let task = session.downloadTask(with: url)
        let taskID = task.taskIdentifier
        lock.lock()
        tasks[taskID] = task
        lock.unlock()
        return taskID
    }

    public func createDownloadTask(with request: URLRequest) -> Int {
        let task = session.downloadTask(with: request)
        let taskID = task.taskIdentifier
        lock.lock()
        tasks[taskID] = task
        lock.unlock()
        return taskID
    }

    public func createDownloadTask(with resumeData: Data) -> Int {
        let task = session.downloadTask(withResumeData: resumeData)
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

    public func pause(taskID: Int, completion: @escaping (Data?) -> Void) {
        guard let task = task(for: taskID) else {
            completion(nil)
            return
        }
        task.cancel(byProducingResumeData: completion)
    }

    private func task(for taskID: Int) -> URLSessionDownloadTask? {
        lock.lock()
        let task = tasks[taskID]
        lock.unlock()
        return task
    }

    private func removeTask(for taskID: Int) {
        lock.lock()
        tasks.removeValue(forKey: taskID)
        lock.unlock()
    }
}

extension URLSessionDownloadClient: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        eventHandler?(
            .progress(
                taskID: downloadTask.taskIdentifier,
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpected: totalBytesExpectedToWrite
            )
        )
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        eventHandler?(.finished(taskID: downloadTask.taskIdentifier, location: location))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        eventHandler?(.completed(taskID: task.taskIdentifier, error: error))
        removeTask(for: task.taskIdentifier)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundEventsDidFinish?()
    }
}
