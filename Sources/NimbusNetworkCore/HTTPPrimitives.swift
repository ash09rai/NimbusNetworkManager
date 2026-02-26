import Foundation

public enum HTTPMethod: String, Sendable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public enum HTTPContentType {
    public static let json = "application/json"
    public static let formURLEncoded = "application/x-www-form-urlencoded"
    public static let octetStream = "application/octet-stream"
    public static let textPlain = "text/plain"
}

public struct EmptyResponse: Decodable, Sendable {
    public init() {}
}

public struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    public init<T: Encodable>(_ wrapped: T) {
        self.encodeClosure = wrapped.encode
    }

    public func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
