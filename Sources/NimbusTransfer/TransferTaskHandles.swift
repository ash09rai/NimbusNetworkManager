import Foundation

/// Handle used to monitor and control a download task.
public final class DownloadTaskHandle {
    public let id: UUID
    public let progressStream: AsyncStream<TransferProgress>

    private let statusProvider: @Sendable () -> TransferTaskStatus
    private let cancelHandler: @Sendable () -> Void
    private let pauseHandler: @Sendable () -> Void
    private let resumeHandler: @Sendable () -> Void

    init(
        id: UUID,
        progressStream: AsyncStream<TransferProgress>,
        statusProvider: @escaping @Sendable () -> TransferTaskStatus,
        cancelHandler: @escaping @Sendable () -> Void,
        pauseHandler: @escaping @Sendable () -> Void,
        resumeHandler: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.progressStream = progressStream
        self.statusProvider = statusProvider
        self.cancelHandler = cancelHandler
        self.pauseHandler = pauseHandler
        self.resumeHandler = resumeHandler
    }

    public var status: TransferTaskStatus {
        statusProvider()
    }

    public func cancel() {
        cancelHandler()
    }

    public func pause() {
        pauseHandler()
    }

    public func resume() {
        resumeHandler()
    }
}

/// Handle used to monitor and control an upload task.
public final class UploadTaskHandle {
    public let id: UUID
    public let progressStream: AsyncStream<TransferProgress>

    private let statusProvider: @Sendable () -> TransferTaskStatus
    private let cancelHandler: @Sendable () -> Void
    private let pauseHandler: @Sendable () -> Void
    private let resumeHandler: @Sendable () -> Void

    init(
        id: UUID,
        progressStream: AsyncStream<TransferProgress>,
        statusProvider: @escaping @Sendable () -> TransferTaskStatus,
        cancelHandler: @escaping @Sendable () -> Void,
        pauseHandler: @escaping @Sendable () -> Void,
        resumeHandler: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.progressStream = progressStream
        self.statusProvider = statusProvider
        self.cancelHandler = cancelHandler
        self.pauseHandler = pauseHandler
        self.resumeHandler = resumeHandler
    }

    public var status: TransferTaskStatus {
        statusProvider()
    }

    public func cancel() {
        cancelHandler()
    }

    public func pause() {
        pauseHandler()
    }

    public func resume() {
        resumeHandler()
    }
}
