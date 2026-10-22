import Foundation

@main
struct OverviewChecks {
    static func main() async throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("CleanMac-overview-fixture-" + UUID().uuidString).standardizedFileURL
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer {
            if ProcessInfo.processInfo.environment["CLEANMAC_KEEP_TEST_FILES"] != "1" { try? fm.removeItem(at: fixture) }
            else { print("Validation fixtures retained: \(fixture.path)") }
        }
        let home = "/Users/fixture"
        let app = InstalledApp(name: "Fixture App", bundleIdentifier: "com.fixture.app", displayPath: "/Applications/Fixture.app", version: "1", isSystemApp: false)
        let service = ServiceEvidence(label: "com.fixture.worker", plistPath: home + "/Library/LaunchAgents/com.fixture.worker.plist",
            executable: "/usr/local/bin/fixture-worker", referencedPaths: [home + "/Library/Caches/com.fixture.worker"])
        func manifest(runtime: RuntimeEvidence = RuntimeEvidence(querySucceeded: true), services: [ServiceEvidence] = []) -> OverviewManifest {
            OverviewManifest(id: UUID().uuidString, createdAt: Date(), cacheSavedAt: Date(timeIntervalSince1970: 1000), homePath: home,
                lifetime: "fixture", roots: [home], recordCount: 0, warnings: [], applications: [app], services: services, runtime: runtime)
        }
        func record(_ path: String, directory: Bool = false) -> OverviewRecord {
            OverviewRecord(path: path, cachedBytes: 100, isDirectory: directory)
        }
        let attribution = OverviewAttribution(manifest: manifest())
        let cachePath = home + "/Library/Caches/com.fixture.app"
        precondition(attribution.finding(for: record(cachePath, directory: true)).disposition == "review")
        precondition(attribution.finding(for: record(home + "/Library/Caches/com.fixture.app2")).disposition == "unknown")
        precondition(attribution.finding(for: record(home + "/Documents/important.db")).disposition == "unknown")
        precondition(attribution.finding(for: record("/Applications/Fixture.app/Contents/Info.plist")).evidence.contains { $0.kind == "application_bundle" })
        precondition(attribution.finding(for: record("/System/Library/test")).disposition == "retain")
        precondition(!OverviewAttribution.reviewableCachePath(home + "/Library/Caches/com.apple.Safari/data", home: home))
        precondition(!OverviewAttribution.reviewableCachePath(cachePath + "/nested", home: home))
        precondition(!UsageEvidenceCollector.contains("/Applications/Fixture.app", "/Applications/Fixture.app2/data"))

        let files = UsageEvidenceCollector.parseOpenFiles("p123\ncFixture\nn\(cachePath)/payload.bin\nn\(cachePath)/payload.bin\np456\ncOther\nn/Applications/Fixture.app/Contents/MacOS/Fixture\n")
        precondition(files.count == 2)
        let runtime = RuntimeEvidence(openFiles: files, querySucceeded: true)
        let active = OverviewAttribution(manifest: manifest(runtime: runtime)).finding(for: record(cachePath, directory: true))
        precondition(active.disposition == "retain" && active.evidence.contains { $0.pid == 123 })
        let configured = OverviewAttribution(manifest: manifest(services: [service]))
            .finding(for: record(home + "/Library/Caches/com.fixture.worker/output.log"))
        precondition(configured.disposition == "retain")
        precondition(configured.evidence.contains { $0.kind == "service_configuration" && $0.sourcePath == service.plistPath })
        print("PASS ownership: exact boundaries / unknown retention / service references / active process / no overlapping proposals")

        let rootPaths = ["/Users/example", "/Users/example/子目录/深层", "/Users/example-neighbor", "/opt"]
        let selectedRoots = try OverviewReportEngine.roots(rootPaths, token: ScanToken())
        precondition(selectedRoots == ["/Users/example", "/Users/example-neighbor", "/opt"].sorted())
        let manyPaths = ["/Users/fixture"] + (0..<100_000).map { "/Users/fixture/branch-\($0)/child" }
        let rootsStarted = Date()
        let manyRoots = try OverviewReportEngine.roots(manyPaths, token: ScanToken())
        precondition(manyRoots == ["/Users/fixture"] && Date().timeIntervalSince(rootsStarted) < 5)
        let cancelledRoots = ScanToken()
        cancelledRoots.cancel()
        do {
            _ = try OverviewReportEngine.roots(rootPaths, token: cancelledRoots)
            fatalError("root aggregation ignored cancellation")
        } catch is CancellationError {}
        print("PASS root aggregation: 100,001 paths / component boundaries / Unicode / pre-cancellation")

        let agents = fixture.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let servicePlist: [String: Any] = ["Label": "com.fixture.private-worker", "ProgramArguments": ["/usr/local/bin/fixture-worker", "--token", "DO_NOT_EXPORT_SECRET", "--data", fixture.appendingPathComponent("worker-data").path]]
        try PropertyListSerialization.data(fromPropertyList: servicePlist, format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("fixture.plist"))
        let collected = UsageEvidenceCollector().services(home: fixture)
        let privateService = collected.items.first { $0.label == "com.fixture.private-worker" }!
        precondition(privateService.referencedPaths.contains(fixture.appendingPathComponent("worker-data").path))
        let exportedService = String(decoding: try OverviewReportEngine.encoder().encode(privateService), as: UTF8.self)
        precondition(!exportedService.contains("DO_NOT_EXPORT_SECRET") && !exportedService.contains("--token"))
        print("PASS service collection: absolute data paths retained, non-path arguments omitted")

        let nested = fixture.appendingPathComponent("tree/nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let payload = nested.appendingPathComponent("payload.bin")
        try Data("one".utf8).write(to: payload)
        let fingerprint = try OverviewReportEngine.fingerprint(fixture.appendingPathComponent("tree").path)
        try Data("changed subtree".utf8).write(to: payload)
        let modified = try OverviewReportEngine.fingerprint(fixture.appendingPathComponent("tree").path)
        precondition(fingerprint.treeDigest != nil && fingerprint != modified)
        try fm.createSymbolicLink(at: nested.appendingPathComponent("link"), withDestinationURL: fixture)
        do {
            _ = try OverviewReportEngine.fingerprint(fixture.appendingPathComponent("tree").path)
            fatalError("symlink subtree accepted")
        } catch {}
        print("PASS subtree fingerprint: descendant changes and symlinks")

        let cancelledFingerprint = ScanToken()
        cancelledFingerprint.cancel()
        do {
            _ = try OverviewReportEngine.fingerprint(fixture.path, token: cancelledFingerprint)
            fatalError("fingerprint ignored cancellation")
        } catch is CancellationError {}
        let cancelledRuntime = UsageEvidenceCollector().runtime(timeout: 30, token: cancelledFingerprint)
        precondition(!cancelledRuntime.querySucceeded && cancelledRuntime.warnings.contains { $0.contains("已取消") })
        let wide = fixture.appendingPathComponent("wide-directory")
        try fm.createDirectory(at: wide, withIntermediateDirectories: true)
        for index in 0..<3_000 { fm.createFile(atPath: wide.appendingPathComponent("file-\(index)").path, contents: Data([1])) }
        let directoryToken = ScanToken()
        let cancelStart = Date()
        let cancelledDirectory = await DirectoryScanner().scanDirectory(at: wide, token: directoryToken, retainTree: true) { update in
            if update.scannedEntries >= 2_000 { directoryToken.cancel() }
        }
        precondition(cancelledDirectory.cancelled && cancelledDirectory.childrenByPath.isEmpty)
        precondition(Date().timeIntervalSince(cancelStart) < 5)
        print("PASS cancellation during a wide directory: stops within child loop and discards partial snapshot")

        let root = fixture.appendingPathComponent("cached").path
        func entry(_ path: String, directory: Bool, bytes: Int64) -> DirectoryEntry {
            DirectoryEntry(id: path, name: URL(fileURLWithPath: path).lastPathComponent, path: path, size: bytes,
                sizeText: "fixture", depth: 1, isHidden: false, isDirectory: directory)
        }
        let quoted = root + "/file with spaces $()\nline.txt"
        let cache = PersistedScanCache(savedAt: Date(timeIntervalSince1970: 1000),
            directoryChildren: [root: [entry(root + "/nested", directory: true, bytes: 7), entry(root + "/empty", directory: true, bytes: 0), entry(quoted, directory: false, bytes: 3)],
                root + "/nested": [entry(root + "/nested/payload", directory: false, bytes: 7)], root + "/empty": []],
            directorySizes: [root: 10, root + "/nested": 7, root + "/empty": 0], directoryWarnings: [root: "fixture incomplete"],
            libraryItems: [], librarySource: nil, expandedDirectories: [])
        let engine = OverviewReportEngine()
        let skillURL = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("CleanMac/Resources/Skills/cleanmac-disk-analysis/SKILL.md")
        let refresh = DiskRefreshCompletion(refreshedRoot: root + "/nested", finishedAt: Date(timeIntervalSince1970: 2000))
        let scoped = AgentAnalysisHandoffBuilder.scopedCache(cache, refresh: refresh)
        precondition(scoped.directoryChildren.count == 1 && scoped.directoryChildren[root + "/nested"] != nil)
        precondition(scoped.directorySizes[root] == nil && scoped.directoryChildren[root + "/empty"] == nil)
        let fullRefresh = DiskRefreshCompletion(refreshedRoot: nil)
        precondition(AgentAnalysisHandoffBuilder.scopedCache(cache, refresh: fullRefresh).directoryChildren.count == cache.directoryChildren.count)
        print("PASS refreshed subtree scope excludes unrelated cached directories")
        for lifetime in OverviewLifetime.allCases {
            let artifact = try engine.generate(cache: cache, lifetime: lifetime,
                destinationRoot: fixture.appendingPathComponent(lifetime == .temporary ? "temporary" : "persistent"), skillURL: skillURL,
                cliDocumentationURL: URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Docs/CLI.md"),
                refresh: fullRefresh, token: ScanToken(), progress: { _ in })
            precondition(artifact.manifest.recordCount == 5)
            precondition(artifact.manifest.cacheSavedAt == cache.savedAt)
            precondition(artifact.manifest.warnings.contains("fixture incomplete"))
            let exportedSkill = artifact.directory.appendingPathComponent(AgentAnalysisHandoffBuilder.skillRelativePath)
            let exportedSkillData = try Data(contentsOf: exportedSkill)
            let originalSkillData = try Data(contentsOf: skillURL)
            precondition(exportedSkillData == originalSkillData)
            let prompt = AgentAnalysisHandoffBuilder.prompt(for: artifact, refresh: refresh)
            precondition(prompt.contains(exportedSkill.path) && prompt.contains("$cleanmac-disk-analysis"))
            let cliDocument = artifact.directory.appendingPathComponent("CLI.md")
            precondition(fm.fileExists(atPath: cliDocument.path) && prompt.contains(cliDocument.path))
            precondition(prompt.contains("CLI 可执行文件"))
            precondition(prompt.contains("1970-01-01T00:33:20Z") && prompt.contains(root + "/nested"))
            precondition(prompt.contains("不要删除或移动文件") && prompt.contains("proposals.json"))
            let promptFile = try String(contentsOf: artifact.directory.appendingPathComponent("agent-prompt.txt"), encoding: .utf8)
            precondition(promptFile.contains(artifact.directory.path) && promptFile.contains("Skill 入口"))
            precondition(promptFile == AgentAnalysisHandoffBuilder.prompt(for: artifact, refresh: fullRefresh))
            let reopened = try engine.open(artifact.directory)
            let analyzed = try engine.analyze(reopened, token: ScanToken(), progress: { _ in })
            precondition(analyzed.analysis?.recordCount == 5)
            precondition(analyzed.preview.contains { $0.path == quoted })
            let pointer = try OverviewReportEngine.decoder().decode(String.self, from: Data(contentsOf: artifact.directory.appendingPathComponent("latest-analysis.json")))
            precondition(fm.fileExists(atPath: artifact.directory.appendingPathComponent(pointer + "/findings.jsonl").path))
            let cancelled = ScanToken()
            cancelled.cancel()
            do {
                _ = try engine.analyze(reopened, token: cancelled, progress: { _ in })
                fatalError("cancellation ignored")
            } catch is CancellationError {}
            let pointerAfterCancel = try Data(contentsOf: artifact.directory.appendingPathComponent("latest-analysis.json"))
            let decodedPointer = try OverviewReportEngine.decoder().decode(String.self, from: pointerAfterCancel)
            precondition(decodedPointer == pointer)
            let recordsURL = artifact.directory.appendingPathComponent("entries.jsonl")
            let extra = try FileHandle(forWritingTo: recordsURL)
            try extra.seekToEnd()
            var extraLine = try OverviewReportEngine.encoder().encode(record(root + "/unexpected"))
            extraLine.append(10)
            try extra.write(contentsOf: extraLine)
            try extra.close()
            do {
                _ = try engine.analyze(reopened, token: ScanToken(), progress: { _ in })
                fatalError("count mismatch accepted")
            } catch is OverviewError {}
            let pointerAfterMismatch = try Data(contentsOf: artifact.directory.appendingPathComponent("latest-analysis.json"))
            precondition(pointerAfterMismatch == pointerAfterCancel)
            let longInput = try FileHandle(forWritingTo: recordsURL)
            try longInput.seekToEnd()
            for index in 0..<4_000 {
                var line = try OverviewReportEngine.encoder().encode(record(root + "/analysis-cancel-\(index)"))
                line.append(10)
                try longInput.write(contentsOf: line)
            }
            try longInput.close()
            let runningToken = ScanToken()
            do {
                _ = try engine.analyze(reopened, token: runningToken) { _ in runningToken.cancel() }
                fatalError("running analysis ignored cancellation")
            } catch is CancellationError {}
            let pointerAfterRunningCancel = try Data(contentsOf: artifact.directory.appendingPathComponent("latest-analysis.json"))
            precondition(pointerAfterRunningCancel == pointerAfterCancel)
            print("PASS \(lifetime.rawValue): export / reopen / streaming analysis / quoted paths / atomic cancellation")
        }

        let invalid = OverviewFinding(path: "/System/Library/test", cachedBytes: 100, isDirectory: true, evidence: [], disposition: "review",
            reason: "untrusted imported recommendation", fingerprint: fingerprint)
        let artifact = OverviewArtifact(id: UUID().uuidString, directory: fixture, manifest: manifest())
        do {
            _ = try engine.trashReviewed(invalid, artifact: artifact)
            fatalError("protected target accepted")
        } catch {}
        print("PASS imported recommendation cannot bypass cleanup boundary")
        print("All overview checks passed; no existing user files were moved or deleted.")
    }
}
