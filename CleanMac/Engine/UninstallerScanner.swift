import Foundation

/// 卸载器：列出已安装应用（含大小）并查找应用相关数据目录。
nonisolated struct UninstallerScanner {
    private let fileManager = FileManager.default
    private let home: URL
    private let workerCount = 4

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// 列出已安装应用，并由 4 个 worker 并行计算每个应用包的占用大小。
    func apps(token: ScanToken? = nil, progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async -> [AppEntry] {
        let inventory = AppInventory().apps()
        let total = inventory.count
        let home = self.home
        let box = WorkIndex(limit: total)
        let taskCount = min(workerCount, max(1, total))

        let merged = await withTaskGroup(of: [AppEntry].self, returning: [AppEntry].self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    var local: [AppEntry] = []
                    while let index = box.nextIndex(), token?.isCancelled != true {
                        let app = inventory[index]
                        let expanded = CleanMacPath.expand(app.displayPath, home: home.path)
                        let size = DirectoryScanner().sizeOf(URL(fileURLWithPath: expanded), token: token)
                        let done = box.bumpProcessed()
                        progress(ScanProgress(phase: "计算大小：\(app.name)", scannedEntries: done, fraction: total > 0 ? Double(done) / Double(total) : 1))
                        local.append(AppEntry(
                            id: app.displayPath,
                            name: app.name,
                            bundleIdentifier: app.bundleIdentifier,
                            path: app.displayPath,
                            version: app.version,
                            size: size,
                            sizeText: CleanMacFormat.bytes(size),
                            isSystemApp: app.isSystemApp
                        ))
                    }
                    return local
                }
            }
            var merged: [AppEntry] = []
            for await local in group {
                merged.append(contentsOf: local)
            }
            return merged
        }
        return merged.sorted { $0.size > $1.size }
    }

    /// 查找与应用相关的数据目录（支持数据、缓存、偏好设置、容器等）。
    func relatedData(for app: AppEntry, token: ScanToken? = nil) -> [JunkItem] {
        let installed = InstalledApp(name: app.name, bundleIdentifier: app.bundleIdentifier, displayPath: app.path, version: app.version, isSystemApp: app.isSystemApp)
        return relatedPaths(for: installed)
            .map { path in
                let size = DirectoryScanner().sizeOf(URL(fileURLWithPath: path), token: token)
                let display = CleanMacPath.display(path, home: home.path)
                return JunkItem(
                    id: path,
                    path: path,
                    displayPath: display,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    size: size,
                    sizeText: CleanMacFormat.bytes(size),
                    categoryID: "related",
                    permanentDeleteOnly: false
                )
            }
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
    }

    private func relatedPaths(for app: InstalledApp) -> [String] {
        let bundleID = app.bundleIdentifier
        let name = app.name
        var candidates: [String] = []
        func add(_ path: String) {
            if fileManager.fileExists(atPath: path) { candidates.append(path) }
        }
        if !bundleID.isEmpty {
            add(home.path + "/Library/Application Support/\(bundleID)")
            add(home.path + "/Library/Caches/\(bundleID)")
            add(home.path + "/Library/Preferences/\(bundleID).plist")
            add(home.path + "/Library/Containers/\(bundleID)")
            add(home.path + "/Library/Application Scripts/\(bundleID)")
            add(home.path + "/Library/Saved Application State/\(bundleID).savedState")
            add(home.path + "/Library/WebKit/\(bundleID)")
            add(home.path + "/Library/HTTPStorages/\(bundleID)")
            add(home.path + "/Library/Logs/\(bundleID)")
            // Group Containers：名称等于 / 以 / 结尾包含 bundleID 的共享容器
            let groupDir = home.path + "/Library/Group Containers"
            if let groups = try? fileManager.contentsOfDirectory(atPath: groupDir) {
                for group in groups where group == bundleID || group.hasPrefix(bundleID + ".") || group.hasSuffix("." + bundleID) {
                    candidates.append(groupDir + "/" + group)
                }
            }
            // Preferences/ByHost 中带 bundleID 的偏好
            let byHost = home.path + "/Library/Preferences/ByHost"
            if let byHostFiles = try? fileManager.contentsOfDirectory(atPath: byHost) {
                for file in byHostFiles where file.hasPrefix(bundleID) && file.hasSuffix(".plist") {
                    candidates.append(byHost + "/" + file)
                }
            }
        }
        if !name.isEmpty && name != bundleID {
            add(home.path + "/Library/Application Support/\(name)")
            add(home.path + "/Library/Caches/\(name)")
            add(home.path + "/Library/Preferences/\(name).plist")
            add(home.path + "/Library/Logs/\(name)")
            add(home.path + "/Library/Saved Application State/\(name).savedState")
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

}
