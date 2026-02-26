import Foundation

/// Applies authentication data and optionally refreshes credentials after unauthorized responses.
public protocol AuthStrategy {
    func apply(to request: URLRequest) async throws -> URLRequest
    func refreshIfNeeded(for response: HTTPURLResponse, data: Data?) async throws -> Bool
}

public extension AuthStrategy {
    func refreshIfNeeded(for response: HTTPURLResponse, data: Data?) async throws -> Bool {
        false
    }
}

/// Coordinates auth application and single-flight refresh.
public actor Authenticator {
    private let strategy: any AuthStrategy
    private let refreshStatusCodes: Set<Int>
    private var refreshTask: Task<Bool, Error>?

    public init(strategy: any AuthStrategy, refreshStatusCodes: Set<Int> = [401, 403]) {
        self.strategy = strategy
        self.refreshStatusCodes = refreshStatusCodes
    }

    public func apply(to request: URLRequest) async throws -> URLRequest {
        try await strategy.apply(to: request)
    }

    public func shouldTriggerRefresh(for statusCode: Int) -> Bool {
        refreshStatusCodes.contains(statusCode)
    }

    public func refreshIfNeeded(for response: HTTPURLResponse, data: Data?) async throws -> Bool {
        guard refreshStatusCodes.contains(response.statusCode) else {
            return false
        }

        if let refreshTask {
            return try await refreshTask.value
        }

        let task = Task { () throws -> Bool in
            try await strategy.refreshIfNeeded(for: response, data: data)
        }
        refreshTask = task

        do {
            let refreshed = try await task.value
            refreshTask = nil
            return refreshed
        } catch {
            refreshTask = nil
            throw error
        }
    }
}
