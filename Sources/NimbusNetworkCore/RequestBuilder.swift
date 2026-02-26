import Foundation

struct RequestOverrides {
    var body: (any Encodable)?
    var bodyData: Data?
    var queryItems: [URLQueryItem]
    var headers: [String: String]

    static let none = RequestOverrides(body: nil, bodyData: nil, queryItems: [], headers: [:])
}

struct RequestBuilder {
    let encoder: JSONEncoder

    func build(endpoint: any Endpoint, overrides: RequestOverrides) throws -> URLRequest {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL
        }
        guard let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw NetworkError.invalidURL
        }

        components.path = normalizedPath(basePath: components.path, endpointPath: endpoint.path)
        let allQueryItems = endpoint.queryItems + overrides.queryItems
        components.queryItems = allQueryItems.isEmpty ? nil : allQueryItems

        guard let url = components.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.cachePolicy = endpoint.cachePolicy
        if let timeout = endpoint.timeout {
            request.timeoutInterval = timeout
        }

        let mergedHeaders = endpoint.headers.merging(overrides.headers) { _, new in new }
        for (key, value) in mergedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let contentType = endpoint.contentType, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let accept = endpoint.accept, request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }

        if let bodyData = overrides.bodyData ?? endpoint.bodyData {
            request.httpBody = bodyData
        } else if let body = overrides.body ?? endpoint.body {
            do {
                request.httpBody = try encoder.encode(AnyEncodable(body))
            } catch {
                throw NetworkError.requestBuildFailed
            }
        }

        return request
    }

    private func normalizedPath(basePath: String, endpointPath: String) -> String {
        let base = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = endpointPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if base.isEmpty {
            return path.isEmpty ? "/" : "/\(path)"
        }
        if path.isEmpty {
            return "/\(base)"
        }
        return "/\(base)/\(path)"
    }
}
