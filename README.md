# NimbusNetworkKit

`NimbusNetworkKit` is a modular Swift Package for iOS 15+ networking using native `URLSession` + `async/await`.

## Modules

- `NimbusNetworkCore`
  - Endpoint modeling, request building, HTTP client, typed result/error model, retry policy, auth coordinator, interceptors
- `NimbusTransfer`
  - Background-capable download/upload managers with progress streams, retry, pause/resume hooks, and background event routing
- `NimbusSockets`
  - WebSocket abstraction + default `URLSessionWebSocketTask` client, reconnect/keepalive, lifecycle-aware background strategy hooks
- `NimbusNetworkKit`
  - Umbrella target that re-exports all modules

## Requirements

- iOS 15+
- Xcode 15+
- Swift 5.9+

## Installation (SPM)

Add to `Package.swift`:

```swift
.package(url: "https://github.com/your-org/NimbusNetworkKit.git", from: "1.0.0")
```

Then add product dependency:

```swift
.product(name: "NimbusNetworkKit", package: "NimbusNetworkKit")
```

## Core Usage

### 1) Basic GET with decoding

```swift
import NimbusNetworkKit

struct UserDTO: Decodable {
    let id: Int
    let name: String
}

struct GetUserEndpoint: Endpoint {
    let baseURL = URL(string: "https://api.example.com")!
    let path = "users/42"
    let method: HTTPMethod = .get
}

let client = HTTPClient()
let result = await client.send(GetUserEndpoint(), response: UserDTO.self)

switch result {
case .success(let success):
    print(success.value, success.statusCode)
case .failure(let failure):
    print(failure.message, failure.statusCode as Any)
}
```

### 2) POST with Encodable body

```swift
import NimbusNetworkKit

struct CreateUserBody: Encodable {
    let name: String
}

struct CreateUserEndpoint: Endpoint {
    let baseURL = URL(string: "https://api.example.com")!
    let path = "users"
    let method: HTTPMethod = .post
}

let result = await client.send(
    CreateUserEndpoint(),
    body: CreateUserBody(name: "Nimbus"),
    response: UserDTO.self
)
```

### 3) Inject AuthStrategy + interceptor pipeline

```swift
import NimbusNetworkKit

actor TokenAuth: AuthStrategy {
    var accessToken: String = "initial-token"

    func apply(to request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    func refreshIfNeeded(for response: HTTPURLResponse, data: Data?) async throws -> Bool {
        guard response.statusCode == 401 else { return false }
        accessToken = "refreshed-token"
        return true
    }
}

struct TraceInterceptor: RequestInterceptor {
    func prepare(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Trace-Id")
        return request
    }
}

let auth = Authenticator(strategy: TokenAuth())
let config = HTTPClientConfiguration(
    interceptors: [TraceInterceptor()],
    authenticator: auth,
    retryPolicy: RetryPolicy(maxAttempts: 3)
)
let authedClient = HTTPClient(configuration: config)
```

## Transfer Usage

### 4) Download with progress + pause/resume

```swift
import NimbusNetworkKit

let downloadManager = DownloadManager()
let destination = FileManager.default.temporaryDirectory.appendingPathComponent("video.mp4")

let handle = downloadManager.startDownload(
    url: URL(string: "https://cdn.example.com/video.mp4")!,
    destination: destination
)

Task {
    for await progress in handle.progressStream {
        print("download progress:", progress.fractionCompleted)
    }
}

handle.pause()
handle.resume()
```

In `AppDelegate`/`SceneDelegate`:

```swift
NimbusBackgroundEvents.shared.handleEventsForBackgroundURLSession(identifier: identifier) {
    completionHandler()
}
```

### 5) Upload with progress + retry + resumable strategy hook

```swift
import NimbusNetworkKit

struct UploadEndpoint: Endpoint {
    let baseURL = URL(string: "https://api.example.com")!
    let path = "uploads"
    let method: HTTPMethod = .post
}

struct OffsetUploadStrategy: ResumableUploadStrategy {
    func resumeRequest(for originalRequest: URLRequest, fileURL: URL, uploadedBytes: Int64) async throws -> URLRequest? {
        var request = originalRequest
        request.setValue("\(uploadedBytes)", forHTTPHeaderField: "Upload-Offset")
        return request
    }
}

let uploadManager = UploadManager(
    configuration: .init(
        retryPolicy: RetryPolicy(maxAttempts: 3),
        resumableUploadStrategy: OffsetUploadStrategy()
    )
)

let fileURL = URL(fileURLWithPath: "/path/to/file.bin")
let uploadHandle = uploadManager.startUpload(fileURL: fileURL, to: UploadEndpoint())

Task {
    for await progress in uploadHandle.progressStream {
        print("upload progress:", progress.fractionCompleted)
    }
}
```

## Socket Usage

### 6) WebSocket connect/send/receive + lifecycle strategy + re-subscribe hook

```swift
import NimbusNetworkKit

let socket = DefaultWebSocketClient(
    configuration: .init(
        reconnectPolicy: .init(maxAttempts: 5, baseDelay: 1, maximumDelay: 16),
        onReconnect: { client in
            try? await client.send(text: "{\"type\":\"resubscribe\"}")
        }
    )
)

let backgroundStrategy = DefaultSocketBackgroundStrategy(
    allowsPersistentConnection: false,
    graceWindow: 1
)

let lifecycleObserver = AppLifecycleObserver(
    strategy: backgroundStrategy,
    client: socket
)

await socket.connect(url: URL(string: "wss://socket.example.com/ws")!, headers: [:])
try? await socket.send(text: "hello")

Task {
    for await event in socket.events {
        print("socket event:", event)
    }
}
```

## iOS Background Socket Limitations (Important)

iOS generally does **not** guarantee always-on background sockets for standard app configurations. `NimbusSockets` follows best-practice behavior:

- Graceful socket suspension on background when persistent socket mode is not valid
- Explicit `socketBackgroundRestricted` error signaling
- Robust reconnect/backoff on foreground
- Consumer re-auth and re-subscribe hook (`onReconnect`)

If your app requires persistent background networking, you must use appropriate Apple-approved background modes and server-side design compatible with those constraints.

## Testing

All tests are local-network independent and mock-driven.

Run:

```bash
swift test --enable-xctest --disable-swift-testing
```

Enable coverage:

```bash
swift test --enable-xctest --disable-swift-testing --enable-code-coverage
```

