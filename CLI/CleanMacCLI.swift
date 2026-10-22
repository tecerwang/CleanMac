import Foundation
import Darwin

private struct CLIUsageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private struct PageComplete: Error {}

@main
struct CleanMacCLI {
    static let version = "1.0.0"
    static let commands = ["capabilities", "inspect", "entries", "analyze", "findings", "scan", "export"]

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["help"] || arguments.last == "--help" {
            print("""
            cleanmac \(version) — local disk-analysis automation (no deletion commands)
            capabilities
            inspect  --overview PATH
            entries  --overview PATH [--path-prefix PATH] [--limit 100] [--offset 0]
            analyze  --overview PATH
            findings --overview PATH [--disposition retain|unknown|review] [--path-prefix PATH] [--limit 100] [--offset 0]
            scan     (--path PATH | --all) [--lifetime temporary|persistent] [--output-root PATH] [--resources PATH]
            export   [--cache PATH] [--path PATH] [--lifetime temporary|persistent] [--output-root PATH] [--resources PATH]
            stdout: one JSON envelope; stderr: JSONL progress. SIGINT/SIGTERM: cooperative cancellation.
            """)
            return
        }
        if arguments == ["--version"] { print(version); return }
        let token = ScanToken()
        signal(SIGPIPE, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { token.cancel() }
            source.resume()
            return source
        }
        var status: Int32 = 0
        do {
            let data = try await run(arguments, token: token)
            try emit(["schemaVersion": 1, "ok": true, "data": data])
        } catch {
            let cancelled = error is CancellationError || token.isCancelled
            status = cancelled ? 130 : (error is CLIUsageError ? 2 : 1)
            try? emit(["schemaVersion": 1, "ok": false,
                "error": ["code": cancelled ? "cancelled" : (status == 2 ? "usage" : "operation_failed"),
                          "message": cancelled ? "已取消；旧缓存和已完成结果保留。" : error.localizedDescription]])
        }
        withExtendedLifetime(signals) {}
        if status != 0 { exit(status) }
    }

    static func run(_ arguments: [String], token: ScanToken) async throws -> [String: Any] {
        guard let command = arguments.first, commands.contains(command) else { throw CLIUsageError(message: "需要有效命令；运行 cleanmac --help。") }
        let allowed: Set<String>
        switch command {
        case "capabilities": allowed = []
        case "inspect", "analyze": allowed = ["overview"]
        case "entries": allowed = ["overview", "path-prefix", "limit", "offset"]
        case "findings": allowed = ["overview", "path-prefix", "limit", "offset", "disposition"]
        case "scan": allowed = ["path", "all", "lifetime", "output-root", "resources"]
        default: allowed = ["cache", "path", "lifetime", "output-root", "resources"]
        }
        let options = try parse(Array(arguments.dropFirst()), allowed: allowed)
        try token.checkCancellation()
        switch command {
        case "capabilities":
            return ["version": version, "commands": commands, "destructiveCommands": [String](),
                "writesGUICache": false, "stdout": "json-envelope", "progress": "stderr-jsonl",
                "executable": AgentCLIResources.executableURL?.path as Any? ?? NSNull(),
                "cliDocumentation": AgentCLIResources.resource("CLI.md")?.path as Any? ?? NSNull()]
        case "inspect":
            return try describe(open(options))
        case "entries", "findings":
            let artifact = try open(options)
            return try page(artifact, findings: command == "findings", options: options, token: token)
        case "analyze":
            let artifact = try open(options)
            let analyzed = try OverviewReportEngine().analyze(artifact, token: token) { phase in progress(phase) }
            var description = try describe(analyzed)
            description["analysis"] = try object(analyzed.analysis!)
            return description
        case "scan", "export":
            let lifetime: OverviewLifetime
            switch options["lifetime"] ?? "temporary" {
            case "temporary": lifetime = .temporary
            case "persistent": lifetime = .persistent
            default: throw CLIUsageError(message: "--lifetime 必须为 temporary 或 persistent。")
            }
            let output = try options["output-root"].map { try absoluteURL($0) }
            let resources = try options["resources"].map { try absoluteURL($0) }
            let skill = resources?.appendingPathComponent("SKILL.md") ?? AgentCLIResources.resource("SKILL.md")
            let documentation = resources?.appendingPathComponent("CLI.md") ?? AgentCLIResources.resource("CLI.md")
            // Validate before doing a potentially expensive scan/cache decode.
            guard let skill, let documentation,
                  FileManager.default.fileExists(atPath: skill.path), FileManager.default.fileExists(atPath: documentation.path) else {
                throw CLIUsageError(message: "缺少 CLI.md/SKILL.md；请使用完整 Release 或 --resources。")
            }
            let cache: PersistedScanCache
            let refresh: DiskRefreshCompletion
            if command == "scan" {
                guard (options["path"] != nil) != (options["all"] != nil) else {
                    throw CLIUsageError(message: "scan 必须且只能指定 --path 或 --all。")
                }
                if let path = options["path"] {
                    let root = try absoluteURL(path)
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                        throw CLIUsageError(message: "--path 必须为现有目录。")
                    }
                    let result = await DirectoryScanner().scanDirectory(at: root, token: token, retainTree: true) { update in
                        progress(update.phase, count: update.scannedEntries)
                    }
                    try token.checkCancellation()
                    if result.cancelled { throw CancellationError() }
                    let warning = result.unreadableCount > 0 ? "有 \(result.unreadableCount) 项无法读取，当前为可读取内容的统计。" : nil
                    var warnings: [String: String] = [:]
                    if let warning {
                        for path in result.childrenByPath.keys { try token.checkCancellation(); warnings[path] = warning }
                    }
                    cache = snapshot(children: result.childrenByPath, sizes: result.sizesByPath, warnings: warnings)
                    refresh = DiskRefreshCompletion(refreshedRoot: root.path)
                } else {
                    let result = await DiskScanner().scan(token: token) { update in progress(update.phase, count: update.scannedEntries) }
                    try token.checkCancellation()
                    guard !result.cancelled, result.directorySnapshot != nil else { throw CancellationError() }
                    let previous = PreparedScanPublication(summary: nil, children: [:], sizes: [:], warnings: [:], expanded: [], rows: [])
                    let prepared = try ScanPublicationPreparer.fullScan(result, previous: previous, roots: [], token: token)
                    cache = snapshot(children: prepared.children, sizes: prepared.sizes, warnings: prepared.warnings, result: prepared.summary)
                    refresh = DiskRefreshCompletion(refreshedRoot: nil)
                }
            } else {
                let cacheURL = try options["cache"].map { try absoluteURL($0) }
                    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CleanMac/scan-cache.plist")
                progress("读取已有扫描缓存（只读）")
                guard let loaded = try await ScanCacheStore(url: cacheURL).load() else { throw OverviewError.invalid("扫描缓存不存在。") }
                try token.checkCancellation()
                refresh = DiskRefreshCompletion(refreshedRoot: try options["path"].map { try absoluteURL($0).path }, finishedAt: loaded.savedAt)
                cache = AgentAnalysisHandoffBuilder.scopedCache(loaded, refresh: refresh)
                guard !cache.directoryChildren.isEmpty else { throw OverviewError.invalid("所选范围没有缓存记录；不会自动重新扫描。") }
            }
            let artifact = try OverviewReportEngine().generate(cache: cache, lifetime: lifetime, destinationRoot: output,
                skillURL: skill, cliDocumentationURL: documentation, cliExecutableURL: AgentCLIResources.executableURL,
                refresh: refresh, token: token) { phase in progress(phase) }
            return try describe(artifact)
        default: throw CLIUsageError(message: "未知命令。")
        }
    }

    static func parse(_ arguments: [String], allowed: Set<String>) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { throw CLIUsageError(message: "不接受位置参数：\(argument)") }
            let key = String(argument.dropFirst(2))
            guard allowed.contains(key), values[key] == nil else { throw CLIUsageError(message: "未知或重复参数：\(argument)") }
            if key == "all" { values[key] = "true"; index += 1; continue }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw CLIUsageError(message: "\(argument) 缺少值。") }
            values[key] = arguments[index + 1]
            index += 2
        }
        return values
    }

    static func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw CLIUsageError(message: "路径必须为不含 NUL 的绝对路径。") }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { _ = components.popLast() }
            else { components.append(component) }
        }
        // Do not rewrite filesystem aliases differently before/after creation.
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
    }

    static func open(_ options: [String: String]) throws -> OverviewArtifact {
        guard let path = options["overview"] else { throw CLIUsageError(message: "缺少 --overview。") }
        return try OverviewReportEngine().open(absoluteURL(path))
    }

    static func snapshot(children: [String: [DirectoryEntry]], sizes: [String: Int64], warnings: [String: String], result: ScanResult? = nil) -> PersistedScanCache {
        PersistedScanCache(result: result, directoryChildren: children, directorySizes: sizes,
            directoryWarnings: warnings, libraryItems: [], librarySource: nil, expandedDirectories: [])
    }

    static func describe(_ artifact: OverviewArtifact) throws -> [String: Any] {
        let manifest = artifact.manifest
        let directory = AgentAnalysisHandoffBuilder.directoryPath(artifact.directory)
        let documentation = directory + "/CLI.md"
        return ["overviewID": artifact.id, "directory": directory,
            "createdAt": manifest.createdAt.ISO8601Format(), "cacheSavedAt": manifest.cacheSavedAt?.ISO8601Format() as Any? ?? NSNull(),
            "roots": manifest.roots, "recordCount": manifest.recordCount, "warnings": manifest.warnings,
            "applicationCount": manifest.applications.count, "serviceCount": manifest.services.count,
            "openFileCount": manifest.runtime.openFiles.count, "runtimeQuerySucceeded": manifest.runtime.querySucceeded,
            "entries": directory + "/entries.jsonl",
            "cliDocumentation": FileManager.default.fileExists(atPath: documentation) ? documentation as Any : NSNull(),
            "agentPrompt": FileManager.default.fileExists(atPath: directory + "/agent-prompt.txt")
                ? (directory + "/agent-prompt.txt") as Any : NSNull()]
    }

    /// Constrain a completed-analysis pointer and all files it names to this package.
    static func latestAnalysis(_ artifact: OverviewArtifact) throws -> URL {
        let pointer = try contained(artifact.directory.appendingPathComponent("latest-analysis.json"), in: artifact.directory)
        let size = (try pointer.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 1_024 else { throw OverviewError.invalid("分析指针过大。") }
        let name = try OverviewReportEngine.decoder().decode(String.self, from: Data(contentsOf: pointer))
        guard name.hasPrefix("analysis-"), UUID(uuidString: String(name.dropFirst("analysis-".count))) != nil,
              !name.contains("/") else { throw OverviewError.invalid("无效的已完成分析指针。") }
        let folder = try contained(artifact.directory.appendingPathComponent(name), in: artifact.directory)
        let analysisURL = try contained(folder.appendingPathComponent("analysis.json"), in: artifact.directory)
        guard ((try analysisURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 1_048_576 else { throw OverviewError.invalid("分析摘要过大。") }
        let analysis = try OverviewReportEngine.decoder().decode(OverviewAnalysis.self, from: Data(contentsOf: analysisURL))
        guard analysis.overviewID == artifact.id else { throw OverviewError.invalid("分析不属于该概述。") }
        return folder
    }

    static func contained(_ file: URL, in directory: URL) throws -> URL {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root + "/") else { throw OverviewError.invalid("分析路径越出概述目录。") }
        return resolved
    }

    static func page(_ artifact: OverviewArtifact, findings: Bool, options: [String: String], token: ScanToken) throws -> [String: Any] {
        guard let limit = Int(options["limit"] ?? "100"), (1...10_000).contains(limit),
              let offset = Int(options["offset"] ?? "0"), (0...100_000_000).contains(offset) else {
            throw CLIUsageError(message: "--limit 为 1–10000，--offset 为 0–100000000。")
        }
        let prefix = try options["path-prefix"].map { try UsageEvidenceCollector.normalized(absoluteURL($0).path) }
        if let disposition = options["disposition"], !["retain", "unknown", "review"].contains(disposition) {
            throw CLIUsageError(message: "--disposition 必须为 retain、unknown 或 review。")
        }
        let source = findings ? try contained(latestAnalysis(artifact).appendingPathComponent("findings.jsonl"), in: artifact.directory)
            : artifact.directory.appendingPathComponent("entries.jsonl")
        var items: [Any] = []
        var skipped = 0
        var more = false
        do {
            try OverviewReportEngine.readLines(source) { data in
                try token.checkCancellation()
                let path: String
                let disposition: String?
                let item: Any
                if findings {
                    let finding = try OverviewReportEngine.decoder().decode(OverviewFinding.self, from: data)
                    guard finding.cachedBytes >= 0 else { throw OverviewError.invalid("记录大小无效。") }
                    path = finding.path; disposition = finding.disposition; item = try object(finding)
                } else {
                    let record = try OverviewReportEngine.decoder().decode(OverviewRecord.self, from: data)
                    guard record.cachedBytes >= 0 else { throw OverviewError.invalid("记录大小无效。") }
                    path = record.path; disposition = nil; item = try object(record)
                }
                guard path.hasPrefix("/"), !path.utf8.contains(0),
                      URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path == path else {
                    throw OverviewError.invalid("记录路径无效。")
                }
                if let prefix, !UsageEvidenceCollector.contains(prefix, path) { return }
                if let filter = options["disposition"], filter != disposition { return }
                if skipped < offset { skipped += 1; return }
                if items.count == limit { more = true; throw PageComplete() }
                items.append(item)
            }
        } catch is PageComplete {}
        try token.checkCancellation()
        return ["overviewID": artifact.id, "items": items, "nextOffset": more ? (offset + items.count) as Any : NSNull()]
    }

    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: OverviewReportEngine.encoder().encode(value))
    }

    static func emit(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    static func progress(_ phase: String, count: Int? = nil) {
        var value: [String: Any] = ["event": "progress", "phase": phase]
        if let count { value["scannedEntries"] = count }
        if var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            data.append(10)
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }
}
