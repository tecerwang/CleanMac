import Foundation
import Combine
import Darwin

@MainActor
final class PublicationEvents {
    var warningUpdates = 0
    var sizeUpdates = 0
    var rowUpdates = 0
    var resultUpdates = 0
    var completions = 0
    var objectChanges = 0
    var retainedWarnings: [String: String] = [:]
    var subscriptions = Set<AnyCancellable>()

    init(_ model: ScannerViewModel) {
        // Retain the latest published value just as a real subscriber can. The
        // old per-key @Published implementation becomes quadratic under this test.
        model.$directoryWarnings.dropFirst().sink { [weak self] value in
            self?.warningUpdates += 1
            self?.retainedWarnings = value
        }.store(in: &subscriptions)
        model.$directorySizes.dropFirst().sink { [weak self] _ in self?.sizeUpdates += 1 }.store(in: &subscriptions)
        model.$filesystemRows.dropFirst().sink { [weak self] _ in self?.rowUpdates += 1 }.store(in: &subscriptions)
        model.$result.dropFirst().sink { [weak self] _ in self?.resultUpdates += 1 }.store(in: &subscriptions)
        model.$completedDiskRefresh.dropFirst().sink { [weak self] _ in self?.completions += 1 }.store(in: &subscriptions)
        model.objectWillChange.sink { [weak self] _ in self?.objectChanges += 1 }.store(in: &subscriptions)
    }
}

@MainActor
final class MainActorHeartbeat {
    var beats = 0
    var maximumGap: TimeInterval = 0
    var task: Task<Void, Never>?

    func start() {
        task = Task { [weak self] in
            var previous = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                guard let self else { return }
                let now = Date()
                maximumGap = max(maximumGap, now.timeIntervalSince(previous))
                previous = now
                beats += 1
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

@main
struct ScanPublicationChecks {
    nonisolated static let fixtureRoot = "/Users/CleanMac-publication-fixture"

    nonisolated static func entry(_ path: String, directory: Bool = true, size: Int64 = 4) -> DirectoryEntry {
        DirectoryEntry(id: path, name: URL(fileURLWithPath: path).lastPathComponent, path: path,
            size: size, sizeText: "fixture", depth: 1, isHidden: false, isDirectory: directory)
    }

    nonisolated static func fixture(directoryCount: Int) -> ScanResult {
        var children: [String: [DirectoryEntry]] = [:]
        var sizes: [String: Int64] = [:]
        children.reserveCapacity(directoryCount + directoryCount / 1_000 + 2)
        sizes.reserveCapacity(directoryCount + directoryCount / 1_000 + 2)
        var branches: [String: [DirectoryEntry]] = [:]
        for index in 0..<directoryCount {
            let branch = fixtureRoot + "/branch-\(index / 1_000)"
            let path = branch + "/folder-\(index)"
            children[path] = [entry(path + "/payload.bin", directory: false)]
            sizes[path] = 4
            branches[branch, default: []].append(entry(path))
        }
        for (branch, entries) in branches {
            children[branch] = entries
            sizes[branch] = Int64(entries.count * 4)
        }
        children[fixtureRoot] = branches.keys.sorted().map { entry($0, size: sizes[$0]!) }
        sizes[fixtureRoot] = Int64(directoryCount * 4)
        children["/Users"] = [entry(fixtureRoot, size: sizes[fixtureRoot]!)]
        sizes["/Users"] = sizes[fixtureRoot]
        let snapshot = DirectoryScanResult(rootSize: sizes[fixtureRoot]!, unreadableCount: 3,
            childrenByPath: children, sizesByPath: sizes)
        return summary(count: directoryCount * 2, snapshot: snapshot)
    }

    nonisolated static func summary(count: Int, snapshot: DirectoryScanResult? = nil) -> ScanResult {
        ScanResult(generatedAt: "fixture", duration: 1, entryCount: count, installedApps: [],
            largestFiles: [], largestFolders: [], residues: [], errors: ["fixture permission denied"],
            scanLimitReached: false, cancelled: false, directorySnapshot: snapshot)
    }

    nonisolated static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    @MainActor
    static func waitUntilIdle(_ model: ScannerViewModel) async throws {
        let deadline = Date().addingTimeInterval(90)
        while model.isScanning {
            require(Date() < deadline, "Timed out waiting for ViewModel")
            try await Task.sleep(for: .milliseconds(10))
        }
        // Flush callbacks queued by a worker before cancellation/publication.
        try await Task.sleep(for: .milliseconds(30))
    }

    @MainActor
    static func seededModel(at url: URL, result: ScanResult,
                            directoryResult: DirectoryScanResult = DirectoryScanResult()) async throws -> ScannerViewModel {
        let oldPath = "/Users/keep-me"
        let obsolete = fixtureRoot + "/obsolete"
        let neighbor = fixtureRoot + "-neighbor"
        let seed = PersistedScanCache(result: summary(count: 7),
            directoryChildren: [oldPath: [], obsolete: [entry(obsolete + "/old.bin", directory: false)], neighbor: []],
            directorySizes: [oldPath: 99, obsolete: 8, neighbor: 101],
            directoryWarnings: [oldPath: "old warning", obsolete: "stale warning", neighbor: "keep neighbor"], libraryItems: [],
            librarySource: nil, expandedDirectories: ["/Users"])
        let store = ScanCacheStore(url: url)
        try await store.save(seed)
        let model = ScannerViewModel(cacheStore: store, observeVolumes: false,
            scanOperation: { _, _ in result }, directoryOperation: { _, _, _ in directoryResult })
        try await waitUntilIdle(model)
        require(model.result?.entryCount == 7, "Isolated seed did not restore")
        return model
    }

    @MainActor
    static func checkCancellation(_ result: ScanResult, at url: URL, checkpoint: String) async throws {
        let model = try await seededModel(at: url, result: result)
        let before = try Data(contentsOf: url)
        let oldWarnings = model.directoryWarnings
        let oldSizes = model.directorySizes
        let events = PublicationEvents(model)
        var requestedAt: Date?
        let observation = model.$progress.sink { progress in
            let target = checkpoint == "ready" ? progress.phase == "扫描结果已就绪，准备发布"
                : checkpoint == "preparing" && progress.phase.contains("正在整理扫描结果：告警")
            if target && requestedAt == nil {
                require(model.canCancelScan, "Preparation was not cancellable")
                requestedAt = Date()
                model.cancelScan()
            }
        }
        model.scan()
        if checkpoint == "before" {
            requestedAt = Date()
            model.cancelScan()
        }
        try await waitUntilIdle(model)
        require(requestedAt != nil, "Cancellation checkpoint was not reached")
        let latency = Date().timeIntervalSince(requestedAt!)
        require(latency < 2, "Preparation cancellation took more than 2 seconds")
        require(model.result?.entryCount == 7 && model.directorySizes["/Users/keep-me"] == 99, "Cancelled scan replaced old state")
        require(model.directoryWarnings == oldWarnings && model.directorySizes == oldSizes, "Cancelled scan replaced old warnings/sizes")
        require(model.children(for: fixtureRoot).isEmpty, "Cancelled scan leaked partial tree")
        require(events.warningUpdates == 0 && events.sizeUpdates == 0 && events.rowUpdates == 0 && events.resultUpdates == 0,
            "Cancellation published partial data")
        require(events.completions == 0 && model.completedDiskRefresh == nil, "Cancelled scan emitted a handoff")
        let after = try Data(contentsOf: url)
        require(after == before, "Cancelled scan changed isolated cache bytes")
        require(model.progress.phase.contains("已取消") && !model.isCancelling, "Late progress overwrote cancellation state")
        observation.cancel()
        print("PASS ViewModel cancellation [\(checkpoint)]: \(String(format: "%.3f", latency)) s; old UI/cache unchanged, no handoff")
    }

    @MainActor
    static func checkSuccessfulPublication(_ result: ScanResult, at url: URL) async throws {
        let model = try await seededModel(at: url, result: result)
        let events = PublicationEvents(model)
        let heartbeat = MainActorHeartbeat()
        heartbeat.start()
        var start = Date()
        var readyTime: TimeInterval?
        var sawNonCancellableCommit = false
        let observation = model.$progress.sink { progress in
            if progress.phase == "扫描结果已就绪，准备发布" { readyTime = Date().timeIntervalSince(start) }
            if progress.phase.contains("提交阶段") { sawNonCancellableCommit = !model.canCancelScan }
        }
        model.scan()
        try await waitUntilIdle(model)
        let firstReadyTime = readyTime
        let expected = result.directorySnapshot!
        require(model.result?.entryCount == result.entryCount && model.result?.directorySnapshot == nil, "Tree duplicated in summary or summary lost")
        require(model.directorySizes.count == expected.sizesByPath.count, "Published sizes incomplete")
        require(model.directoryWarnings.count == expected.childrenByPath.count, "Warnings incomplete")
        require(model.children(for: fixtureRoot).count == expected.childrenByPath[fixtureRoot]!.count, "Published tree incomplete")
        require(events.warningUpdates == 1 && events.sizeUpdates == 1 && events.rowUpdates == 1 && events.resultUpdates == 1,
            "Published per-directory instead of once per property")
        require(events.completions == 1 && model.completedDiskRefresh?.refreshedRoot == nil, "Expected exactly one full-scan handoff")
        require(events.objectChanges < 1_000, "Notification count grows per directory")
        require(readyTime != nil && readyTime! < 30, "Large result preparation was too slow")
        start = Date()
        readyTime = nil
        model.scan()
        try await waitUntilIdle(model)
        heartbeat.stop()
        require(readyTime != nil && readyTime! < 30, "Repeated large publication was too slow")
        require(events.warningUpdates == 2 && events.sizeUpdates == 2 && events.rowUpdates == 2 && events.resultUpdates == 2,
            "Repeated publication issued per-key notifications")
        require(events.completions == 2 && events.objectChanges < 1_000, "Repeated publication emitted extra notifications/handoffs")
        require(heartbeat.beats > 0 && heartbeat.maximumGap < 1, "Main actor unresponsive during preparation/publication")
        require(sawNonCancellableCommit, "Atomic cache commit incorrectly marked cancellable")
        let cache = try await ScanCacheStore(url: url).load()!
        require(cache.directoryChildren.count == expected.childrenByPath.count && cache.directoryWarnings.count == expected.childrenByPath.count,
            "Isolated persisted tree/warnings incomplete")
        require(cache.result?.directorySnapshot == nil, "Persisted redundant full snapshot")
        observation.cancel()
        print("PASS \(expected.childrenByPath.count) directories / \(result.entryCount) scanned items, published twice: preparation \(String(format: "%.3f", firstReadyTime!)) / \(String(format: "%.3f", readyTime!)) s; warnings/sizes/rows/summary once per run; \(events.objectChanges) total object notifications; max main-actor gap \(String(format: "%.3f", heartbeat.maximumGap)) s")
    }

    @MainActor
    static func checkDirectoryRefresh(_ result: ScanResult, at url: URL) async throws {
        let snapshot = result.directorySnapshot!
        let model = try await seededModel(at: url, result: result, directoryResult: snapshot)
        let events = PublicationEvents(model)
        let heartbeat = MainActorHeartbeat()
        heartbeat.start()
        model.refreshDirectory(fixtureRoot)
        try await waitUntilIdle(model)
        heartbeat.stop()
        require(model.directorySizes["/Users/keep-me"] == 99 && model.directoryWarnings["/Users/keep-me"] == "old warning", "Refresh lost unrelated cached root")
        require(model.directoryWarnings[fixtureRoot + "-neighbor"] == "keep neighbor", "Refresh removed a neighboring path with the same prefix")
        require(model.directorySizes[fixtureRoot + "/obsolete"] == nil && model.directoryWarnings[fixtureRoot + "/obsolete"] == nil
            && model.children(for: fixtureRoot + "/obsolete").isEmpty, "Refresh retained a stale subtree")
        require(model.directoryWarnings.count == snapshot.childrenByPath.count + 2, "Refresh warnings missing")
        require(events.warningUpdates == 1 && events.sizeUpdates == 1 && events.rowUpdates == 1, "Refresh issued per-directory publications")
        require(events.completions == 1 && model.completedDiskRefresh?.refreshedRoot == fixtureRoot, "Wrong refresh completion scope")
        require(model.result?.entryCount == 7, "Directory refresh overwrote full-scan summary")
        require(heartbeat.maximumGap < 1, "Refresh blocked main actor")
        let before = try Data(contentsOf: url)
        let oldCompletion = model.completedDiskRefresh
        let oldUpdates = events.warningUpdates
        var requested = false
        let observation = model.$progress.sink { progress in
            if progress.phase.contains("正在整理扫描结果：替换目录") && !requested {
                requested = true
                model.cancelScan()
            }
        }
        model.refreshDirectory(fixtureRoot)
        try await waitUntilIdle(model)
        require(requested, "Refresh replacement cancellation checkpoint not reached")
        require(events.warningUpdates == oldUpdates && events.completions == 1 && model.completedDiskRefresh == oldCompletion,
            "Cancelled refresh published new data/handoff")
        let after = try Data(contentsOf: url)
        require(after == before, "Cancelled refresh changed cache")
        observation.cancel()
        print("PASS large directory refresh: one publication, unrelated roots retained, cancellation during old-subtree removal preserves previous cache/handoff")
    }

    static func main() async throws {
        // A main-actor regression must also time out if that actor is completely
        // blocked; its own async timeout could otherwise never run.
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("FAIL publication watchdog exceeded 180 seconds\n".utf8))
            exit(2)
        }
        let count = Int(ProcessInfo.processInfo.environment["CLEANMAC_PUBLICATION_DIRECTORIES"] ?? "250000")!
        require(count >= 20_000, "Use at least 20,000 directories for scale checks")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CleanMac-publication-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("Validation files retained (isolated caches only): \(directory.path)")
        let result = await Task.detached { fixture(directoryCount: count) }.value
        let baseline = PreparedScanPublication(summary: nil, children: [:], sizes: [:], warnings: [:], expanded: [], rows: [])
        try await Task.detached {
            let token = ScanToken()
            do {
                _ = try ScanPublicationPreparer.fullScan(result, previous: baseline, roots: [], token: token) { stage, _ in
                    if stage == "告警" { token.cancel() }
                }
                fatalError("Warning preparation ignored cancellation")
            } catch is CancellationError {}
            var withoutWarnings = result
            withoutWarnings.directorySnapshot!.unreadableCount = 0
            var expanded = baseline
            expanded.expanded = Set(result.directorySnapshot!.childrenByPath.keys.filter { !$0.contains("/folder-") })
            let rowToken = ScanToken()
            do {
                _ = try ScanPublicationPreparer.fullScan(withoutWarnings, previous: expanded, roots: [entry("/Users")], token: rowToken) { stage, _ in
                    if stage == "可见目录" { rowToken.cancel() }
                }
                fatalError("Visible row construction ignored cancellation")
            } catch is CancellationError {}
            print("PASS preparer cancellation within warning and expanded-row loops; no partial result returned")
        }.value
        try await checkCancellation(result, at: directory.appendingPathComponent("cancel-before.plist"), checkpoint: "before")
        try await checkCancellation(result, at: directory.appendingPathComponent("cancel-preparing.plist"), checkpoint: "preparing")
        try await checkCancellation(result, at: directory.appendingPathComponent("cancel-ready.plist"), checkpoint: "ready")
        try await checkSuccessfulPublication(result, at: directory.appendingPathComponent("success.plist"))
        // A smaller but still large refresh exercises old-subtree removal too.
        let refresh = await Task.detached {
            var refresh = fixture(directoryCount: min(count, 100_000))
            refresh.directorySnapshot!.childrenByPath.removeValue(forKey: "/Users")
            refresh.directorySnapshot!.sizesByPath.removeValue(forKey: "/Users")
            return refresh
        }.value
        try await checkDirectoryRefresh(refresh, at: directory.appendingPathComponent("refresh.plist"))
        print("All publication checks passed. Existing user files/cache were not modified or deleted.")
    }
}
