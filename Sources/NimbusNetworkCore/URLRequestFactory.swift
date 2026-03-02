import Foundation

/// Public wrapper for constructing `URLRequest` values from Nimbus endpoints.
public struct URLRequestFactory {
    private let encoder: JSONEncoder

    public init(encoder: JSONEncoder = JSONEncoder()) {
        self.encoder = encoder
    }

    public func makeRequest(for endpoint: any Endpoint) throws -> URLRequest {
        try RequestBuilder(encoder: encoder).build(endpoint: endpoint, overrides: .none)
    }
}
