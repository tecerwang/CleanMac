import Foundation

/// 单目录扫描 worker 的局部结果（最后合并，无锁竞争）。
nonisolated struct DirectoryWorkerResult: Sendable {
    var folderSizes: [String: Int64] = [:]
    var directChildren: [String: URL] = [:]
    var unreadableCount = 0
    var childrenByPath: [String: [DirectoryEntry]] = [:]
}

/// 扫描一个目录树，返回其直接子目录的占用大小（含隐藏目录）。
/// 使用 4 个并行 worker 共享目录队列。
nonisolated struct DirectoryScanner {
    private let fileManager = FileManager.default
    private let maxEntries = 1_000_000
    private let workerCount = 4

    /// 返回 (直接子目录列表, 根目录自身的完整占用)。
    /// 根目录大小包含了其下所有子目录与文件的累计占用，
    /// 供界面把子目录的占用递归汇总到父目录上显示。
    func scanDirectory(at root: URL, token: ScanToken? = nil, includeRootWhenEmpty: Bool = false, retainTree: Bool = false, progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async -> DirectoryScanResult {
        let root = root.standardizedFileURL
        guard fileManager.fileExists(atPath: root.path) else { return DirectoryScanResult(unreadableCount: 1) }
        let stopPath = root.deletingLastPathComponent().standardizedFileURL.path
        let queue = DirectoryQueue(workerCount: workerCount)
        let counter = EntryCounter(limit: Int.max)
        queue.push([QueueItem(url: root, stopPath: stopPath)])

        var merged = await withTaskGroup(of: DirectoryWorkerResult.self, returning: DirectoryWorkerResult.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    self.workerDirectory(queue: queue, counter: counter, root: root, stopPath: stopPath, token: token, retainTree: retainTree, progress: progress)
                }
            }
            var merged = DirectoryWorkerResult()
            for await result in group {
                if token?.isCancelled == true { queue.finish(); continue }
                merged.unreadableCount += result.unreadableCount
                merged.childrenByPath.merge(result.childrenByPath) { _, new in new }
                for (path, size) in result.folderSizes {
                    if token?.isCancelled == true { break }
                    merged.folderSizes[path, default: 0] += size
                }
                for (path, url) in result.directChildren {
                    merged.directChildren[path] = url
                }
            }
            return merged
        }

        if token?.isCancelled == true { return DirectoryScanResult(cancelled: true) }

        let rootSize = merged.folderSizes[root.standardizedFileURL.path, default: 0]
        var entries = merged.directChildren.map { path, url in
            let size = merged.folderSizes[path, default: 0]
            let hidden = (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? url.lastPathComponent.hasPrefix(".")
            return DirectoryEntry(id: path, name: url.lastPathComponent, path: path, size: size, sizeText: CleanMacFormat.bytes(size), depth: 1, isHidden: hidden == true)
        }
        if includeRootWhenEmpty && entries.isEmpty {
            entries.append(DirectoryEntry(id: root.path, name: root.lastPathComponent, path: root.path, size: rootSize, sizeText: CleanMacFormat.bytes(rootSize), depth: 0, isHidden: root.lastPathComponent.hasPrefix(".")))
        }
        if retainTree {
            for path in merged.childrenByPath.keys {
                if token?.isCancelled == true { return DirectoryScanResult(cancelled: true) }
                merged.childrenByPath[path] = merged.childrenByPath[path]!.map { entry in
                    var updated = entry
                    if updated.isDirectory {
                        let size = merged.folderSizes[entry.path, default: 0]
                        updated = DirectoryEntry(id: entry.id, name: entry.name, path: entry.path, size: size, sizeText: CleanMacFormat.bytes(size), depth: 1, isHidden: entry.isHidden)
                    }
                    return updated
                }.sorted { $0.size > $1.size }
            }
        }
        return DirectoryScanResult(entries: entries.sorted { $0.size > $1.size }, rootSize: rootSize, unreadableCount: merged.unreadableCount, cancelled: token?.isCancelled == true, childrenByPath: merged.childrenByPath, sizesByPath: merged.folderSizes)
    }

    private func workerDirectory(queue: DirectoryQueue, counter: EntryCounter, root: URL, stopPath: String, token: ScanToken?, retainTree: Bool, progress: @escaping @Sendable (ScanProgress) -> Void) -> DirectoryWorkerResult {
        var result = DirectoryWorkerResult()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isHiddenKey]

        loop: while true {
            if token?.isCancelled == true {
                queue.finish()
                break
            }
            guard let item = queue.popBlocking() else { break }
            let directoryPath = item.url.standardizedFileURL.path
            if retainTree { result.childrenByPath[directoryPath] = [] }
            result.folderSizes[directoryPath, default: 0] += 0
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(at: item.url, includingPropertiesForKeys: keys, options: [])
            } catch {
                result.unreadableCount += 1
                continue
            }
            var subdirectories: [QueueItem] = []
            for child in children {
                if token?.isCancelled == true { queue.finish(); break loop }
                let count = counter.reserve()
                if count < 0 {
                    queue.finish()
                    break loop
                }
                if count.isMultiple(of: 2_000) {
                    progress(ScanProgress(phase: "刷新 \(root.path)", scannedEntries: count, fraction: nil))
                }
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else {
                    result.unreadableCount += 1
                    continue
                }
                guard values.isSymbolicLink != true else { continue }
                if retainTree {
                    let normalized = child.standardizedFileURL
                    let size = Int64(values.fileSize ?? 0)
                    result.childrenByPath[directoryPath, default: []].append(DirectoryEntry(id: normalized.path, name: normalized.lastPathComponent, path: normalized.path, size: size, sizeText: CleanMacFormat.bytes(size), depth: 1, isHidden: values.isHidden == true, isDirectory: values.isDirectory == true))
                }
                if values.isDirectory == true {
                    subdirectories.append(QueueItem(url: child, stopPath: stopPath))
                    if item.url.standardizedFileURL.path == root.path {
                        let normalized = child.standardizedFileURL
                        result.directChildren[normalized.path] = normalized
                    }
                    continue
                }
                guard let size = values.fileSize, size > 0 else { continue }
                var parent = child.deletingLastPathComponent().standardizedFileURL
                while true {
                    result.folderSizes[parent.path, default: 0] += Int64(size)
                    if parent.path == root.standardizedFileURL.path || parent.path == "/" { break }
                    parent.deleteLastPathComponent()
                }
            }
            queue.push(subdirectories)
        }
        return result
    }

    /// 递归统计目录（或文件）的总大小，跳过符号链接，支持取消。
    func sizeOf(_ url: URL, token: ScanToken? = nil) -> Int64 {
        // 符号链接根只按链接本身计，避免删除时 freed 字节被高估
        if let linkValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
           linkValues.isSymbolicLink == true {
            return Int64(linkValues.fileSize ?? 0)
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        var stack = [url]
        var visited = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        while let directory = stack.popLast(), visited < maxEntries {
            if token?.isCancelled == true { break }
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
            } catch {
                continue
            }
            for child in children {
                if token?.isCancelled == true { return total }
                guard visited < maxEntries else { break }
                visited += 1
                guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    stack.append(child)
                } else if let size = values.fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }
}
