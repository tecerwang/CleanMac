import Foundation

/// 扫描任务取消令牌（零依赖模块）。扫描器在工作循环中定期检查该标志，
/// 以便用户随时中断耗时的磁盘分析。
nonisolated final class ScanToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }
}
