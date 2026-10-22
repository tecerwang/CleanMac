import Foundation

/// Configuration ownership and observed runtime use are independent evidence.
/// An absent match never proves that an application was uninstalled.
nonisolated struct OverviewAttribution {
    private let manifest: OverviewManifest
    private var paths: [String: [OwnershipEvidence]] = [:]
    private var identifiers: [String: [OwnershipEvidence]] = [:]
    private var openPaths: [String: [OwnershipEvidence]] = [:]

    init(manifest: OverviewManifest, token: ScanToken? = nil) {
        self.manifest = manifest
        for app in manifest.applications {
            if token?.isCancelled == true { return }
            let path = UsageEvidenceCollector.normalized(CleanMacPath.expand(app.displayPath, home: manifest.homePath))
            let bundle = OwnershipEvidence(owner: app.name, kind: "application_bundle", confidence: "high",
                reason: "路径位于已发现的应用包内。", sourcePath: path, pid: nil)
            paths[path, default: []].append(bundle)
            if !app.bundleIdentifier.isEmpty {
                identifiers[app.bundleIdentifier.lowercased(), default: []].append(OwnershipEvidence(owner: app.name,
                    kind: "bundle_identifier", confidence: "medium", reason: "路径组件与应用 Bundle Identifier 精确匹配；不代表正在使用。", sourcePath: path, pid: nil))
            }
        }
        for service in manifest.services {
            if token?.isCancelled == true { return }
            let evidence = OwnershipEvidence(owner: service.label, kind: "service_configuration", confidence: "high",
                reason: "launchd 配置显式引用此路径；配置存在不代表服务已加载或运行。", sourcePath: service.plistPath, pid: nil)
            paths[service.plistPath, default: []].append(evidence)
            if let executable = service.executable { paths[executable, default: []].append(evidence) }
            for path in service.referencedPaths where path != "/" && path != manifest.homePath {
                paths[path, default: []].append(evidence)
            }
            identifiers[service.label.lowercased(), default: []].append(OwnershipEvidence(owner: service.label,
                kind: "service_label", confidence: "medium", reason: "路径组件与 launchd Label 精确匹配，待核实用途。", sourcePath: service.plistPath, pid: nil))
        }
        var processOwners: [Int: Set<String>] = [:]
        var serviceExecutables: [String: [String]] = [:]
        for service in manifest.services {
            if let executable = service.executable { serviceExecutables[executable, default: []].append(service.label) }
        }
        for file in manifest.runtime.openFiles {
            if token?.isCancelled == true { return }
            for label in serviceExecutables[file.path] ?? [] {
                processOwners[file.pid, default: []].insert(label + "（配置可执行文件关联，待确认）")
            }
            var path = file.path
            while true {
                for match in paths[path] ?? [] where match.kind == "application_bundle" {
                    processOwners[file.pid, default: []].insert(match.owner)
                }
                if path == "/" { break }
                path = URL(fileURLWithPath: path).deletingLastPathComponent().path
            }
        }
        for file in manifest.runtime.openFiles {
            if token?.isCancelled == true { return }
            let owners = processOwners[file.pid, default: []].sorted()
            let owner = owners.isEmpty ? file.command : file.command + "（进程映射线索：" + owners.joined(separator: "、") + "）"
            let evidence = OwnershipEvidence(owner: owner, kind: "open_file", confidence: "high",
                reason: "PID \(file.pid) 在观察时打开该文件或目录中的内容。", sourcePath: file.path, pid: file.pid)
            var path = file.path
            while true {
                // The full observations live in manifest.json. Findings keep a
                // bounded sample per ancestor to avoid quadratic report growth.
                if openPaths[path, default: []].count < 8 { openPaths[path, default: []].append(evidence) }
                if path == "/" { break }
                path = URL(fileURLWithPath: path).deletingLastPathComponent().path
            }
        }
    }

    func finding(for record: OverviewRecord, fingerprint: FileFingerprint? = nil) -> OverviewFinding {
        var matches: [OwnershipEvidence] = []
        var path = record.path
        while true {
            matches.append(contentsOf: paths[path] ?? [])
            let component = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            var identifier = component
            for suffix in [".plist", ".savedstate"] where identifier.hasSuffix(suffix) {
                identifier = String(identifier.dropLast(suffix.count))
            }
            matches.append(contentsOf: identifiers[identifier] ?? [])
            if path == "/" { break }
            path = URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
        let open = openPaths[record.path] ?? []
        matches.append(contentsOf: open)
        var seen = Set<OwnershipEvidence>()
        matches = matches.filter { seen.insert($0).inserted }
        let disposition: String
        let reason: String
        if CleanupEngine.isProtectedPath(record.path, home: manifest.homePath) {
            disposition = "retain"; reason = "系统或根目录，保留。"
        } else if !open.isEmpty {
            disposition = "retain"; reason = "观察到正在使用，保留并先确认应用或服务用途。"
        } else if Self.reviewableCachePath(record.path, home: manifest.homePath),
                  !matches.isEmpty, !matches.contains(where: { $0.kind == "service_configuration" || $0.kind == "service_label" }) {
            disposition = "review"; reason = "应用缓存且存在归属证据，可人工复核；未观察到打开文件不代表可安全删除。"
        } else if matches.isEmpty {
            disposition = "unknown"; reason = "暂无可靠归属证据。不能据此认定为垃圾或残留。"
        } else {
            disposition = "retain"; reason = "存在应用或服务关联，默认保留，交由人工或 AI 分析用途。"
        }
        return OverviewFinding(path: record.path, cachedBytes: record.cachedBytes, isDirectory: record.isDirectory,
            evidence: matches, disposition: disposition, reason: reason, fingerprint: fingerprint)
    }

    /// Restrict the new assisted cleanup entry to individual user-cache children.
    /// Documents, databases, app bundles and service configurations need a separate workflow.
    static func reviewableCachePath(_ path: String, home: String) -> Bool {
        let root = home + "/Library/Caches"
        let components = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }
        // One proposal per direct cache child; avoid overlapping recommendations
        // and repeatedly hashing every ancestor of the same subtree.
        let relative = String(path.dropFirst((root + "/").count))
        return path.hasPrefix(root + "/") && !relative.isEmpty && !relative.contains("/") && !components.contains("cleanmac")
            && !components.contains(where: { $0.hasPrefix("com.apple.") })
    }
}
