import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Bridges UIKit lifecycle notifications to a `SocketBackgroundStrategy`.
public final class AppLifecycleObserver {
    private let strategy: any SocketBackgroundStrategy
    private let client: any SocketLifecycleControlling
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    public init(
        strategy: any SocketBackgroundStrategy,
        client: any SocketLifecycleControlling,
        notificationCenter: NotificationCenter = .default,
        automaticallyObserveSystemNotifications: Bool = true
    ) {
        self.strategy = strategy
        self.client = client
        self.notificationCenter = notificationCenter

        #if canImport(UIKit)
        if automaticallyObserveSystemNotifications {
            registerNotifications()
        }
        #else
        _ = automaticallyObserveSystemNotifications
        #endif
    }

    deinit {
        observers.forEach(notificationCenter.removeObserver)
    }

    public func notifyWillResignActive() {
        Task { await strategy.onWillResignActive(client: client) }
    }

    public func notifyDidEnterBackground() {
        Task { await strategy.onDidEnterBackground(client: client) }
    }

    public func notifyWillEnterForeground() {
        Task { await strategy.onWillEnterForeground(client: client) }
    }

    public func notifyDidBecomeActive() {
        Task { await strategy.onDidBecomeActive(client: client) }
    }

    #if canImport(UIKit)
    private func registerNotifications() {
        observers.append(
            notificationCenter.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.notifyWillResignActive()
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.notifyDidEnterBackground()
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.notifyWillEnterForeground()
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.notifyDidBecomeActive()
            }
        )
    }
    #endif
}
