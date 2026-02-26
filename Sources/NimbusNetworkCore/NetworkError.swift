import Foundation

public enum NetworkError: Error, Equatable {
    case invalidURL
    case requestBuildFailed
    case transport(Error)
    case cancelled
    case server(statusCode: Int, data: Data?)
    case decoding(Error)
    case timeout
    case authFailed
    case retryExhausted
    case backgroundTransfer(Error)
    case socketDisconnected
    case socketProtocolError
    case socketBackgroundRestricted

    public static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL),
            (.requestBuildFailed, .requestBuildFailed),
            (.cancelled, .cancelled),
            (.timeout, .timeout),
            (.authFailed, .authFailed),
            (.retryExhausted, .retryExhausted),
            (.socketDisconnected, .socketDisconnected),
            (.socketProtocolError, .socketProtocolError),
            (.socketBackgroundRestricted, .socketBackgroundRestricted):
            return true
        case (.transport(let lhsError), .transport(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        case (.server(let lhsCode, let lhsData), .server(let rhsCode, let rhsData)):
            return lhsCode == rhsCode && lhsData == rhsData
        case (.decoding(let lhsError), .decoding(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        case (.backgroundTransfer(let lhsError), .backgroundTransfer(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}

public extension NetworkError {
    var defaultMessage: String {
        switch self {
        case .invalidURL:
            return "The request URL is invalid."
        case .requestBuildFailed:
            return "Failed to build the request."
        case .transport(let error):
            return error.localizedDescription
        case .cancelled:
            return "The request was cancelled."
        case .server(let statusCode, _):
            return "The server returned status code \(statusCode)."
        case .decoding:
            return "Unable to decode the server response."
        case .timeout:
            return "The request timed out."
        case .authFailed:
            return "Authentication failed."
        case .retryExhausted:
            return "Retry attempts were exhausted."
        case .backgroundTransfer(let error):
            return error.localizedDescription
        case .socketDisconnected:
            return "The socket disconnected."
        case .socketProtocolError:
            return "The socket encountered a protocol error."
        case .socketBackgroundRestricted:
            return "Background socket execution is restricted in the current app state."
        }
    }
}
