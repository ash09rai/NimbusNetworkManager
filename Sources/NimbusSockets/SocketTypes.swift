import Foundation
import NimbusNetworkCore

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

public enum WebSocketEvent: Sendable, Equatable {
    case connected
    case disconnected(code: URLSessionWebSocketTask.CloseCode?)
    case message(WebSocketMessage)
    case error(NetworkError)
    case reconnected(attempt: Int)
}

public struct SocketReconnectPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let jitterFactor: Double

    public init(
        maxAttempts: Int = 5,
        baseDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 30,
        jitterFactor: Double = 0.2
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.jitterFactor = max(0, min(jitterFactor, 1))
    }

    public func delay(forAttempt attempt: Int, randomSource: any RandomnessSource = SystemRandomnessSource()) -> TimeInterval {
        let exponentialDelay = min(maximumDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
        guard jitterFactor > 0 else {
            return exponentialDelay
        }
        let jitter = (randomSource.nextUnit() * 2 - 1) * jitterFactor * exponentialDelay
        return max(0, exponentialDelay + jitter)
    }
}
