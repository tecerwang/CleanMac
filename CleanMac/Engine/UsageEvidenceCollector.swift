import Foundation
import Darwin

/// Observes configuration and accessible open files; never starts or stops a service.
nonisolated struct UsageEvidenceCollector {
    func services(home: URL, token: ScanToken? = nil) -> (items: [ServiceEvidence], warnings: [String]) {
        let roots = [home.appendingPathComponent("Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons"),
            URL(fileURLWithPath: "/System/Library/LaunchAgents"), URL(fileURLWithPath: "/System/Library/LaunchDaemons")]
        var items: [ServiceEvidence] = []
        var warnings: [String] = []
        for root in roots {
            if token?.isCancelled == true { break }
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            do {
                let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                for file in files where file.pathExtension == "plist" {
                    if token?.isCancelled == true { break }
                    do {
                        let data = try Data(contentsOf: file)
                        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                              let label = plist["Label"] as? String else { continue }
                        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                        // Retain only absolute path references from arguments,
                        // never flags, non-path values or environment contents.
                        let argumentPaths = Array((plist["ProgramArguments"] as? [String] ?? []).dropFirst())
                            .filter { $0.hasPrefix("/") }
                        let references = (["WorkingDirectory", "StandardOutPath", "StandardErrorPath"].compactMap { plist[$0] as? String } + argumentPaths)
                            .filter { $0.hasPrefix("/") }.map(Self.normalized)
                        items.append(ServiceEvidence(label: label, plistPath: Self.normalized(file.path),
                            executable: program.flatMap { $0.hasPrefix("/") ? Self.normalized($0) : nil }, referencedPaths: references))
                    } catch { warnings.append("无法读取服务配置：\(file.path)") }
                }
            } catch { warnings.append("无法列出服务目录：\(root.path)") }
        }
        return (items, warnings)
    }

    /// Uses fixed arguments and a bounded capture file instead of shell interpolation
    /// or a pipe that can deadlock when lsof produces a large result.
    func runtime(timeout: TimeInterval = 12, token: ScanToken? = nil) -> RuntimeEvidence {
        var evidence = RuntimeEvidence()
        if token?.isCancelled == true { evidence.warnings = ["打开文件观察已取消。"]; return evidence }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("CleanMac-lsof-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            let outputURL = scratch.appendingPathComponent("output")
            let errorURL = scratch.appendingPathComponent("error")
            fm.createFile(atPath: outputURL.path, contents: nil)
            fm.createFile(atPath: errorURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            let errors = try FileHandle(forWritingTo: errorURL)
            defer { try? output.close(); try? errors.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-nP", "-Fpcn"]
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            let maximumBytes = 32 * 1024 * 1024
            while process.isRunning && Date() < deadline && token?.isCancelled != true {
                let size = (try? fm.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > maximumBytes { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if token?.isCancelled == true { evidence.warnings.append("打开文件观察已取消。") }
            if process.isRunning {
                process.terminate()
                // Do not let a blocked external observer stall the UI indefinitely.
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                evidence.warnings.append("打开文件观察超时或达到 32 MiB 上限，证据不完整。")
            }
            if token?.isCancelled == true { return evidence }
            let input = try FileHandle(forReadingFrom: outputURL)
            defer { try? input.close() }
            let data = try input.read(upToCount: maximumBytes) ?? Data()
            let totalBytes = (try? fm.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if totalBytes > maximumBytes && evidence.warnings.isEmpty { evidence.warnings.append("打开文件记录超过 32 MiB，证据已截断。") }
            evidence.openFiles = Self.parseOpenFiles(String(decoding: data, as: UTF8.self), token: token)
            if evidence.openFiles.count > 100_000 {
                evidence.openFiles = Array(evidence.openFiles.prefix(100_000))
                evidence.warnings.append("打开文件超过 100,000 条，证据已截断。")
            }
            let errorInput = try FileHandle(forReadingFrom: errorURL)
            defer { try? errorInput.close() }
            let errorData = try errorInput.read(upToCount: 4096) ?? Data()
            if !errorData.isEmpty { evidence.warnings.append("lsof 报告权限或访问限制，可能遗漏使用者。") }
            if process.terminationStatus != 0 { evidence.warnings.append("lsof 未正常完成（\(process.terminationStatus)）。") }
            evidence.querySucceeded = evidence.warnings.isEmpty
        } catch { evidence.warnings.append("无法观察进程打开文件：\(error.localizedDescription)") }
        return evidence
    }

    static func parseOpenFiles(_ text: String, token: ScanToken? = nil) -> [OpenFileEvidence] {
        var pid: Int?
        var command = ""
        var result = Set<OpenFileEvidence>()
        for line in text.split(separator: "\n") {
            if token?.isCancelled == true { return [] }
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p": pid = Int(value); command = ""
            case "c": command = value
            case "n":
                if let pid, value.hasPrefix("/") {
                    result.insert(OpenFileEvidence(pid: pid, command: command, path: normalized(value)))
                }
            default: break
            }
        }
        return result.sorted { ($0.path, $0.pid) < ($1.path, $1.pid) }
    }

    static func normalized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    static func contains(_ root: String, _ path: String) -> Bool { root == path || path.hasPrefix(root == "/" ? "/" : root + "/") }
}
