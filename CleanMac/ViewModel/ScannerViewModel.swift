import Foundation
import SwiftUI
import Combine

@MainActor
final class ScannerViewModel: ObservableObject {
    // 磁盘分析
    @Published private(set) var result: ScanResult?
    @Published private(set) var isScanning = false
    @Published private(set) var progress = ScanProgress(phase: "准备分析", scannedEntries: 0, fraction: nil)
    @Published private(set) var libraryItems: [DiskItem] = []
    @Published var librarySource: LibrarySource = .npm
    @Published private(set) var cacheStatus = ""
    @Published private(set) var completedDiskRefresh: DiskRefreshCompletion?
    @Published private(set) var isCancelling = false
    @Published private(set) var isCommittingSnapshot = false
    private let cacheStore: ScanCacheStore
    typealias ScanOperation = @Sendable (ScanToken, @escaping @Sendable (ScanProgress) -> Void) async -> ScanResult
    typealias DirectoryOperation = @Sendable (String, ScanToken, @escaping @Sendable (ScanProgress) -> Void) async -> DirectoryScanResult
    private let scanOperation: ScanOperation
    private let directoryOperation: DirectoryOperation
    private enum SnapshotStage { case none, preparing, ready }
    private var snapshotStage: SnapshotStage = .none
    private var libraryResults: [String: [DiskItem]] = [:]
    private var cacheSavedAt: Date?

    // 文件系统浏览
    @Published private(set) var filesystemRows: [DirectoryEntry] = []

    // 智能清理
    @Published private(set) var cleanupCategories: [JunkCategory] = []
    @Published private(set) var checkedJunkIDs = Set<String>()
    @Published private(set) var cleanupReport: CleanupReport?
    @Published private(set) var isCleaning = false
    @Published private(set) var cleaningPhase = ""

    // 磁盘卷
    @Published private(set) var volumes: [VolumeInfo] = []

    // 卸载器
    @Published private(set) var apps: [AppEntry] = []
    @Published var selectedAppID: String?
    @Published private(set) var relatedItems: [JunkItem] = []
    @Published private(set) var checkedRelatedIDs = Set<String>()

    private var token: ScanToken?
    var canCancelScan: Bool { isScanning && token != nil && !isCancelling && !isCommittingSnapshot }

    private let filesystemRoots: [DirectoryEntry] = [
        DirectoryEntry(id: "/", name: "/", path: "/", size: 0, sizeText: "未刷新", depth: 0, isHidden: false),
        DirectoryEntry(id: "/Users", name: "Users", path: "/Users", size: 0, sizeText: "未刷新", depth: 0, isHidden: false),
        DirectoryEntry(id: FileManager.default.homeDirectoryForCurrentUser.path, name: "用户主目录", path: FileManager.default.homeDirectoryForCurrentUser.path, size: 0, sizeText: "未刷新", depth: 0, isHidden: false),
        DirectoryEntry(id: "/Applications", name: "应用程序", path: "/Applications", size: 0, sizeText: "未刷新", depth: 0, isHidden: false),
        DirectoryEntry(id: "/Volumes", name: "已挂载磁盘", path: "/Volumes", size: 0, sizeText: "未刷新", depth: 0, isHidden: false)
    ]
    private var directoryChildren: [String: [DirectoryEntry]] = [:]
    private var expandedDirectories = Set<String>()
    /// 已刷新目录的完整占用（含所有子孙），供侧边栏父目录行与详情页头部显示。
    @Published private(set) var directorySizes: [String: Int64] = [:]
    @Published private(set) var directoryWarnings: [String: String] = [:]

    init(cacheStore: ScanCacheStore = ScanCacheStore(), restoreCache: Bool = true, observeVolumes: Bool = true,
         scanOperation: @escaping ScanOperation = { token, progress in
             await DiskScanner().scan(token: token, progress: progress)
         },
         directoryOperation: @escaping DirectoryOperation = { path, token, progress in
             await DirectoryScanner().scanDirectory(at: URL(fileURLWithPath: path), token: token, retainTree: true, progress: progress)
         }) {
        self.cacheStore = cacheStore
        self.scanOperation = scanOperation
        self.directoryOperation = directoryOperation
        filesystemRows = filesystemRoots
        if restoreCache {
            beginBusy("正在读取上次扫描记录")
            Task {
                do {
                    if let cache = try await cacheStore.load() {
                        let roots = filesystemRoots
                        let rows = try await Task.detached(priority: .utility) {
                            try ScanPublicationPreparer.filesystemRows(roots: roots, children: cache.directoryChildren,
                                sizes: cache.directorySizes, expanded: cache.expandedDirectories, token: ScanToken())
                        }.value
                        cacheSavedAt = cache.savedAt
                        result = cache.result
                        directoryChildren = cache.directoryChildren
                        directorySizes = cache.directorySizes
                        directoryWarnings = cache.directoryWarnings
                        libraryItems = cache.libraryItems
                        librarySource = cache.librarySource.flatMap(LibrarySource.init(rawValue:)) ?? .npm
                        libraryResults = cache.libraryResults ?? [librarySource.rawValue: cache.libraryItems]
                        expandedDirectories = cache.expandedDirectories
                        cacheStatus = "已载入缓存 · \(cache.savedAt.formatted(date: .abbreviated, time: .shortened))"
                        filesystemRows = rows
                    }
                } catch {
                    cacheStatus = "无法读取缓存：\(error.localizedDescription)"
                }
                isScanning = false
            }
        }
        if observeVolumes { loadVolumes() }
    }

    private func persistScanCache() async {
        isCommittingSnapshot = true
        let previousProgress = progress
        progress = ScanProgress(phase: "正在保存扫描记录（提交阶段）", scannedEntries: progress.scannedEntries, fraction: nil)
        defer { isCommittingSnapshot = false; progress = previousProgress }
        // The tree already lives in directoryChildren/directorySizes; avoid
        // encoding a second copy inside the overview scan result.
        var summary = result
        summary?.directorySnapshot = nil
        let cache = PersistedScanCache(result: summary, directoryChildren: directoryChildren,
            directorySizes: directorySizes, directoryWarnings: directoryWarnings,
            libraryItems: libraryItems, librarySource: librarySource.rawValue,
            expandedDirectories: expandedDirectories, libraryResults: libraryResults)
        do {
            try await cacheStore.save(cache)
            cacheSavedAt = cache.savedAt
            cacheStatus = "缓存已保存 · \(cache.savedAt.formatted(date: .abbreviated, time: .shortened))"
        } catch {
            cacheStatus = "缓存保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 通用

    /// Read-only export of the current snapshot; generating an overview never
    /// refreshes directories or changes the persistent scan cache.
    func overviewCache() -> PersistedScanCache? {
        guard !isScanning, !isCleaning, !directoryChildren.isEmpty else { return nil }
        var summary = result
        summary?.directorySnapshot = nil
        return PersistedScanCache(savedAt: cacheSavedAt ?? Date(), result: summary,
            directoryChildren: directoryChildren, directorySizes: directorySizes,
            directoryWarnings: directoryWarnings, libraryItems: libraryItems,
            librarySource: librarySource.rawValue, expandedDirectories: expandedDirectories, libraryResults: libraryResults)
    }

    func cancelScan() {
        guard canCancelScan else { return }
        token?.cancel()
        isCancelling = true
        progress = ScanProgress(phase: "正在取消，保留上次扫描记录…", scannedEntries: progress.scannedEntries, fraction: nil)
    }

    private func makeToken() -> ScanToken {
        let newToken = ScanToken()
        token = newToken
        isCancelling = false
        return newToken
    }

    private func beginBusy(_ phase: String) {
        snapshotStage = .none
        isScanning = true
        progress = ScanProgress(phase: phase, scannedEntries: 0, fraction: nil)
    }

    /// 开始清理类操作：同时重置进度，避免遮罩显示上一次扫描的陈旧进度。
    private func beginCleaning(_ phase: String) {
        isCleaning = true
        cleaningPhase = phase
        progress = ScanProgress(phase: phase, scannedEntries: 0, fraction: nil)
    }

    /// 合并进度更新：多个 worker 回调乱序到达主线程时保持计数单调，进度条不回退。
    private func applyProgress(_ update: ScanProgress, for scanToken: ScanToken) {
        guard isScanning, token === scanToken, !scanToken.isCancelled, !isCommittingSnapshot, snapshotStage == .none else { return }
        if update.scannedEntries >= progress.scannedEntries {
            progress = update
        }
    }

    // MARK: - 磁盘分析

    func scan() {
        guard !isScanning else { return }
        beginBusy("准备分析")
        let scanToken = makeToken()
        let previous = publicationState()
        let roots = filesystemRoots
        let operation = scanOperation
        let work = Task.detached(priority: .userInitiated) {
            let result = await operation(scanToken) { update in
                Task { @MainActor in
                    self.applyProgress(update, for: scanToken)
                }
            }
            try scanToken.checkCancellation()
            await self.beginSnapshotPreparation(token: scanToken)
            return try ScanPublicationPreparer.fullScan(result, previous: previous, roots: roots, token: scanToken) { stage, count in
                Task { @MainActor in self.applyPreparationProgress(stage: stage, count: count, token: scanToken) }
            }
        }
        Task { @MainActor in
            do {
                let prepared = try await work.value
                try await self.publishPreparedSnapshot(prepared, token: scanToken, refreshedRoot: nil,
                    entryCount: prepared.summary?.entryCount ?? 0)
            } catch {
                self.finishCancelledPublication(token: scanToken)
            }
        }
    }

    private func publicationState() -> PreparedScanPublication {
        PreparedScanPublication(summary: result, children: directoryChildren, sizes: directorySizes,
            warnings: directoryWarnings, expanded: expandedDirectories, rows: filesystemRows)
    }

    private func beginSnapshotPreparation(token currentToken: ScanToken) {
        guard token === currentToken, !currentToken.isCancelled else { return }
        snapshotStage = .preparing
        progress = ScanProgress(phase: "正在整理扫描结果", scannedEntries: progress.scannedEntries, fraction: nil)
    }

    private func applyPreparationProgress(stage: String, count: Int, token currentToken: ScanToken) {
        guard isScanning, token === currentToken, !currentToken.isCancelled, snapshotStage == .preparing else { return }
        progress = ScanProgress(phase: "正在整理扫描结果：\(stage) \(count) 项", scannedEntries: progress.scannedEntries, fraction: nil)
    }

    private func publishPreparedSnapshot(_ prepared: PreparedScanPublication, token currentToken: ScanToken,
                                         refreshedRoot: String?, entryCount: Int) async throws {
        try currentToken.checkCancellation()
        snapshotStage = .ready
        progress = ScanProgress(phase: "扫描结果已就绪，准备发布", scannedEntries: entryCount, fraction: nil)
        // Give already queued Cancel events a chance to run before the atomic
        // publication boundary. No old UI state or disk cache changes before it.
        await Task.yield()
        try currentToken.checkCancellation()
        guard token === currentToken else { throw CancellationError() }
        result = prepared.summary
        directoryChildren = prepared.children
        directorySizes = prepared.sizes
        directoryWarnings = prepared.warnings
        expandedDirectories = prepared.expanded
        filesystemRows = prepared.rows
        progress = ScanProgress(phase: refreshedRoot == nil ? "分析完成" : "目录刷新完成", scannedEntries: entryCount, fraction: 1)
        await persistScanCache()
        snapshotStage = .none
        isScanning = false
        isCancelling = false
        completedDiskRefresh = DiskRefreshCompletion(refreshedRoot: refreshedRoot)
    }

    private func finishCancelledPublication(token currentToken: ScanToken) {
        guard token === currentToken else { return }
        snapshotStage = .none
        progress = ScanProgress(phase: "分析已取消，保留上次记录", scannedEntries: progress.scannedEntries, fraction: nil)
        isScanning = false
        isCancelling = false
    }

    // MARK: - 智能清理

    var selectedJunkItems: [JunkItem] {
        cleanupCategories
            .flatMap(\.items)
            .filter { checkedJunkIDs.contains($0.id) && !$0.permanentDeleteOnly }
    }

    var selectedJunkSize: Int64 {
        selectedJunkItems.reduce(0) { $0 + $1.size }
    }

    var trashItems: [JunkItem] {
        cleanupCategories.first(where: { $0.id == "trash" })?.items ?? []
    }

    var trashSize: Int64 {
        trashItems.reduce(0) { $0 + $1.size }
    }

    func scanCleanup() {
        guard !isScanning else { return }
        beginBusy("扫描垃圾文件")
        let scanToken = makeToken()
        let work = Task.detached(priority: .userInitiated) {
            let scanner = JunkScanner()
            return await scanner.scan(token: scanToken) { update in
                Task { @MainActor in
                    self.applyProgress(update, for: scanToken)
                }
            }
        }
        Task { @MainActor in
            let categories = await work.value
            if scanToken.isCancelled {
                self.progress = ScanProgress(phase: "垃圾扫描已取消", scannedEntries: 0, fraction: nil)
                self.isScanning = false
                return
            }
            self.cleanupCategories = categories
            var defaults = Set<String>()
            for category in categories where category.defaultChecked {
                for item in category.items where !item.permanentDeleteOnly {
                    defaults.insert(item.id)
                }
            }
            self.checkedJunkIDs = defaults
            self.cleanupReport = nil
            self.progress = ScanProgress(phase: "垃圾扫描完成", scannedEntries: categories.reduce(0) { $0 + $1.items.count }, fraction: 1)
            self.isScanning = false
        }
    }

    func setJunkChecked(_ item: JunkItem, _ checked: Bool) {
        if checked {
            checkedJunkIDs.insert(item.id)
        } else {
            checkedJunkIDs.remove(item.id)
        }
    }

    func selectAllJunk() {
        for category in cleanupCategories {
            for item in category.items where !item.permanentDeleteOnly {
                checkedJunkIDs.insert(item.id)
            }
        }
    }

    func deselectAllJunk() {
        checkedJunkIDs.removeAll()
    }

    func setCategoryChecked(_ category: JunkCategory, _ checked: Bool) {
        for item in category.items where !item.permanentDeleteOnly {
            if checked {
                checkedJunkIDs.insert(item.id)
            } else {
                checkedJunkIDs.remove(item.id)
            }
        }
    }

    func isCategoryFullyChecked(_ category: JunkCategory) -> Bool {
        let eligible = category.items.filter { !$0.permanentDeleteOnly }
        guard !eligible.isEmpty else { return false }
        return eligible.allSatisfy { checkedJunkIDs.contains($0.id) }
    }

    /// 把勾选的垃圾移入废纸篓（可恢复）。
    func runCleanup() {
        guard !isCleaning, !isScanning else { return }
        let paths = selectedJunkItems.map(\.path)
        guard !paths.isEmpty else { return }
        beginCleaning("准备移入废纸篓")
        let scanToken = makeToken()
        let work = Task.detached(priority: .userInitiated) {
            let engine = CleanupEngine()
            return engine.moveToTrash(paths, token: scanToken) { done, total, path in
                Task { @MainActor in
                    self.cleaningPhase = "已处理 \(done)/\(total)：\(URL(fileURLWithPath: path).lastPathComponent)"
                    self.progress = ScanProgress(phase: self.cleaningPhase, scannedEntries: done, fraction: total > 0 ? Double(done) / Double(total) : nil)
                }
            }
        }
        Task { @MainActor in
            let report = await work.value
            self.cleanupReport = report
            self.isCleaning = false
            self.scanCleanup()
        }
    }

    func dismissCleanupReport() {
        cleanupReport = nil
    }

    /// 清空废纸篓（永久删除，不可恢复）。
    func emptyTrash() {
        guard !isCleaning, !isScanning else { return }
        let paths = trashItems.map(\.path)
        guard !paths.isEmpty else { return }
        beginCleaning("准备清空废纸篓")
        let scanToken = makeToken()
        let work = Task.detached(priority: .userInitiated) {
            let engine = CleanupEngine()
            return engine.permanentlyDelete(paths, token: scanToken) { done, total, path in
                Task { @MainActor in
                    self.cleaningPhase = "已删除 \(done)/\(total)"
                    self.progress = ScanProgress(phase: self.cleaningPhase, scannedEntries: done, fraction: total > 0 ? Double(done) / Double(total) : nil)
                }
            }
        }
        Task { @MainActor in
            let report = await work.value
            self.cleanupReport = report
            self.isCleaning = false
            self.scanCleanup()
        }
    }

    /// 把任意路径移入废纸篓（大文件、残留、开发库条目等）。
    func trashSingleItem(_ path: String, completion: @escaping @MainActor (CleanupReport) -> Void) {
        guard !isCleaning else { return }
        beginCleaning("正在移入废纸篓")
        let work = Task.detached(priority: .userInitiated) {
            let engine = CleanupEngine()
            return engine.moveToTrash([path]) { done, total, _ in
                Task { @MainActor in
                    self.cleaningPhase = "已处理 \(done)/\(total)"
                    self.progress = ScanProgress(phase: self.cleaningPhase, scannedEntries: done, fraction: total > 0 ? Double(done) / Double(total) : nil)
                }
            }
        }
        Task { @MainActor in
            let report = await work.value
            self.isCleaning = false
            completion(report)
        }
    }

    // MARK: - 磁盘卷

    func loadVolumes() {
        let work = Task.detached(priority: .utility) {
            VolumeScanner().volumes()
        }
        Task { @MainActor in
            self.volumes = await work.value
        }
    }

    // MARK: - 卸载器

    func scanUninstaller() {
        guard !isScanning else { return }
        beginBusy("读取已安装应用")
        let scanToken = makeToken()
        let work = Task.detached(priority: .userInitiated) {
            let scanner = UninstallerScanner()
            return await scanner.apps(token: scanToken) { update in
                Task { @MainActor in
                    self.applyProgress(update, for: scanToken)
                }
            }
        }
        Task { @MainActor in
            let appList = await work.value
            self.apps = appList
            self.selectedAppID = nil
            self.relatedItems = []
            self.checkedRelatedIDs = []
            self.progress = ScanProgress(phase: "已读取 \(appList.count) 个应用", scannedEntries: appList.count, fraction: 1)
            self.isScanning = false
        }
    }

    var selectedApp: AppEntry? {
        guard let id = selectedAppID else { return nil }
        return apps.first { $0.id == id }
    }

    /// 加载所选应用的相关数据目录。
    func loadRelatedData(for id: String?) {
        relatedItems = []
        checkedRelatedIDs = []
        guard let app = apps.first(where: { $0.id == id }) else { return }
        let work = Task.detached(priority: .userInitiated) {
            UninstallerScanner().relatedData(for: app)
        }
        Task { @MainActor in
            let items = await work.value
            self.relatedItems = items
            self.checkedRelatedIDs = Set(items.map(\.id))
        }
    }

    func setRelatedChecked(_ item: JunkItem, _ checked: Bool) {
        if checked {
            checkedRelatedIDs.insert(item.id)
        } else {
            checkedRelatedIDs.remove(item.id)
        }
    }

    /// 卸载应用：应用本身 + 勾选的相关数据一并移入废纸篓。
    func uninstallSelectedApp() {
        guard !isCleaning, !isScanning, let app = selectedApp, !app.isSystemApp else { return }
        var paths: [String] = []
        let expanded = CleanMacPath.expand(app.path, home: FileManager.default.homeDirectoryForCurrentUser.path)
        paths.append(expanded)
        paths += relatedItems.filter { checkedRelatedIDs.contains($0.id) }.map(\.path)
        beginCleaning("正在卸载 \(app.name)")
        let work = Task.detached(priority: .userInitiated) {
            CleanupEngine().moveToTrash(paths) { done, total, _ in
                Task { @MainActor in
                    self.cleaningPhase = "正在卸载 \(app.name)（\(done)/\(total)）"
                    self.progress = ScanProgress(phase: self.cleaningPhase, scannedEntries: done, fraction: total > 0 ? Double(done) / Double(total) : nil)
                }
            }
        }
        Task { @MainActor in
            let report = await work.value
            self.cleanupReport = report
            self.isCleaning = false
            self.scanUninstaller()
        }
    }

    // MARK: - 文件系统浏览

    func isDirectoryExpanded(_ path: String) -> Bool {
        expandedDirectories.contains(path)
    }

    func children(for path: String) -> [DirectoryEntry] {
        directoryChildren[URL(fileURLWithPath: path).standardizedFileURL.path] ?? []
    }

    /// 目录的完整占用（刷新后可用）。
    func directorySize(for path: String) -> Int64? {
        directorySizes[URL(fileURLWithPath: path).standardizedFileURL.path]
    }

    func refreshDirectory(_ path: String) {
        guard !isScanning else { return }
        beginBusy("读取目录 \(path)")
        let scanToken = makeToken()
        let previous = publicationState()
        let roots = filesystemRoots
        let operation = directoryOperation
        let work = Task.detached(priority: .userInitiated) {
            let outcome = await operation(path, scanToken) { update in
                Task { @MainActor in
                    self.applyProgress(update, for: scanToken)
                }
            }
            try scanToken.checkCancellation()
            await self.beginSnapshotPreparation(token: scanToken)
            let prepared = try ScanPublicationPreparer.directoryRefresh(outcome, root: path, previous: previous,
                roots: roots, token: scanToken) { stage, count in
                Task { @MainActor in self.applyPreparationProgress(stage: stage, count: count, token: scanToken) }
            }
            return (snapshot: prepared, entryCount: outcome.entries.count)
        }
        Task { @MainActor in
            do {
                let prepared = try await work.value
                try await self.publishPreparedSnapshot(prepared.snapshot, token: scanToken,
                    refreshedRoot: URL(fileURLWithPath: path).standardizedFileURL.path, entryCount: prepared.entryCount)
            } catch {
                self.finishCancelledPublication(token: scanToken)
            }
        }
    }

    func toggleDirectory(_ path: String) {
        if expandedDirectories.contains(path) {
            expandedDirectories.remove(path)
        } else if directoryChildren[path] != nil {
            expandedDirectories.insert(path)
        } else {
            expandedDirectories.insert(path)
        }
        rebuildFilesystemRows()
    }

    // MARK: - 开发库

    func showCachedLibraries(_ source: LibrarySource) {
        librarySource = source
        libraryItems = libraryResults[source.rawValue] ?? []
    }

    func queryLibraries(_ source: LibrarySource) {
        guard !isScanning else { return }
        beginBusy("查询 \(source.rawValue) 库")
        let scanToken = makeToken()
        let work = Task.detached(priority: .userInitiated) {
            await LibraryScanner().scan(source: source, token: scanToken) { update in
                Task { @MainActor in
                    self.applyProgress(update, for: scanToken)
                }
            }
        }
        Task { @MainActor in
            let items = await work.value
            guard !scanToken.isCancelled else {
                self.isScanning = false
                return
            }
            self.libraryItems = items
            self.librarySource = source
            self.libraryResults[source.rawValue] = items
            self.progress = ScanProgress(phase: "库查询完成", scannedEntries: items.count, fraction: 1)
            await self.persistScanCache()
            self.isScanning = false
        }
    }

    private func rebuildFilesystemRows() {
        filesystemRows = (try? ScanPublicationPreparer.filesystemRows(roots: filesystemRoots, children: directoryChildren,
            sizes: directorySizes, expanded: expandedDirectories, token: ScanToken())) ?? filesystemRoots
    }
}
