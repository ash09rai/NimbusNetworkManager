import Foundation
import NimbusNetworkCore

/// Configuration for `DefaultWebSocketClient`.
public struct WebSocketClientConfiguration {
    public let session: any WebSocketSessionProtocol
    public let reconnectPolicy: SocketReconnectPolicy?
    public let autoReconnect: Bool
    public let keepAliveInterval: TimeInterval?
    public let sleeper: any TaskSleeping
    public let randomSource: any RandomnessSource
    public let logger: any NetworkLogger
    public let onReconnect: (@Sendable (any WebSocketClient) async -> Void)?

    public init(
        session: (any WebSocketSessionProtocol)? = nil,
        reconnectPolicy: SocketReconnectPolicy? = SocketReconnectPolicy(),
        autoReconnect: Bool = true,
        keepAliveInterval: TimeInterval? = 30,
        sleeper: any TaskSleeping = DefaultTaskSleeper(),
        randomSource: any RandomnessSource = SystemRandomnessSource(),
        logger: any NetworkLogger = NoopNetworkLogger(),
        onReconnect: (@Sendable (any WebSocketClient) async -> Void)? = nil
    ) {
        self.session = session ?? URLSession(configuration: .default)
        self.reconnectPolicy = reconnectPolicy
        self.autoReconnect = autoReconnect
        self.keepAliveInterval = keepAliveInterval
        self.sleeper = sleeper
        self.randomSource = randomSource
        self.logger = logger
        self.onReconnect = onReconnect
    }
}

/// Default `WebSocketClient` implementation backed by `URLSessionWebSocketTask`.
public actor DefaultWebSocketClient: WebSocketClient, SocketLifecycleControlling {
    public nonisolated let events: AsyncStream<WebSocketEvent>

    private let configuration: WebSocketClientConfiguration
    private let continuation: AsyncStream<WebSocketEvent>.Continuation

    private var currentTask: (any WebSocketTaskProtocol)?
    private var currentTaskID: ObjectIdentifier?
    private var receiveLoopTask: Task<Void, Never>?
    private var pingLoopTask: Task<Void, Never>?
    private var reconnectLoopTask: Task<Void, Never>?

    private var lastRequest: URLRequest?
    private var manualDisconnect = false
    private var connected = false
    private var reconnectAttempt = 0

    public init(configuration: WebSocketClientConfiguration = WebSocketClientConfiguration()) {
        self.configuration = configuration
        var streamContinuation: AsyncStream<WebSocketEvent>.Continuation!
        self.events = AsyncStream<WebSocketEvent> { streamContinuation = $0 }
        self.continuation = streamContinuation
    }

    deinit {
        continuation.finish()
    }

    public func connect(url: URL, headers: [String: String] = [:]) async {
        var request = URLRequest(url: url)
        headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        lastRequest = request
        manualDisconnect = false
        reconnectAttempt = 0
        await establishConnection(with: request, isReconnect: false)
    }

    public func disconnect() async {
        manualDisconnect = true
        reconnectLoopTask?.cancel()
        reconnectLoopTask = nil
        closeCurrentConnection(code: .normalClosure)
    }

    public func send(text: String) async throws {
        guard let currentTask else {
            throw NetworkError.socketDisconnected
        }
        try await send(.string(text), on: currentTask)
    }

    public func send(data: Data) async throws {
        guard let currentTask else {
            throw NetworkError.socketDisconnected
        }
        try await send(.data(data), on: currentTask)
    }

    public func suspendForBackground() async {
        closeCurrentConnection(code: .goingAway)
    }

    public func reconnectIfNeeded() async {
        guard !connected, !manualDisconnect else { return }
        guard let request = lastRequest else { return }
        reconnectAttempt = 0
        await establishConnection(with: request, isReconnect: true)
    }

    public func emitBackgroundRestricted() async {
        continuation.yield(.error(.socketBackgroundRestricted))
    }

    public func isConnected() async -> Bool {
        connected
    }

    private func establishConnection(with request: URLRequest, isReconnect: Bool) async {
        let task = configuration.session.makeWebSocketTask(request: request)
        currentTask = task
        currentTaskID = ObjectIdentifier(task as AnyObject)
        connected = true

        task.resume()
        configuration.logger.log(level: .info, message: isReconnect ? "WebSocket reconnected" : "WebSocket connected", metadata: [
            "url": request.url?.absoluteString ?? ""
        ])

        if isReconnect {
            continuation.yield(.reconnected(attempt: reconnectAttempt))
            if let onReconnect = configuration.onReconnect {
                await onReconnect(self)
            }
        } else {
            continuation.yield(.connected)
        }

        startReceiveLoop(taskID: ObjectIdentifier(task as AnyObject))
        startPingLoop(taskID: ObjectIdentifier(task as AnyObject))
    }

    private func closeCurrentConnection(code: URLSessionWebSocketTask.CloseCode) {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil

        pingLoopTask?.cancel()
        pingLoopTask = nil

        if let currentTask {
            currentTask.cancel(with: code, reason: nil)
        }

        let wasConnected = connected
        connected = false
        currentTask = nil
        currentTaskID = nil

        if wasConnected {
            continuation.yield(.disconnected(code: code))
        }
    }

    private func startReceiveLoop(taskID: ObjectIdentifier) {
        receiveLoopTask?.cancel()
        receiveLoopTask = Task { [weak self] in
            await self?.runReceiveLoop(taskID: taskID)
        }
    }

    private func startPingLoop(taskID: ObjectIdentifier) {
        pingLoopTask?.cancel()

        guard let keepAliveInterval = configuration.keepAliveInterval,
              keepAliveInterval > 0 else {
            return
        }

        pingLoopTask = Task { [weak self] in
            await self?.runPingLoop(taskID: taskID, interval: keepAliveInterval)
        }
    }

    private func runReceiveLoop(taskID: ObjectIdentifier) async {
        while !Task.isCancelled {
            guard let currentTask,
                  currentTaskID == taskID else {
                return
            }

            do {
                let message = try await receive(from: currentTask)
                switch message {
                case .string(let text):
                    continuation.yield(.message(.text(text)))
                case .data(let data):
                    continuation.yield(.message(.data(data)))
                @unknown default:
                    continuation.yield(.error(.socketProtocolError))
                }
            } catch {
                await handleSocketError(error, taskID: taskID)
                return
            }
        }
    }

    private func runPingLoop(taskID: ObjectIdentifier, interval: TimeInterval) async {
        while !Task.isCancelled {
            await configuration.sleeper.sleep(seconds: interval)
            guard let currentTask,
                  currentTaskID == taskID else {
                return
            }

            do {
                try await sendPing(on: currentTask)
            } catch {
                await handleSocketError(error, taskID: taskID)
                return
            }
        }
    }

    private func handleSocketError(_ error: Error, taskID: ObjectIdentifier) async {
        guard currentTaskID == taskID else { return }

        closeCurrentConnection(code: .abnormalClosure)
        let mappedError = mapError(error)
        continuation.yield(.error(mappedError))

        guard configuration.autoReconnect,
              !manualDisconnect,
              configuration.reconnectPolicy != nil else {
            return
        }

        await scheduleReconnectIfNeeded()
    }

    private func scheduleReconnectIfNeeded() async {
        guard reconnectLoopTask == nil,
              let reconnectPolicy = configuration.reconnectPolicy else {
            return
        }

        reconnectLoopTask = Task { [weak self] in
            await self?.runReconnectLoop(policy: reconnectPolicy)
        }
    }

    private func runReconnectLoop(policy: SocketReconnectPolicy) async {
        while !Task.isCancelled {
            guard let request = lastRequest,
                  !manualDisconnect else {
                reconnectLoopTask = nil
                return
            }

            reconnectAttempt += 1
            guard reconnectAttempt <= policy.maxAttempts else {
                reconnectLoopTask = nil
                continuation.yield(.error(.retryExhausted))
                return
            }

            let delay = policy.delay(forAttempt: reconnectAttempt, randomSource: configuration.randomSource)
            await configuration.sleeper.sleep(seconds: delay)
            await establishConnection(with: request, isReconnect: true)
            reconnectLoopTask = nil
            return
        }
    }

    private func mapError(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError {
            return networkError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .networkConnectionLost, .notConnectedToInternet:
                return .socketDisconnected
            case .cannotParseResponse:
                return .socketProtocolError
            default:
                return .transport(urlError)
            }
        }
        return .socketProtocolError
    }

    private func receive(from task: any WebSocketTaskProtocol) async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            task.receive { result in
                continuation.resume(with: result)
            }
        }
    }

    private func send(_ message: URLSessionWebSocketTask.Message, on task: any WebSocketTaskProtocol) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(message) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func sendPing(on task: any WebSocketTaskProtocol) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
