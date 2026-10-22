import Foundation

/// 全盘扫描 worker 的局部结果（最后合并，无锁竞争）。
nonisolated struct ScanWorkerResult: Sendable {
    var topFiles: [DiskItem] = []
    var folderSizes: [String: Int64] = [:]
    var errors: [String] = []
    var childrenByPath: [String: [DirectoryEntry]] = [:]
}

/// 扫描指定根目录，统计大文件、大型目录与应用残留。
/// 使用 4 个并行 worker 共享一个目录队列，显著缩短全盘分析时间。
nonisolated struct DiskScanner {
    private let fileManager = FileManager.default
    private let maxResults = 250
    private let progressInterval = 2_000
    private let workerCount = 4

    private var homeURL: URL { fileManager.homeDirectoryForCurrentUser }

    private var roots: [URL] {
        [
            URL(fileURLWithPath: "/Users"),
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/Library"),
            URL(fileURLWithPath: "/opt"),
            URL(fileURLWithPath: "/usr/local")
        ].filter { fileManager.fileExists(atPath: $0.path) }
    }

    func scan(token: ScanToken? = nil, progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async -> ScanResult {
        let start = Date()
        let installedApps = AppInventory().apps(token: token)
        progress(ScanProgress(phase: "已读取 \(installedApps.count) 个已安装应用，启动并行分析", scannedEntries: 0, fraction: nil))

        let queue = DirectoryQueue(workerCount: workerCount)
        let counter = EntryCounter(limit: Int.max)
        queue.push(roots.map { QueueItem(url: $0, stopPath: $0.deletingLastPathComponent().standardizedFileURL.path) })

        var merged = await withTaskGroup(of: ScanWorkerResult.self, returning: ScanWorkerResult.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    self.workerScan(queue: queue, counter: counter, token: token, installedApps: installedApps, progress: progress)
                }
            }
            var merged = ScanWorkerResult()
            for await result in group {
                if token?.isCancelled == true { queue.finish(); continue }
                merged.topFiles.append(contentsOf: result.topFiles)
                merged.errors.append(contentsOf: result.errors)
                merged.childrenByPath.merge(result.childrenByPath) { _, new in new }
                for (path, size) in result.folderSizes {
                    if token?.isCancelled == true { break }
                    merged.folderSizes[path, default: 0] += size
                }
            }
            return merged
        }

        // 流式 top-K：不物化全部目录、不全量排序；
        // 受系统保护的根目录（/Users、/Applications 等）不进入可删除列表。
        let home = homeURL.path
        var topFolders: [DiskItem] = []
        var residues: [DiskItem] = []
        for (path, size) in merged.folderSizes {
            if token?.isCancelled == true { break }
            if CleanupEngine.isProtectedPath(path, home: home) { continue }
            let url = URL(fileURLWithPath: path)
            if topFolders.count < maxResults || size > (topFolders.last?.size ?? 0) {
                let item = makeItem(path: url, size: size, kind: .folder, installedApps: installedApps, isResidue: false, evidence: "", isHidden: CleanMacPath.isHidden(path))
                consider(item, in: &topFolders)
            }
            if isAppDataPath(url), let evidence = residueEvidence(for: url, apps: installedApps) {
                let base = makeItem(path: url, size: size, kind: .folder, installedApps: installedApps, isResidue: false, evidence: "", isHidden: CleanMacPath.isHidden(path))
                residues.append(DiskItem(id: base.id, name: base.name, absolutePath: base.absolutePath, path: base.path, size: base.size, sizeText: base.sizeText, source: "疑似已卸载应用残留", evidence: evidence, kind: base.kind, isResidue: true, isHidden: base.isHidden))
            }
        }
        let finalFiles = merged.topFiles.sorted { $0.size > $1.size }.prefix(maxResults).map { $0 }
        let entryCount = counter.current()
        let reachedLimit = counter.didReachLimit()

        for path in merged.childrenByPath.keys {
            if token?.isCancelled == true { break }
            merged.childrenByPath[path] = merged.childrenByPath[path]!.map { entry in
                guard entry.isDirectory else { return entry }
                let size = merged.folderSizes[entry.path, default: 0]
                return DirectoryEntry(id: entry.id, name: entry.name, path: entry.path, size: size, sizeText: CleanMacFormat.bytes(size), depth: 1, isHidden: entry.isHidden)
            }.sorted { $0.size > $1.size }
        }
        let snapshot = DirectoryScanResult(unreadableCount: merged.errors.count, cancelled: token?.isCancelled == true, childrenByPath: merged.childrenByPath, sizesByPath: merged.folderSizes)
        return ScanResult(
            generatedAt: CleanMacFormat.timestamp(),
            duration: Date().timeIntervalSince(start),
            entryCount: entryCount,
            installedApps: installedApps,
            largestFiles: finalFiles,
            largestFolders: topFolders,
            residues: residues.sorted { $0.size > $1.size }.prefix(maxResults).map { $0 },
            errors: Array(merged.errors.prefix(100)),
            scanLimitReached: reachedLimit,
            cancelled: token?.isCancelled == true,
            directorySnapshot: snapshot
        )
    }

    /// 单个并行 worker：从队列领取目录，枚举子项，子目录放回队列。
    private func workerScan(queue: DirectoryQueue, counter: EntryCounter, token: ScanToken?, installedApps: [InstalledApp], progress: @escaping @Sendable (ScanProgress) -> Void) -> ScanWorkerResult {
        var result = ScanWorkerResult()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isHiddenKey]

        loop: while true {
            if token?.isCancelled == true {
                queue.finish()
                break
            }
            guard let item = queue.popBlocking() else { break }
            let directoryPath = item.url.standardizedFileURL.path
            result.childrenByPath[directoryPath] = []
            result.folderSizes[directoryPath, default: 0] += 0
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(at: item.url, includingPropertiesForKeys: keys, options: [])
            } catch {
                result.errors.append("\(displayPath(item.url)): \(error.localizedDescription)")
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
                if count.isMultiple(of: progressInterval) {
                    progress(ScanProgress(phase: "并行分析中（\(workerCount) 线程）", scannedEntries: count, fraction: nil))
                }
                do {
                    let values = try child.resourceValues(forKeys: Set(keys))
                    if values.isSymbolicLink == true { continue }
                    let normalized = child.standardizedFileURL
                    let entrySize = Int64(values.fileSize ?? 0)
                    result.childrenByPath[directoryPath, default: []].append(DirectoryEntry(id: normalized.path, name: normalized.lastPathComponent, path: normalized.path, size: entrySize, sizeText: CleanMacFormat.bytes(entrySize), depth: 1, isHidden: values.isHidden == true, isDirectory: values.isDirectory == true))
                    if values.isDirectory == true {
                        subdirectories.append(QueueItem(url: child, stopPath: item.stopPath))
                        continue
                    }
                    guard let fileSize = values.fileSize, fileSize > 0 else { continue }
                    let size = Int64(fileSize)
                    let diskItem = makeItem(path: child, size: size, kind: .file, installedApps: installedApps, isResidue: false, evidence: "", isHidden: values.isHidden == true)
                    consider(diskItem, in: &result.topFiles)
                    addSize(size, toAncestorsOf: child.deletingLastPathComponent(), stopPath: item.stopPath, sizes: &result.folderSizes)
                } catch {
                    result.errors.append("\(displayPath(child)): \(error.localizedDescription)")
                }
            }
            queue.push(subdirectories)
        }
        return result
    }

    /// 只保留最大的 N 个文件：未满时追加排序，满时二分定位插入，
    /// 避免每条记录都触发整段排序。
    private func consider(_ item: DiskItem, in buffer: inout [DiskItem]) {
        if buffer.count < maxResults {
            buffer.append(item)
            buffer.sort { $0.size > $1.size }
            return
        }
        guard item.size > (buffer.last?.size ?? 0) else { return }
        var lo = 0
        var hi = buffer.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if buffer[mid].size >= item.size {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        buffer.insert(item, at: lo)
        buffer.removeLast()
    }

    private func addSize(_ size: Int64, toAncestorsOf directory: URL, stopPath: String, sizes: inout [String: Int64]) {
        var current = directory.standardizedFileURL
        while current.path != stopPath && current.path != "/" {
            sizes[current.path, default: 0] += size
            current.deleteLastPathComponent()
        }
    }

    private func makeItem(path: URL, size: Int64, kind: DiskItemKind, installedApps: [InstalledApp], isResidue: Bool, evidence: String, isHidden: Bool) -> DiskItem {
        DiskItem(
            id: path.path,
            name: path.lastPathComponent,
            absolutePath: path.path,
            path: displayPath(path),
            size: size,
            sizeText: CleanMacFormat.bytes(size),
            source: sourceLabel(path),
            evidence: evidence,
            kind: kind,
            isResidue: isResidue,
            isHidden: isHidden
        )
    }

    private func isAppDataPath(_ path: URL) -> Bool {
        let markers = ["Application Support", "Caches", "Containers", "Group Containers", "Logs", "Preferences", "Saved Application State"]
        return path.pathComponents.contains(where: markers.contains)
    }

    private func residueEvidence(for path: URL, apps: [InstalledApp]) -> String? {
        let pathText = path.path.lowercased()
        let identifiers = path.pathComponents.filter { component in
            component.range(of: "^(com|org|net|io|app)\\.[a-zA-Z0-9._-]+$", options: .regularExpression) != nil
        }
        if let identifier = identifiers.first {
            let installed = apps.contains { $0.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame }
            if !installed { return "发现 Bundle Identifier \(identifier)，但当前 /Applications 和 ~/Applications 没有对应应用" }
        }

        let generic = ["Application Support", "Caches", "Containers", "Group Containers", "Logs", "Preferences", "Saved Application State"]
        let leaf = path.lastPathComponent
        guard !generic.contains(leaf), !leaf.isEmpty else { return nil }
        let appNameTokens = apps.flatMap { [$0.name.lowercased(), $0.bundleIdentifier.lowercased()] }
        let normalizedLeaf = leaf.lowercased().replacingOccurrences(of: "-", with: " ")
        if !appNameTokens.contains(where: { !$0.isEmpty && normalizedLeaf.contains($0) }) && pathText.contains("/library/") {
            return "位于应用数据目录，但无法与当前已安装应用建立可靠匹配"
        }
        return nil
    }

    private func sourceLabel(_ path: URL) -> String {
        let components = Set(path.pathComponents)
        if components.contains("Caches") { return "应用缓存 / macOS 缓存" }
        if components.contains("Application Support") { return "应用数据（Application Support）" }
        if components.contains("Containers") || components.contains("Group Containers") { return "沙盒应用容器" }
        if components.contains("Logs") { return "应用日志" }
        if components.contains("Downloads") { return "下载目录" }
        if components.contains("Desktop") { return "桌面" }
        if components.contains("Applications") { return "已安装应用" }
        return "用户文件或其他来源"
    }

    private func displayPath(_ url: URL) -> String {
        CleanMacPath.display(url.path, home: homeURL.path)
    }
}
