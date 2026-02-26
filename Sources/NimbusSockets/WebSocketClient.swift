import Foundation

/// High-level WebSocket client abstraction.
public protocol WebSocketClient: AnyObject {
    var events: AsyncStream<WebSocketEvent> { get }

    func connect(url: URL, headers: [String: String]) async
    func disconnect() async
    func send(text: String) async throws
    func send(data: Data) async throws
}

/// Lifecycle control surface used by background strategies.
public protocol SocketLifecycleControlling: AnyObject {
    func suspendForBackground() async
    func reconnectIfNeeded() async
    func emitBackgroundRestricted() async
    func isConnected() async -> Bool
}
