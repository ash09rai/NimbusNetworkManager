import XCTest
@testable import NimbusSockets
@testable import NimbusNetworkCore

final class WebSocketClientTests: XCTestCase {
    final class ImmediateSleeper: TaskSleeping {
        func sleep(seconds: TimeInterval) async {}
    }

    struct ZeroRandom: RandomnessSource {
        func nextUnit() -> Double { 0.5 }
    }

    final class MockWebSocketTask: WebSocketTaskProtocol {
        private let lock = NSLock()
        private var receiveQueue: [Result<URLSessionWebSocketTask.Message, Error>] = []
        private var pendingReceive: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?

        private(set) var resumeCallCount = 0
        private(set) var cancelCodes: [URLSessionWebSocketTask.CloseCode] = []
        private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
        private(set) var pingCallCount = 0

        var pingError: Error?

        func enqueueReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
            lock.lock()
            if let pendingReceive {
                self.pendingReceive = nil
                lock.unlock()
                pendingReceive(result)
                return
            }
            receiveQueue.append(result)
            lock.unlock()
        }

        func resume() {
            lock.lock()
            resumeCallCount += 1
            lock.unlock()
        }

        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            lock.lock()
            cancelCodes.append(closeCode)
            lock.unlock()
        }

        func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
            lock.lock()
            sentMessages.append(message)
            lock.unlock()
            completionHandler(nil)
        }

        func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
            lock.lock()
            if !receiveQueue.isEmpty {
                let result = receiveQueue.removeFirst()
                lock.unlock()
                completionHandler(result)
                return
            }
            pendingReceive = completionHandler
            lock.unlock()
        }

        func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
            lock.lock()
            pingCallCount += 1
            let pingError = self.pingError
            lock.unlock()
            pongReceiveHandler(pingError)
        }
    }

    final class MockWebSocketSession: WebSocketSessionProtocol {
        private let lock = NSLock()
        private var tasks: [MockWebSocketTask]
        private(set) var requests: [URLRequest] = []

        init(tasks: [MockWebSocketTask]) {
            self.tasks = tasks
        }

        func makeWebSocketTask(request: URLRequest) -> any WebSocketTaskProtocol {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            if tasks.isEmpty {
                return MockWebSocketTask()
            }
            return tasks.removeFirst()
        }
    }

    actor StrategySpy: SocketBackgroundStrategy {
        var willResignCount = 0
        var didEnterBackgroundCount = 0
        var willEnterForegroundCount = 0
        var didBecomeActiveCount = 0

        func onWillResignActive(client: any SocketLifecycleControlling) async {
            willResignCount += 1
        }

        func onDidEnterBackground(client: any SocketLifecycleControlling) async {
            didEnterBackgroundCount += 1
        }

        func onWillEnterForeground(client: any SocketLifecycleControlling) async {
            willEnterForegroundCount += 1
        }

        func onDidBecomeActive(client: any SocketLifecycleControlling) async {
            didBecomeActiveCount += 1
        }
    }

    actor LifecycleClientSpy: SocketLifecycleControlling {
        var connected = true
        var suspendCalls = 0
        var reconnectCalls = 0
        var restrictionCalls = 0

        func suspendForBackground() async {
            suspendCalls += 1
            connected = false
        }

        func reconnectIfNeeded() async {
            reconnectCalls += 1
            connected = true
        }

        func emitBackgroundRestricted() async {
            restrictionCalls += 1
        }

        func isConnected() async -> Bool {
            connected
        }
    }

    func testConnectSendReceiveAndDisconnect() async throws {
        let task = MockWebSocketTask()
        task.enqueueReceive(.success(.string("hello")))

        let session = MockWebSocketSession(tasks: [task])
        let client = DefaultWebSocketClient(
            configuration: .init(
                session: session,
                reconnectPolicy: nil,
                autoReconnect: false,
                keepAliveInterval: nil,
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom()
            )
        )

        var iterator = client.events.makeAsyncIterator()

        await client.connect(url: URL(string: "wss://example.com/socket")!, headers: ["Authorization": "Bearer token"])

        let firstEvent = await iterator.next()
        let secondEvent = await iterator.next()

        if case .connected = firstEvent {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected connected event")
        }

        if case let .message(.text(text)) = secondEvent {
            XCTAssertEqual(text, "hello")
        } else {
            XCTFail("Expected text message event")
        }

        try await client.send(text: "ping")
        try await client.send(data: Data([0x01, 0x02]))

        XCTAssertEqual(task.sentMessages.count, 2)
        XCTAssertEqual(session.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token")

        await client.disconnect()
        let disconnected = await iterator.next()
        if case .disconnected = disconnected {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected disconnected event")
        }
    }

    func testReconnectPolicyAndOnReconnectHook() async throws {
        let firstTask = MockWebSocketTask()
        firstTask.enqueueReceive(.failure(URLError(.networkConnectionLost)))

        let secondTask = MockWebSocketTask()
        secondTask.enqueueReceive(.success(.string("after-reconnect")))

        let session = MockWebSocketSession(tasks: [firstTask, secondTask])

        final class ReconnectRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var callCount = 0
            func record() {
                lock.lock()
                callCount += 1
                lock.unlock()
            }
        }
        let recorder = ReconnectRecorder()

        let client = DefaultWebSocketClient(
            configuration: .init(
                session: session,
                reconnectPolicy: SocketReconnectPolicy(maxAttempts: 2, baseDelay: 0, maximumDelay: 0, jitterFactor: 0),
                autoReconnect: true,
                keepAliveInterval: nil,
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom(),
                onReconnect: { _ in
                    recorder.record()
                }
            )
        )

        var iterator = client.events.makeAsyncIterator()
        await client.connect(url: URL(string: "wss://example.com/reconnect")!, headers: [:])

        _ = await iterator.next() // connected
        _ = await iterator.next() // error from first task
        _ = await iterator.next() // disconnected

        let reconnectEvent = await iterator.next()
        if case let .reconnected(attempt) = reconnectEvent {
            XCTAssertEqual(attempt, 1)
        } else {
            XCTFail("Expected reconnect event")
        }

        let messageEvent = await iterator.next()
        if case let .message(.text(text)) = messageEvent {
            XCTAssertEqual(text, "after-reconnect")
        } else {
            XCTFail("Expected message after reconnect")
        }

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(session.requests.count, 2)

        await client.disconnect()
    }

    func testPingKeepAliveScheduling() async throws {
        let task = MockWebSocketTask()
        task.pingError = URLError(.networkConnectionLost)

        let session = MockWebSocketSession(tasks: [task])
        let client = DefaultWebSocketClient(
            configuration: .init(
                session: session,
                reconnectPolicy: nil,
                autoReconnect: false,
                keepAliveInterval: 1,
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom()
            )
        )

        var iterator = client.events.makeAsyncIterator()
        await client.connect(url: URL(string: "wss://example.com/ping")!, headers: [:])

        _ = await iterator.next() // connected
        _ = await iterator.next() // error from ping

        XCTAssertEqual(task.pingCallCount, 1)
        await client.disconnect()
    }

    func testBackgroundLifecycleObserverForwardsCallbacks() async throws {
        let strategy = StrategySpy()
        let lifecycleClient = LifecycleClientSpy()

        let observer = AppLifecycleObserver(
            strategy: strategy,
            client: lifecycleClient,
            notificationCenter: .default,
            automaticallyObserveSystemNotifications: false
        )

        observer.notifyWillResignActive()
        observer.notifyDidEnterBackground()
        observer.notifyWillEnterForeground()
        observer.notifyDidBecomeActive()

        try await waitUntil {
            let resign = await strategy.willResignCount
            let background = await strategy.didEnterBackgroundCount
            let foreground = await strategy.willEnterForegroundCount
            let active = await strategy.didBecomeActiveCount
            return resign == 1 && background == 1 && foreground == 1 && active == 1
        }
    }

    func testDefaultBackgroundStrategyReconnectsOnForeground() async {
        let strategy = DefaultSocketBackgroundStrategy(
            allowsPersistentConnection: false,
            graceWindow: 0,
            hasBackgroundCapability: { false },
            sleeper: ImmediateSleeper()
        )

        let lifecycleClient = LifecycleClientSpy()
        await strategy.onDidBecomeActive(client: lifecycleClient)

        let reconnectCalls = await lifecycleClient.reconnectCalls
        XCTAssertEqual(reconnectCalls, 1)
    }

    func testBackgroundRestrictedPathEmitsSocketBackgroundRestrictedError() async {
        let task = MockWebSocketTask()
        let session = MockWebSocketSession(tasks: [task])

        let client = DefaultWebSocketClient(
            configuration: .init(
                session: session,
                reconnectPolicy: nil,
                autoReconnect: false,
                keepAliveInterval: nil,
                sleeper: ImmediateSleeper(),
                randomSource: ZeroRandom()
            )
        )

        let strategy = DefaultSocketBackgroundStrategy(
            allowsPersistentConnection: false,
            graceWindow: 0,
            hasBackgroundCapability: { false },
            sleeper: ImmediateSleeper()
        )

        var iterator = client.events.makeAsyncIterator()
        await client.connect(url: URL(string: "wss://example.com/background")!, headers: [:])

        _ = await iterator.next() // connected
        await strategy.onDidEnterBackground(client: client)

        let restrictedEvent = await iterator.next()
        let disconnectedEvent = await iterator.next()

        if case let .error(error) = restrictedEvent {
            XCTAssertEqual(error, .socketBackgroundRestricted)
        } else {
            XCTFail("Expected socket background restricted error")
        }

        if case .disconnected = disconnectedEvent {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected disconnected after background handling")
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        interval: UInt64 = 10_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await condition() { return }
            try await Task.sleep(nanoseconds: interval)
        }
        XCTFail("Condition was not met in time")
    }
}
