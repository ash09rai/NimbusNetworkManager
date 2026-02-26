import Foundation
import NimbusNetworkCore

/// Strategy interface for app lifecycle aware socket behavior.
public protocol SocketBackgroundStrategy: AnyObject {
    func onWillResignActive(client: any SocketLifecycleControlling) async
    func onDidEnterBackground(client: any SocketLifecycleControlling) async
    func onWillEnterForeground(client: any SocketLifecycleControlling) async
    func onDidBecomeActive(client: any SocketLifecycleControlling) async
}

/// Default background strategy: graceful suspend in background, reconnect on foreground.
public final actor DefaultSocketBackgroundStrategy: SocketBackgroundStrategy {
    public typealias BackgroundCapabilityChecker = @Sendable () -> Bool

    private let allowsPersistentConnection: Bool
    private let graceWindow: TimeInterval
    private let hasBackgroundCapability: BackgroundCapabilityChecker
    private let sleeper: any TaskSleeping

    public init(
        allowsPersistentConnection: Bool = false,
        graceWindow: TimeInterval = 2,
        hasBackgroundCapability: @escaping BackgroundCapabilityChecker = { false },
        sleeper: any TaskSleeping = DefaultTaskSleeper()
    ) {
        self.allowsPersistentConnection = allowsPersistentConnection
        self.graceWindow = max(0, graceWindow)
        self.hasBackgroundCapability = hasBackgroundCapability
        self.sleeper = sleeper
    }

    public func onWillResignActive(client: any SocketLifecycleControlling) async {
        _ = await client.isConnected()
    }

    public func onDidEnterBackground(client: any SocketLifecycleControlling) async {
        if allowsPersistentConnection || hasBackgroundCapability() {
            guard graceWindow > 0 else { return }
            await sleeper.sleep(seconds: graceWindow)
            if !(allowsPersistentConnection || hasBackgroundCapability()) {
                await client.emitBackgroundRestricted()
                await client.suspendForBackground()
            }
            return
        }

        await client.emitBackgroundRestricted()
        await client.suspendForBackground()
    }

    public func onWillEnterForeground(client: any SocketLifecycleControlling) async {
        _ = await client.isConnected()
    }

    public func onDidBecomeActive(client: any SocketLifecycleControlling) async {
        await client.reconnectIfNeeded()
    }
}
