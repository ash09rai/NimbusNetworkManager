import Foundation

/// Abstraction over `URLSessionWebSocketTask` for testability.
public protocol WebSocketTaskProtocol: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void)
    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void)
}

/// Adapter that exposes `URLSessionWebSocketTask` through `WebSocketTaskProtocol`.
public final class URLSessionWebSocketTaskAdapter: WebSocketTaskProtocol {
    private let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func resume() {
        task.resume()
    }

    public func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }

    public func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        task.send(message, completionHandler: completionHandler)
    }

    public func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        task.receive(completionHandler: completionHandler)
    }

    public func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        task.sendPing(pongReceiveHandler: pongReceiveHandler)
    }
}

/// Abstraction that creates WebSocket tasks.
public protocol WebSocketSessionProtocol {
    func makeWebSocketTask(request: URLRequest) -> any WebSocketTaskProtocol
}

extension URLSession: WebSocketSessionProtocol {
    public func makeWebSocketTask(request: URLRequest) -> any WebSocketTaskProtocol {
        URLSessionWebSocketTaskAdapter(task: webSocketTask(with: request))
    }
}
