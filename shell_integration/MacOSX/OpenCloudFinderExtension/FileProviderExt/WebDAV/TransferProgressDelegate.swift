import Foundation

/// A task delegate is retained only for its own transfer, so simultaneous file
/// operations never overwrite each other's Finder progress.
final class TransferProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: Progress?
    /// Chunked uploads report the bytes already on the server and the whole file size,
    /// so Finder shows overall progress rather than that of the current chunk.
    private let baseOffset: Int64
    private let totalSize: Int64?
    init(progress: Progress?, baseOffset: Int64 = 0, totalSize: Int64? = nil) {
        self.progress = progress
        self.baseOffset = baseOffset
        self.totalSize = totalSize
    }

    private func update(completed: Int64, expected: Int64) {
        guard let progress = progress else { return }
        let completed = baseOffset + completed
        let expected = totalSize ?? expected
        if expected > 0 { progress.totalUnitCount = expected }
        else { progress.totalUnitCount = max(progress.totalUnitCount, completed + 1) }
        progress.completedUnitCount = max(0, completed)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        update(completed: totalBytesSent, expected: totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        update(completed: totalBytesWritten, expected: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The async download method owns moving the temporary file and validates HTTP status.
    }
}
