import XCTest
@testable import NimbusNetworkCore

final class HTTPClientTests: XCTestCase {
    struct UserResponse: Codable, Equatable {
        let id: Int
        let name: String
    }

    struct ErrorResponse: Codable, Equatable {
        let message: String
    }

    struct CreateUserBody: Codable, Equatable {
        let name: String
    }

    struct TestEndpoint: Endpoint {
        let baseURL: URL
        let path: String
        let method: HTTPMethod
        var headers: [String: String] = [:]
        var queryItems: [URLQueryItem] = []
        var timeout: TimeInterval? = nil
        var body: (any Encodable)? = nil
        var bodyData: Data? = nil
        var contentType: String? = HTTPContentType.json
        var accept: String? = HTTPContentType.json
        var cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData
        var responseDecoder: JSONDecoder? = nil
        var requestEncoder: JSONEncoder? = nil
        var retryPolicy: RetryPolicy? = nil
    }

    actor MockHTTPSession: HTTPSession {
        typealias Handler = (URLRequest) throws -> (Data, URLResponse)

        private var handlers: [Handler]
        private var requests: [URLRequest] = []

        init(handlers: [Handler]) {
            self.handlers = handlers
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let handler = handlers.isEmpty ? nil : handlers.removeFirst()

            guard let handler else {
                throw URLError(.badServerResponse)
            }
            return try handler(request)
        }

        func firstRequest() -> URLRequest? {
            requests.first
        }

        func requestCount() -> Int {
            requests.count
        }
    }

    actor RecordingInterceptor: RequestInterceptor {
        private var preparedRequests: [URLRequest] = []

        func prepare(_ request: URLRequest) async throws -> URLRequest {
            var request = request
            request.setValue("Interceptor", forHTTPHeaderField: "X-Trace")
            preparedRequests.append(request)
            return request
        }

        func didReceive(response: HTTPURLResponse, data: Data?) async {}

        func preparedCount() -> Int {
            preparedRequests.count
        }
    }

    actor MockAuthStrategy: AuthStrategy {
        var token: String
        var refreshCallCount: Int = 0
        var shouldRefreshSucceed: Bool

        init(token: String = "expired", shouldRefreshSucceed: Bool = true) {
            self.token = token
            self.shouldRefreshSucceed = shouldRefreshSucceed
        }

        func apply(to request: URLRequest) async throws -> URLRequest {
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }

        func refreshIfNeeded(for response: HTTPURLResponse, data: Data?) async throws -> Bool {
            refreshCallCount += 1
            if shouldRefreshSucceed {
                try? await Task.sleep(nanoseconds: 50_000_000)
                token = "fresh"
                return true
            }
            return false
        }
    }

    actor RecordingSleeper: TaskSleeping {
        private var durations: [TimeInterval] = []

        func sleep(seconds: TimeInterval) async {
            durations.append(seconds)
        }

        func recordedDurations() -> [TimeInterval] {
            durations
        }
    }

    struct FixedRandom: RandomnessSource {
        let value: Double

        func nextUnit() -> Double {
            value
        }
    }

    func testURLBuildingValidationWithBasePathAndQueryItems() async {
        let session = MockHTTPSession(handlers: [{ request in
            let data = try JSONEncoder().encode(UserResponse(id: 1, name: "Ash"))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-ID": "123"]
            )!
            return (data, response)
        }])

        let endpoint = TestEndpoint(
            baseURL: URL(string: "https://api.example.com/v1")!,
            path: "users",
            method: .get,
            queryItems: [URLQueryItem(name: "limit", value: "10")]
        )

        let client = HTTPClient(configuration: .init(session: session))
        let result = await client.send(endpoint, response: UserResponse.self)

        guard case let .success(success) = result else {
            XCTFail("Expected success")
            return
        }

        XCTAssertEqual(success.value, UserResponse(id: 1, name: "Ash"))
        XCTAssertEqual(success.statusCode, 200)
        XCTAssertEqual(success.headers["X-ID"] as? String, "123")
        let request = await session.firstRequest()
        XCTAssertEqual(request?.url?.absoluteString, "https://api.example.com/v1/users?limit=10")
    }

    func testHeaderInjectionViaInterceptors() async {
        let interceptor = RecordingInterceptor()
        let session = MockHTTPSession(handlers: [{ request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trace"), "Interceptor")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = try JSONEncoder().encode(UserResponse(id: 2, name: "Trace"))
            return (data, response)
        }])

        let endpoint = TestEndpoint(baseURL: URL(string: "https://api.example.com")!, path: "users", method: .get)

        let client = HTTPClient(configuration: .init(session: session, interceptors: [interceptor]))
        _ = await client.send(endpoint, response: UserResponse.self)

        let preparedCount = await interceptor.preparedCount()
        XCTAssertEqual(preparedCount, 1)
    }

    func testEncodableBodyEncoding() async throws {
        let session = MockHTTPSession(handlers: [{ request in
            let body = try XCTUnwrap(request.httpBody)
            let decoded = try JSONDecoder().decode(CreateUserBody.self, from: body)
            XCTAssertEqual(decoded, CreateUserBody(name: "New User"))

            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let data = try JSONEncoder().encode(UserResponse(id: 10, name: "New User"))
            return (data, response)
        }])

        let endpoint = TestEndpoint(baseURL: URL(string: "https://api.example.com")!, path: "users", method: .post)
        let client = HTTPClient(configuration: .init(session: session))

        let result = await client.send(endpoint, body: CreateUserBody(name: "New User"), response: UserResponse.self)
        guard case let .success(success) = result else {
            XCTFail("Expected success")
            return
        }
        XCTAssertEqual(success.statusCode, 201)
    }

    func testDecodingSuccess() async throws {
        let expected = UserResponse(id: 7, name: "Decode")
        let session = MockHTTPSession(handlers: [{ request in
            let data = try JSONEncoder().encode(expected)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }])

        let endpoint = TestEndpoint(baseURL: URL(string: "https://api.example.com")!, path: "decode", method: .get)
        let client = HTTPClient(configuration: .init(session: session))

        let result = await client.send(endpoint, response: UserResponse.self)
        XCTAssertEqual(result.value, expected)
    }

    func testRawDataResponseReturnsUnmodifiedPayload() async {
        let payload = Data("{\"raw\":true}".utf8)
        let session = MockHTTPSession(handlers: [{ request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (payload, response)
        }])

        let endpoint = TestEndpoint(baseURL: URL(string: "https://api.example.com")!, path: "raw", method: .get)
        let client = HTTPClient(configuration: .init(session: session))

        let result = await client.send(endpoint, response: Data.self)
        XCTAssertEqual(result.value, payload)
    }

    func testInvalidURLErrorMapping() async {
        let session = MockHTTPSession(handlers: [])
        let endpoint = TestEndpoint(baseURL: URL(string: "/relative-url")!, path: "users", method: .get)
        let client = HTTPClient(configuration: .init(session: session))

        let result = await client.send(endpoint, response: UserResponse.self)
        XCTAssertEqual(result.failure?.error, .invalidURL)
    }

    func testTransportTimeoutAndCancellationErrors() async {
        let timeoutSession = MockHTTPSession(handlers: [{ _ in
            throw URLError(.timedOut)
        }])
        let cancelSession = MockHTTPSession(handlers: [{ _ in
            throw URLError(.cancelled)
        }])

        let endpoint = TestEndpoint(baseURL: URL(string: "https://api.example.com")!, path: "timeout", method: .get)
        let timeoutClient = HTTPClient(configuration: .init(session: timeoutSession))
        let cancelClient = HTTPClient(configuration: .init(session: cancelSession))

        let timeoutResult = await timeoutClient.send(endpoint, response: UserResponse.self)
        let cancelResult = await cancelClient.send(endpoint, response: UserResponse.self)

        XCTAssertEqual(timeoutResult.failure?.error, .timeout)
        XCTAssertEqual(cancelResult.failure?.error, .cancelled)
    }

    func testServerErrorCapturesStatusAndRawData() async throws {
        let errorData = try JSONEncoder().encode(ErrorResponse(message: "Bad request"))
        let session = MockHTTPSession(handlers: [{ request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (errorData, response)
        }])

        let endpoint = TestEndpoint(baseURL: URL(string: "https://api.example.com")!, path: "users", method: .get)
        let client = HTTPClient(configuration: .init(session: session))

        let result = await client.send(endpoint, response: UserResponse.self)
        guard case let .failure(failure) = result else {
            XCTFail("Expected failure")
            return
        }

        XCTAssertEqual(failure.statusCode, 400)
        XCTAssertEqual(failure.rawData, errorData)
        XCTAssertEqual(failure.error, .server(statusCode: 400, data: errorData))
    }

    func testRetryPolicyRetries429AndSucceeds() async throws {
        let sleeper = RecordingSleeper()
        let policy = RetryPolicy(
            maxAttempts: 3,
            retryableStatusCodes: [429],
            delayStrategy: ExponentialJitterBackoff(baseDelay: 1, maximumDelay: 1, jitterFactor: 0)
        )

        let successData = try JSONEncoder().encode(UserResponse(id: 5, name: "Retry"))
        let session = MockHTTPSession(handlers: [
            { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
                return (Data("rate-limit".utf8), response)
            },
            { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (successData, response)
            }
        ])

        let endpoint = TestEndpoint(baseURL: URL(string: "https://api.example.com")!, path: "retry", method: .get, retryPolicy: policy)
        let client = HTTPClient(configuration: .init(session: session, sleeper: sleeper, randomSource: FixedRandom(value: 0.5)))

        let result = await client.send(endpoint, response: UserResponse.self)

        let requestCount = await session.requestCount()
        let sleepDurations = await sleeper.recordedDurations()
        XCTAssertEqual(result.value, UserResponse(id: 5, name: "Retry"))
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(sleepDurations, [1])
    }

    func testRetryExhaustedForPersistentServerErrors() async {
        let policy = RetryPolicy(maxAttempts: 2, retryableStatusCodes: [500], delayStrategy: ExponentialJitterBackoff(baseDelay: 0, maximumDelay: 0, jitterFactor: 0))
        let session = MockHTTPSession(handlers: [
            { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            },
            { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        ])

        let endpoint = TestEndpoint(baseURL: URL(string: "https://api.example.com")!, path: "retry", method: .get, retryPolicy: policy)
        let client = HTTPClient(configuration: .init(session: session, sleeper: RecordingSleeper(), randomSource: FixedRandom(value: 0.5)))

        let result = await client.send(endpoint, response: UserResponse.self)
        XCTAssertEqual(result.failure?.error, .retryExhausted)
    }

    func testAuthRefreshSingleFlightWithConcurrentRequests() async {
        let strategy = MockAuthStrategy(token: "expired", shouldRefreshSucceed: true)
        let authenticator = Authenticator(strategy: strategy)

        let session = MockHTTPSession(handlers: [
            { request in
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                    return (Data(), response)
                }
                let data = try JSONEncoder().encode(UserResponse(id: 1, name: "A"))
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            },
            { request in
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                    return (Data(), response)
                }
                let data = try JSONEncoder().encode(UserResponse(id: 2, name: "B"))
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            },
            { request in
                let data = try JSONEncoder().encode(UserResponse(id: 3, name: "C"))
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            },
            { request in
                let data = try JSONEncoder().encode(UserResponse(id: 4, name: "D"))
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
        ])

        let endpoint = TestEndpoint(baseURL: URL(string: "https://api.example.com")!, path: "auth", method: .get)
        let client = HTTPClient(configuration: .init(session: session, authenticator: authenticator))

        async let first = client.send(endpoint, response: UserResponse.self)
        async let second = client.send(endpoint, response: UserResponse.self)

        _ = await [first, second]
        let refreshCount = await strategy.refreshCallCount
        XCTAssertEqual(refreshCount, 1)
    }

    func testAuthRefreshFailurePath() async {
        let strategy = MockAuthStrategy(token: "expired", shouldRefreshSucceed: false)
        let authenticator = Authenticator(strategy: strategy)

        let session = MockHTTPSession(handlers: [{ request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }])

        let endpoint = TestEndpoint(baseURL: URL(string: "https://api.example.com")!, path: "auth-fail", method: .get)
        let client = HTTPClient(configuration: .init(session: session, authenticator: authenticator))

        let result = await client.send(endpoint, response: UserResponse.self)
        XCTAssertEqual(result.failure?.error, .authFailed)
    }

    func testServerErrorDecodingSupport() async throws {
        let errorData = try JSONEncoder().encode(ErrorResponse(message: "Oops"))
        let session = MockHTTPSession(handlers: [{ request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (errorData, response)
        }])

        let endpoint = TestEndpoint(baseURL: URL(string: "https://api.example.com")!, path: "error", method: .post)
        let client = HTTPClient(configuration: .init(session: session))

        let result = await client.send(endpoint, response: UserResponse.self, serverError: ErrorResponse.self)

        guard case let .failure(failure) = result else {
            XCTFail("Expected failure")
            return
        }

        let decoded = failure.serverError?.typed(as: ErrorResponse.self)
        XCTAssertEqual(decoded, ErrorResponse(message: "Oops"))
    }

    func testRetryPolicyBackoffDeterministicWithInjectedRandomness() {
        let policy = RetryPolicy(
            maxAttempts: 3,
            retryableStatusCodes: [500],
            retryableURLErrorCodes: [.timedOut],
            delayStrategy: ExponentialJitterBackoff(baseDelay: 2, maximumDelay: 10, jitterFactor: 0.5)
        )

        let delay = policy.delay(forAttempt: 2, randomSource: FixedRandom(value: 1))
        XCTAssertEqual(delay, 6, accuracy: 0.0001)
        XCTAssertTrue(policy.shouldRetry(statusCode: 500, attempt: 1))
        XCTAssertTrue(policy.shouldRetry(error: URLError(.timedOut), attempt: 1))
        XCTAssertFalse(policy.shouldRetry(statusCode: 400, attempt: 1))
    }

    func testURLProtocolStubSequenceForClientWithoutRealNetwork() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.enqueue(
            statusCode: 500,
            data: Data("first".utf8)
        )
        URLProtocolStub.enqueue(
            statusCode: 200,
            data: try JSONEncoder().encode(UserResponse(id: 99, name: "URLProtocol"))
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)

        let policy = RetryPolicy(maxAttempts: 2, retryableStatusCodes: [500], delayStrategy: ExponentialJitterBackoff(baseDelay: 0, maximumDelay: 0, jitterFactor: 0))

        let endpoint = TestEndpoint(baseURL: URL(string: "https://stub.example.com")!, path: "users", method: .get, retryPolicy: policy)
        let client = HTTPClient(configuration: .init(session: session, sleeper: RecordingSleeper()))

        let result = await client.send(endpoint, response: UserResponse.self)
        XCTAssertEqual(result.value, UserResponse(id: 99, name: "URLProtocol"))
        XCTAssertEqual(URLProtocolStub.requestCount, 2)
    }
}

private final class URLProtocolStub: URLProtocol {
    struct QueuedResponse {
        let statusCode: Int
        let data: Data
        let headers: [String: String]
    }

    private static let lock = NSLock()
    private static var responses: [QueuedResponse] = []
    private(set) static var requestCount: Int = 0

    static func reset() {
        lock.lock()
        responses = []
        requestCount = 0
        lock.unlock()
    }

    static func enqueue(statusCode: Int, data: Data, headers: [String: String] = [:]) {
        lock.lock()
        responses.append(.init(statusCode: statusCode, data: data, headers: headers))
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        URLProtocolStub.lock.lock()
        URLProtocolStub.requestCount += 1
        let response = URLProtocolStub.responses.isEmpty ? nil : URLProtocolStub.responses.removeFirst()
        URLProtocolStub.lock.unlock()

        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
