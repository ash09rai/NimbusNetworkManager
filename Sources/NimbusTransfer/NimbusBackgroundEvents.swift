import Foundation

/// Stores and resolves app delegate completion handlers for background transfer sessions.
public final class NimbusBackgroundEvents {
    public static let shared = NimbusBackgroundEvents()

    private let lock = NSLock()
    private var completionHandlers: [String: () -> Void] = [:]

    private init() {}

    public func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping () -> Void) {
        lock.lock()
        completionHandlers[identifier] = completionHandler
        lock.unlock()
    }

    public func completeEvents(for identifier: String) {
        lock.lock()
        let completion = completionHandlers.removeValue(forKey: identifier)
        lock.unlock()
        completion?()
    }
}
