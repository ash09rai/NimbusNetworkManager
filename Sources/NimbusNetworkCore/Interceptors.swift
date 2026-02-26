import Foundation

/// Middleware hook for request mutation and response observation.
public protocol RequestInterceptor {
    func prepare(_ request: URLRequest) async throws -> URLRequest
    func didReceive(response: HTTPURLResponse, data: Data?) async
}

public extension RequestInterceptor {
    func didReceive(response: HTTPURLResponse, data: Data?) async {}
}
