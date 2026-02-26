import Foundation

/// Describes a network endpoint and request metadata needed to build a `URLRequest`.
public protocol Endpoint {
    var baseURL: URL { get }
    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String] { get }
    var queryItems: [URLQueryItem] { get }
    var timeout: TimeInterval? { get }
    var body: (any Encodable)? { get }
    var bodyData: Data? { get }
    var contentType: String? { get }
    var accept: String? { get }
    var cachePolicy: URLRequest.CachePolicy { get }
    var responseDecoder: JSONDecoder? { get }
    var requestEncoder: JSONEncoder? { get }
    var retryPolicy: RetryPolicy? { get }
}

public extension Endpoint {
    var headers: [String: String] { [:] }
    var queryItems: [URLQueryItem] { [] }
    var timeout: TimeInterval? { nil }
    var body: (any Encodable)? { nil }
    var bodyData: Data? { nil }
    var contentType: String? { HTTPContentType.json }
    var accept: String? { HTTPContentType.json }
    var cachePolicy: URLRequest.CachePolicy { .useProtocolCachePolicy }
    var responseDecoder: JSONDecoder? { nil }
    var requestEncoder: JSONEncoder? { nil }
    var retryPolicy: RetryPolicy? { nil }
}

/// Convenience endpoint implementation for simple request construction.
public struct BasicEndpoint: Endpoint {
    public let baseURL: URL
    public let path: String
    public let method: HTTPMethod
    public let headers: [String: String]
    public let queryItems: [URLQueryItem]
    public let timeout: TimeInterval?
    public let body: (any Encodable)?
    public let bodyData: Data?
    public let contentType: String?
    public let accept: String?
    public let cachePolicy: URLRequest.CachePolicy
    public let responseDecoder: JSONDecoder?
    public let requestEncoder: JSONEncoder?
    public let retryPolicy: RetryPolicy?

    public init(
        baseURL: URL,
        path: String,
        method: HTTPMethod,
        headers: [String: String] = [:],
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval? = nil,
        body: (any Encodable)? = nil,
        bodyData: Data? = nil,
        contentType: String? = HTTPContentType.json,
        accept: String? = HTTPContentType.json,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        responseDecoder: JSONDecoder? = nil,
        requestEncoder: JSONEncoder? = nil,
        retryPolicy: RetryPolicy? = nil
    ) {
        self.baseURL = baseURL
        self.path = path
        self.method = method
        self.headers = headers
        self.queryItems = queryItems
        self.timeout = timeout
        self.body = body
        self.bodyData = bodyData
        self.contentType = contentType
        self.accept = accept
        self.cachePolicy = cachePolicy
        self.responseDecoder = responseDecoder
        self.requestEncoder = requestEncoder
        self.retryPolicy = retryPolicy
    }
}
