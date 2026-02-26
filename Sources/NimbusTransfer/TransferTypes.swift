import Foundation

public enum TransferTaskStatus: Sendable, Equatable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
}

public struct TransferProgress: Sendable, Equatable {
    public let completedBytes: Int64
    public let totalBytes: Int64?

    public var fractionCompleted: Double {
        guard let totalBytes, totalBytes > 0 else {
            return 0
        }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}
