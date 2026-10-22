import Foundation

// MARK: - 并行调度基础设施

/// 并行扫描队列元素：待处理的目录 + 祖先累计的停止点。
nonisolated struct QueueItem: Sendable {
    let url: URL
    let stopPath: String
}

/// 线程安全的目录工作队列，供多个 worker 领取任务。
/// 队列暂时为空时 worker 会等待（而不是退出），
/// 只有全部 worker 都空闲且队列为空时任务才真正结束。
nonisolated final class DirectoryQueue: @unchecked Sendable {
    private let cond = NSCondition()
    private var items: [QueueItem] = []
    private var idleWorkers = 0
    private var finished = false
    private let totalWorkers: Int

    init(workerCount: Int) {
        self.totalWorkers = workerCount
    }

    func push(_ newItems: [QueueItem]) {
        guard !newItems.isEmpty else { return }
        cond.lock()
        items.append(contentsOf: newItems)
        if idleWorkers > 0 {
            cond.signal()
        }
        cond.unlock()
    }

    /// 幂等地结束整个队列：唤醒所有等待中的 worker。
    /// worker 在取消或达到扫描上限而提前退出前必须调用，
    /// 否则阻塞在 cond.wait 的其它 worker 会永远等不到终止信号。
    func finish() {
        cond.lock()
        finished = true
        cond.broadcast()
        cond.unlock()
    }

    /// 领取一个任务；队列暂时为空时等待新任务，
    /// 全部 worker 都空闲时返回 nil 表示结束。
    func popBlocking() -> QueueItem? {
        cond.lock()
        defer { cond.unlock() }
        while true {
            if finished { return nil }
            if let item = items.popLast() {
                return item
            }
            idleWorkers += 1
            if idleWorkers >= totalWorkers {
                finished = true
                idleWorkers -= 1
                cond.broadcast()
                return nil
            }
            cond.wait()
            idleWorkers -= 1
        }
    }
}

/// 线程安全的全局条目计数器，同时承担扫描上限判断。
nonisolated final class EntryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0
    private var limitReached = false

    init(limit: Int) { self.limit = limit }

    /// 申请处理一个条目；达到上限后返回 -1 且不再自增。
    func reserve() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if count >= limit {
            limitReached = true
            return -1
        }
        count += 1
        return count
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func didReachLimit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return limitReached
    }
}

/// 线程安全的下标分发器：多个 worker 轮流领取 0..<limit 的任务下标。
nonisolated final class WorkIndex: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var next = 0
    private var processed = 0

    init(limit: Int) { self.limit = limit }

    func nextIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard next < limit else { return nil }
        let index = next
        next += 1
        return index
    }

    func bumpProcessed() -> Int {
        lock.lock()
        defer { lock.unlock() }
        processed += 1
        return processed
    }
}
