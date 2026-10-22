import Foundation

/// 扫描系统中可以安全清理的垃圾文件：用户缓存、浏览器缓存、
/// 日志、开发垃圾（Xcode）、旧下载以及废纸篓。
nonisolated struct JunkScanner {
    private let fileManager = FileManager.default
    private let home: URL
    private let maxItemsPerCategory = 300
    private let workerCount = 4

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func scan(token: ScanToken? = nil, progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async -> [JunkCategory] {
        let specs: [(String, String, String, String, Bool, [URL])] = [
            ("userCaches", "用户缓存", "internaldrive.fill", "~/Library/Caches 中各类应用产生的缓存，通常可以安全重建。", true, [home.appendingPathComponent("Library/Caches")]),
            ("browserCaches", "浏览器缓存", "globe", "Safari / Chrome / Edge / Firefox 等浏览器的网页缓存。", true, browserCacheRoots()),
            ("logs", "日志与报告", "doc.text", "~/Library/Logs 下的应用日志文件。", true, [home.appendingPathComponent("Library/Logs")]),
            ("developerJunk", "开发垃圾", "hammer", "Xcode DerivedData、旧设备支持文件与模拟器缓存。", true, developerJunkRoots()),
            ("trash", "废纸篓", "trash", "当前用户废纸篓中的内容。清空后无法恢复，请确认后再操作。", false, [home.appendingPathComponent(".Trash")])
        ]

        var categories: [JunkCategory] = []
        for spec in specs {
            if token?.isCancelled == true { break }
            let (id, name, icon, detail, defaultChecked, roots) = spec
            var items: [JunkItem] = []
            for root in roots {
                if token?.isCancelled == true { break }
                items += await itemsIn(root, categoryID: id, token: token)
            }
            // 去重、排序
            var seen = Set<String>()
            let unique = items.filter { seen.insert($0.path).inserted }.sorted { $0.size > $1.size }
            let limited = Array(unique.prefix(maxItemsPerCategory))
            categories.append(JunkCategory(id: id, name: name, icon: icon, detail: detail, defaultChecked: defaultChecked, items: limited))
            progress(ScanProgress(phase: "已完成「\(name)」", scannedEntries: categories.count, fraction: Double(categories.count) / Double(specs.count)))
        }

        // 旧下载（单独处理，默认不勾选，只统计文件）
        categories.append(oldDownloadsCategory(token: token, progress: progress))
        progress(ScanProgress(phase: "已完成「旧下载」", scannedEntries: categories.count, fraction: 1))
        return categories
    }

    /// 返回 root 的直接子项（文件与目录）作为垃圾条目，
    /// 由 4 个 worker 并行计算每个子项的大小。
    private func itemsIn(_ root: URL, categoryID: String, token: ScanToken?) async -> [JunkItem] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let children = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: []) else { return [] }
        let permanent = categoryID == "trash"
        let box = WorkIndex(limit: children.count)
        let taskCount = min(workerCount, max(1, children.count))

        return await withTaskGroup(of: [JunkItem].self, returning: [JunkItem].self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    var local: [JunkItem] = []
                    while let index = box.nextIndex(), token?.isCancelled != true {
                        let child = children[index]
                        guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                        let size: Int64
                        if values.isDirectory == true {
                            size = DirectoryScanner().sizeOf(child, token: token)
                        } else {
                            size = Int64(values.fileSize ?? 0)
                        }
                        guard size > 0 else { continue }
                        local.append(JunkItem(
                            id: child.path,
                            path: child.path,
                            displayPath: displayPath(child.path),
                            name: child.lastPathComponent,
                            size: size,
                            sizeText: CleanMacFormat.bytes(size),
                            categoryID: categoryID,
                            permanentDeleteOnly: permanent
                        ))
                    }
                    return local
                }
            }
            var merged: [JunkItem] = []
            for await local in group {
                merged.append(contentsOf: local)
            }
            return merged
        }
    }

    private func oldDownloadsCategory(token: ScanToken?, progress: @escaping @Sendable (ScanProgress) -> Void) -> JunkCategory {
        let root = home.appendingPathComponent("Downloads")
        var items: [JunkItem] = []
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var stack = [root]
        var visited = 0
        while let directory = stack.popLast(), visited < 100_000, items.count < maxItemsPerCategory {
            if token?.isCancelled == true { break }
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
            } catch {
                continue
            }
            for child in children {
                guard items.count < maxItemsPerCategory else { break }
                visited += 1
                guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    stack.append(child)
                    continue
                }
                guard let modified = values.contentModificationDate, modified < cutoff, let size = values.fileSize, size > 0 else { continue }
                items.append(JunkItem(
                    id: child.path,
                    path: child.path,
                    displayPath: displayPath(child.path),
                    name: child.lastPathComponent,
                    size: Int64(size),
                    sizeText: CleanMacFormat.bytes(Int64(size)),
                    categoryID: "oldDownloads",
                    permanentDeleteOnly: false
                ))
            }
        }
        return JunkCategory(
            id: "oldDownloads",
            name: "下载目录旧文件",
            icon: "arrow.down.circle",
            detail: "~/Downloads 中超过 30 天未修改的文件（默认不勾选，请自行确认）。",
            defaultChecked: false,
            items: items.sorted { $0.size > $1.size }
        )
    }

    private func browserCacheRoots() -> [URL] {
        var roots: [URL] = []
        func add(_ path: String) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) { roots.append(url) }
        }
        // Safari
        add(home.path + "/Library/Caches/com.apple.Safari")
        add(home.path + "/Library/Caches/com.apple.Safari.SafeBrowsing")
        add(home.path + "/Library/Containers/com.apple.Safari/Data/Library/Caches")
        // Chromium 系浏览器：主缓存 + 各 Profile 的缓存子目录
        let chromium: [(vendor: String, browser: String)] = [
            ("Google", "Chrome"),
            ("Microsoft", "Edge"),
            ("BraveSoftware", "Brave-Browser"),
            ("Opera Software", "Opera"),
            ("The Browser Company", "Arc"),
            ("Chromium", "Chromium"),
            ("Vivaldi", "Vivaldi")
        ]
        let profileCacheDirs = ["Cache", "Code Cache", "GPUCache", "DawnCache", "Service Worker", "Feature Engagement Tracker"]
        for (vendor, browser) in chromium {
            add(home.path + "/Library/Caches/\(vendor)/\(browser)")
            let profiles = URL(fileURLWithPath: home.path + "/Library/Application Support/\(vendor)/\(browser)")
            guard let profileChildren = try? fileManager.contentsOfDirectory(at: profiles, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { continue }
            for profile in profileChildren where (try? profile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                for cacheDir in profileCacheDirs {
                    add(profile.path + "/\(cacheDir)")
                }
            }
        }
        // Firefox
        add(home.path + "/Library/Caches/Firefox")
        let ffProfiles = URL(fileURLWithPath: home.path + "/Library/Application Support/Firefox/Profiles")
        if let profileChildren = try? fileManager.contentsOfDirectory(at: ffProfiles, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
            for profile in profileChildren where (try? profile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                add(profile.path + "/cache2")
                add(profile.path + "/storage")
            }
        }
        return roots
    }

    private func developerJunkRoots() -> [URL] {
        [
            home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
            home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"),
            home.appendingPathComponent("Library/Developer/Xcode/Archives"),
            home.appendingPathComponent("Library/Developer/CoreSimulator/Caches")
        ].filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func displayPath(_ path: String) -> String {
        CleanMacPath.display(path, home: home.path)
    }
}
