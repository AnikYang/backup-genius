import Foundation

extension Work {
    var estimatedWork: Double {
        let size = kind == .sync && stamp?.kind == .regular ? stamp?.size ?? 0 : 0
        // Reserve work for metadata and transaction publication as well as data I/O.
        return Double(blockSize) + 2 * Double(size)
    }
}

// Preparation workers and the transaction writer report I/O while a timer samples it.
final class TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Double
    private let started: Double
    private var completed: Double = 0
    private var batch: Double = 0
    private var batchIO: Double = 0
    private var written: Double = 0
    private var sampledAt: Double
    private var sampledWork: Double = 0
    private var sampledWritten: Double = 0
    private var workRate: Double?
    private var writeRate: Double?
    private var lastWorkAt: Double

    init(total: Double, at time: Double) {
        self.total = total
        started = time
        sampledAt = time
        lastWorkAt = time
    }

    func beginBatch(_ work: Double) { lock.withLock { batch = work } }

    func record(read: Int = 0, written: Int = 0) {
        lock.withLock {
            batchIO += Double(read) + Double(written)
            self.written += Double(written)
        }
    }

    func finishBatch() {
        lock.withLock {
            completed += batch
            batch = 0
            batchIO = 0
        }
    }

    @discardableResult
    func sample(at time: Double, progress: inout SyncProgress) -> Bool {
        lock.withLock {
            let interval = time - sampledAt
            guard interval >= 0.2 else { return false }
            // Keep some work outstanding until the prepared batch commits.
            let work = completed + min(batchIO, batch * 0.8)
            let smoothing = min(1, interval / 2)
            let nextWork = (work - sampledWork) / interval
            let nextWrite = (written - sampledWritten) / interval
            if nextWork > 0 { lastWorkAt = time }
            workRate = (workRate ?? nextWork) * (1 - smoothing) + nextWork * smoothing
            writeRate = (writeRate ?? nextWrite) * (1 - smoothing) + nextWrite * smoothing
            sampledAt = time
            sampledWork = work
            sampledWritten = written
            progress.writeBytesPerSecond = nextWrite == 0 ? 0 : writeRate
            if time - started >= 1, work > 0, time - lastWorkAt < 2, work < total, let workRate, workRate > 0 {
                let remaining = (total - work) / workRate
                progress.estimatedSecondsRemaining = remaining.isFinite ? remaining : nil
            } else {
                progress.estimatedSecondsRemaining = nil
            }
            return true
        }
    }
}
