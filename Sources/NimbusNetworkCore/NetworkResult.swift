import Foundation

/// Success metadata returned by `HTTPClient`.
public struct NetworkSuccess<Value: Decodable> {
    public let value: Value
    public let statusCode: Int
    public let headers: [AnyHashable: Any]
    public let rawData: Data?

    public init(value: Value, statusCode: Int, headers: [AnyHashable: Any], rawData: Data?) {
        self.value = value
        self.statusCode = statusCode
        self.headers = headers
        self.rawData = rawData
    }
}

/// Type-erased container for decoded server error payloads.
public struct AnyServerError: @unchecked Sendable {
    public let typeName: String
    private let value: Any

    public init<T: Decodable>(_ value: T) {
        self.typeName = String(describing: T.self)
        self.value = value
    }

    public func typed<T: Decodable>(as type: T.Type) -> T? {
        value as? T
    }
}

/// Failure metadata returned by `HTTPClient`.
public struct NetworkFailure {
    public let error: NetworkError
    public let statusCode: Int?
    public let message: String
    public let rawData: Data?
    public let serverError: AnyServerError?

    public init(
        error: NetworkError,
        statusCode: Int?,
        message: String,
        rawData: Data?,
        serverError: AnyServerError? = nil
    ) {
        self.error = error
        self.statusCode = statusCode
        self.message = message
        self.rawData = rawData
        self.serverError = serverError
    }
}

/// Unified typed result for success and failure responses.
public enum NetworkResult<Value: Decodable> {
    case success(NetworkSuccess<Value>)
    case failure(NetworkFailure)

    public var value: Value? {
        guard case let .success(success) = self else { return nil }
        return success.value
    }

    public var failure: NetworkFailure? {
        guard case let .failure(failure) = self else { return nil }
        return failure
    }
}
