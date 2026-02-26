import Foundation

/// Computes backoff delays for retry attempts.
public protocol RetryDelayStrategy {
    func delay(forAttempt attempt: Int, randomSource: any RandomnessSource) -> TimeInterval
}

/// Random source abstraction to make jitter deterministic in tests.
public protocol RandomnessSource {
    func nextUnit() -> Double
}

/// Sleep abstraction for deterministic retry tests and schedulers.
public protocol TaskSleeping {
    func sleep(seconds: TimeInterval) async
}

/// Default task sleeper backed by `Task.sleep`.
public struct DefaultTaskSleeper: TaskSleeping {
    public init() {}

    public func sleep(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// Default randomness source based on `Double.random`.
public struct SystemRandomnessSource: RandomnessSource {
    public init() {}

    public func nextUnit() -> Double {
        Double.random(in: 0...1)
    }
}

/// Exponential backoff with optional jitter.
public struct ExponentialJitterBackoff: RetryDelayStrategy {
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let jitterFactor: Double

    public init(baseDelay: TimeInterval = 0.5, maximumDelay: TimeInterval = 30, jitterFactor: Double = 0.2) {
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.jitterFactor = max(0, min(jitterFactor, 1))
    }

    public func delay(forAttempt attempt: Int, randomSource: any RandomnessSource) -> TimeInterval {
        let exponential = min(maximumDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
        guard jitterFactor > 0 else { return exponential }
        let jitterScale = exponential * jitterFactor
        let randomComponent = (randomSource.nextUnit() * 2) - 1
        return max(0, exponential + (randomComponent * jitterScale))
    }
}

/// Configurable retry policy for status-code and transport-error retries.
public struct RetryPolicy {
    public let maxAttempts: Int
    public let retryableStatusCodes: Set<Int>
    public let retryableURLErrorCodes: Set<URLError.Code>
    public let delayStrategy: any RetryDelayStrategy

    public init(
        maxAttempts: Int = 3,
        retryableStatusCodes: Set<Int> = Set([429] + Array(500...599)),
        retryableURLErrorCodes: Set<URLError.Code> = [
            .timedOut,
            .networkConnectionLost,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable
        ],
        delayStrategy: any RetryDelayStrategy = ExponentialJitterBackoff()
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.retryableStatusCodes = retryableStatusCodes
        self.retryableURLErrorCodes = retryableURLErrorCodes
        self.delayStrategy = delayStrategy
    }

    public func shouldRetry(statusCode: Int? = nil, error: Error? = nil, attempt: Int) -> Bool {
        guard attempt < maxAttempts else {
            return false
        }

        if let statusCode, retryableStatusCodes.contains(statusCode) {
            return true
        }

        guard let error else {
            return false
        }

        if let urlError = error as? URLError {
            return retryableURLErrorCodes.contains(urlError.code)
        }

        if let networkError = error as? NetworkError {
            switch networkError {
            case .timeout:
                return true
            case .transport(let wrappedError):
                if let urlError = wrappedError as? URLError {
                    return retryableURLErrorCodes.contains(urlError.code)
                }
                return false
            default:
                return false
            }
        }

        return false
    }

    public func delay(forAttempt attempt: Int, randomSource: any RandomnessSource = SystemRandomnessSource()) -> TimeInterval {
        delayStrategy.delay(forAttempt: attempt, randomSource: randomSource)
    }
}
