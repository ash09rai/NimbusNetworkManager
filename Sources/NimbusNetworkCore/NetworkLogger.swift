import Foundation

public enum NetworkLogLevel: String {
    case debug
    case info
    case error
}

public protocol NetworkLogger {
    func log(level: NetworkLogLevel, message: String, metadata: [String: String])
}

public struct NoopNetworkLogger: NetworkLogger {
    public init() {}

    public func log(level: NetworkLogLevel, message: String, metadata: [String: String]) {}
}

public struct PrintNetworkLogger: NetworkLogger {
    public init() {}

    public func log(level: NetworkLogLevel, message: String, metadata: [String: String] = [:]) {
        #if DEBUG
        let metadataString = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        print("[NimbusNetworkCore][\(level.rawValue.uppercased())] \(message) \(metadataString)")
        #endif
    }
}
