import Foundation

/// Configuration container for `HTTPClient`.
public struct HTTPClientConfiguration {
    public var session: any HTTPSession
    public var encoder: JSONEncoder
    public var decoder: JSONDecoder
    public var retryPolicy: RetryPolicy?
    public var interceptors: [any RequestInterceptor]
    public var authenticator: Authenticator?
    public var logger: any NetworkLogger
    public var sleeper: any TaskSleeping
    public var randomSource: any RandomnessSource
    public var errorMessageMapper: (NetworkError, Int?, Data?) -> String

    public init(
        session: any HTTPSession = URLSession.shared,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        retryPolicy: RetryPolicy? = nil,
        interceptors: [any RequestInterceptor] = [],
        authenticator: Authenticator? = nil,
        logger: any NetworkLogger = NoopNetworkLogger(),
        sleeper: any TaskSleeping = DefaultTaskSleeper(),
        randomSource: any RandomnessSource = SystemRandomnessSource(),
        errorMessageMapper: @escaping (NetworkError, Int?, Data?) -> String = { error, _, _ in
            error.defaultMessage
        }
    ) {
        self.session = session
        self.encoder = encoder
        self.decoder = decoder
        self.retryPolicy = retryPolicy
        self.interceptors = interceptors
        self.authenticator = authenticator
        self.logger = logger
        self.sleeper = sleeper
        self.randomSource = randomSource
        self.errorMessageMapper = errorMessageMapper
    }
}

/// Actor-based HTTP client with retry, interception, authentication, and typed decoding support.
public actor HTTPClient {
    private let configuration: HTTPClientConfiguration

    public init(configuration: HTTPClientConfiguration = HTTPClientConfiguration()) {
        self.configuration = configuration
    }

    /// Sends an endpoint request and decodes a success payload.
    public func send<T: Decodable>(
        _ endpoint: any Endpoint,
        response: T.Type
    ) async -> NetworkResult<T> {
        await sendInternal(endpoint, responseType: response, overrides: .none, serverErrorDecoder: nil)
    }

    /// Sends an endpoint request and decodes both success and typed server-error payloads.
    public func send<T: Decodable, E: Decodable>(
        _ endpoint: any Endpoint,
        response: T.Type,
        serverError: E.Type
    ) async -> NetworkResult<T> {
        let serverErrorDecoder: (Data?) -> AnyServerError? = { [decoder = configuration.decoder] data in
            guard let data, !data.isEmpty else { return nil }
            guard let decoded = try? decoder.decode(serverError, from: data) else {
                return nil
            }
            return AnyServerError(decoded)
        }
        return await sendInternal(
            endpoint,
            responseType: response,
            overrides: .none,
            serverErrorDecoder: serverErrorDecoder
        )
    }

    /// Sends an endpoint request with an encoded body override.
    public func send<T: Decodable, Body: Encodable>(
        _ endpoint: any Endpoint,
        body: Body,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        response: T.Type
    ) async -> NetworkResult<T> {
        let overrides = RequestOverrides(body: body, bodyData: nil, queryItems: queryItems, headers: headers)
        return await sendInternal(endpoint, responseType: response, overrides: overrides, serverErrorDecoder: nil)
    }

    /// Sends an endpoint request with query/header overrides.
    public func send<T: Decodable>(
        _ endpoint: any Endpoint,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        response: T.Type
    ) async -> NetworkResult<T> {
        let overrides = RequestOverrides(body: nil, bodyData: nil, queryItems: queryItems, headers: headers)
        return await sendInternal(endpoint, responseType: response, overrides: overrides, serverErrorDecoder: nil)
    }

    private func sendInternal<T: Decodable>(
        _ endpoint: any Endpoint,
        responseType: T.Type,
        overrides: RequestOverrides,
        serverErrorDecoder: ((Data?) -> AnyServerError?)?
    ) async -> NetworkResult<T> {
        let encoder = endpoint.requestEncoder ?? configuration.encoder
        let decoder = endpoint.responseDecoder ?? configuration.decoder
        let retryPolicy = endpoint.retryPolicy ?? configuration.retryPolicy

        let requestBuilder = RequestBuilder(encoder: encoder)

        let baseRequest: URLRequest
        do {
            baseRequest = try requestBuilder.build(endpoint: endpoint, overrides: overrides)
        } catch let error as NetworkError {
            return makeFailure(error: error, statusCode: nil, data: nil, serverErrorDecoder: serverErrorDecoder)
        } catch {
            return makeFailure(error: .requestBuildFailed, statusCode: nil, data: nil, serverErrorDecoder: serverErrorDecoder)
        }

        return await execute(
            baseRequest: baseRequest,
            decoder: decoder,
            retryPolicy: retryPolicy,
            responseType: responseType,
            serverErrorDecoder: serverErrorDecoder,
            allowAuthRefreshRetry: true
        )
    }

    private func execute<T: Decodable>(
        baseRequest: URLRequest,
        decoder: JSONDecoder,
        retryPolicy: RetryPolicy?,
        responseType: T.Type,
        serverErrorDecoder: ((Data?) -> AnyServerError?)?,
        allowAuthRefreshRetry: Bool
    ) async -> NetworkResult<T> {
        var attempt = 1

        while true {
            do {
                let preparedRequest = try await prepareRequest(baseRequest)
                configuration.logger.log(level: .debug, message: "Sending request", metadata: [
                    "method": preparedRequest.httpMethod ?? "",
                    "url": preparedRequest.url?.absoluteString ?? ""
                ])

                let (data, rawResponse) = try await configuration.session.data(for: preparedRequest)
                guard let httpResponse = rawResponse as? HTTPURLResponse else {
                    return makeFailure(
                        error: .transport(URLError(.badServerResponse)),
                        statusCode: nil,
                        data: data,
                        serverErrorDecoder: serverErrorDecoder
                    )
                }

                for interceptor in configuration.interceptors {
                    await interceptor.didReceive(response: httpResponse, data: data)
                }

                if allowAuthRefreshRetry,
                   let authenticator = configuration.authenticator,
                   await authenticator.shouldTriggerRefresh(for: httpResponse.statusCode) {
                    do {
                        let refreshed = try await authenticator.refreshIfNeeded(for: httpResponse, data: data)
                        if refreshed {
                            configuration.logger.log(level: .info, message: "Auth refreshed; retrying request", metadata: [
                                "statusCode": "\(httpResponse.statusCode)"
                            ])
                            return await execute(
                                baseRequest: baseRequest,
                                decoder: decoder,
                                retryPolicy: retryPolicy,
                                responseType: responseType,
                                serverErrorDecoder: serverErrorDecoder,
                                allowAuthRefreshRetry: false
                            )
                        }
                        return makeFailure(error: .authFailed, statusCode: httpResponse.statusCode, data: data, serverErrorDecoder: serverErrorDecoder)
                    } catch {
                        return makeFailure(error: .authFailed, statusCode: httpResponse.statusCode, data: data, serverErrorDecoder: serverErrorDecoder)
                    }
                }

                if (200...299).contains(httpResponse.statusCode) {
                    do {
                        let decodedValue = try decodeSuccess(data: data, as: responseType, decoder: decoder)
                        return .success(
                            NetworkSuccess(
                                value: decodedValue,
                                statusCode: httpResponse.statusCode,
                                headers: httpResponse.allHeaderFields,
                                rawData: data
                            )
                        )
                    } catch {
                        return makeFailure(error: .decoding(error), statusCode: httpResponse.statusCode, data: data, serverErrorDecoder: serverErrorDecoder)
                    }
                }

                if let retryPolicy,
                   retryPolicy.shouldRetry(statusCode: httpResponse.statusCode, attempt: attempt) {
                    let delay = retryPolicy.delay(forAttempt: attempt, randomSource: configuration.randomSource)
                    configuration.logger.log(level: .info, message: "Retrying request after server response", metadata: [
                        "attempt": "\(attempt)",
                        "statusCode": "\(httpResponse.statusCode)",
                        "delay": "\(delay)"
                    ])
                    await configuration.sleeper.sleep(seconds: delay)
                    attempt += 1
                    continue
                }

                if let retryPolicy,
                   attempt >= retryPolicy.maxAttempts,
                   retryPolicy.retryableStatusCodes.contains(httpResponse.statusCode) {
                    return makeFailure(error: .retryExhausted, statusCode: httpResponse.statusCode, data: data, serverErrorDecoder: serverErrorDecoder)
                }

                return makeFailure(
                    error: .server(statusCode: httpResponse.statusCode, data: data),
                    statusCode: httpResponse.statusCode,
                    data: data,
                    serverErrorDecoder: serverErrorDecoder
                )
            } catch {
                let mappedError = mapToNetworkError(error)
                if let retryPolicy,
                   retryPolicy.shouldRetry(error: mappedError, attempt: attempt) {
                    let delay = retryPolicy.delay(forAttempt: attempt, randomSource: configuration.randomSource)
                    configuration.logger.log(level: .info, message: "Retrying request after transport error", metadata: [
                        "attempt": "\(attempt)",
                        "error": "\(mappedError)",
                        "delay": "\(delay)"
                    ])
                    await configuration.sleeper.sleep(seconds: delay)
                    attempt += 1
                    continue
                }

                if let retryPolicy,
                   attempt >= retryPolicy.maxAttempts,
                   isRetryableError(mappedError, policy: retryPolicy) {
                    return makeFailure(error: .retryExhausted, statusCode: nil, data: nil, serverErrorDecoder: serverErrorDecoder)
                }

                return makeFailure(error: mappedError, statusCode: nil, data: nil, serverErrorDecoder: serverErrorDecoder)
            }
        }
    }

    private func prepareRequest(_ request: URLRequest) async throws -> URLRequest {
        var preparedRequest = request

        if let authenticator = configuration.authenticator {
            preparedRequest = try await authenticator.apply(to: preparedRequest)
        }

        for interceptor in configuration.interceptors {
            preparedRequest = try await interceptor.prepare(preparedRequest)
        }

        return preparedRequest
    }

    private func decodeSuccess<T: Decodable>(data: Data, as type: T.Type, decoder: JSONDecoder) throws -> T {
        if T.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! T
        }
        if data.isEmpty {
            throw NetworkError.decoding(
                DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Expected response data, but received empty response body.")
                )
            )
        }
        return try decoder.decode(T.self, from: data)
    }

    private func mapToNetworkError(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError {
            return networkError
        }
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .cancelled:
                return .cancelled
            default:
                return .transport(urlError)
            }
        }
        return .transport(error)
    }

    private func isRetryableError(_ error: NetworkError, policy: RetryPolicy) -> Bool {
        switch error {
        case .timeout:
            return true
        case .transport(let wrapped):
            guard let urlError = wrapped as? URLError else { return false }
            return policy.retryableURLErrorCodes.contains(urlError.code)
        default:
            return false
        }
    }

    private func makeFailure<T: Decodable>(
        error: NetworkError,
        statusCode: Int?,
        data: Data?,
        serverErrorDecoder: ((Data?) -> AnyServerError?)?
    ) -> NetworkResult<T> {
        let serverError = serverErrorDecoder?(data)
        let message = configuration.errorMessageMapper(error, statusCode, data)
        return .failure(
            NetworkFailure(
                error: error,
                statusCode: statusCode,
                message: message,
                rawData: data,
                serverError: serverError
            )
        )
    }
}
