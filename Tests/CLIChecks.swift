import Foundation
import Darwin

struct CLIResult {
    let status: Int32
    let json: [String: Any]
    let progress: String
}

@main
struct CLIChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func execute(_ cli: URL, _ arguments: [String], logs: URL,
                        cancelAfterProgress: Bool = false, cancellationSignal: Int32 = SIGINT) throws -> CLIResult {
        let run = logs.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let stdout = run.appendingPathComponent("stdout.json")
        let stderr = run.appendingPathComponent("stderr.jsonl")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let output = try FileHandle(forWritingTo: stdout)
        let errors = try FileHandle(forWritingTo: stderr)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(40)
        var sentSignal = false
        while process.isRunning {
            if cancelAfterProgress && !sentSignal {
                let text = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
                if text.contains("scannedEntries") {
                    kill(process.processIdentifier, cancellationSignal)
                    sentSignal = true
                }
            }
            if Date() > deadline {
                kill(process.processIdentifier, SIGKILL)
                fatalError("CLI timeout: \(arguments.first ?? "")")
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        process.waitUntilExit()
        if cancelAfterProgress { require(sentSignal, "CLI finished before cancellation checkpoint") }
        let data = try Data(contentsOf: stdout)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { fatalError("stdout is not one JSON object") }
        require(json["schemaVersion"] as? Int == 1, "Missing JSON schema version")
        let progress = try String(contentsOf: stderr, encoding: .utf8)
        for line in progress.split(separator: "\n") {
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            require(value["event"] as? String == "progress", "stderr contains non-protocol progress")
        }
        return CLIResult(status: process.terminationStatus, json: json, progress: progress)
    }

    static func success(_ result: CLIResult) -> [String: Any] {
        require(result.status == 0 && result.json["ok"] as? Bool == true, "Command failed: \(result.json)")
        return result.json["data"] as! [String: Any]
    }

    static func main() throws {
        let fm = FileManager.default
        let repository = URL(fileURLWithPath: fm.currentDirectoryPath)
        let cli = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let logs = fixture.appendingPathComponent("runs")
        let input = fixture.appendingPathComponent("input with spaces ' $() \n测试")
        try fm.createDirectory(at: input.appendingPathComponent("app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: input.appendingPathComponent("app2"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: input.appendingPathComponent("app/payload.bin"))
        try Data("two".utf8).write(to: input.appendingPathComponent("app2/other.bin"))
        try Data("quoted".utf8).write(to: input.appendingPathComponent("a ' $()\nfile.txt"))
        let caps = success(try execute(cli, ["capabilities"], logs: logs))
        require((caps["destructiveCommands"] as! [String]).isEmpty && caps["writesGUICache"] as? Bool == false, "Unsafe CLI capabilities")
        require(fm.fileExists(atPath: caps["cliDocumentation"] as! String), "CLI cannot locate bundled documentation")
        let helper = repository.appendingPathComponent("build/Build/Products/Release/CleanMac.app/Contents/Helpers/cleanmac")
        let bundled = success(try execute(helper, ["capabilities"], logs: logs))
        require(fm.fileExists(atPath: bundled["cliDocumentation"] as! String), "Embedded CLI cannot locate documentation")
        print("PASS standalone and embedded CLI discovery; JSON-only output, no destructive commands")

        let reports = fixture.appendingPathComponent("reports")
        let scan = success(try execute(cli, ["scan", "--path", input.path, "--output-root", reports.path], logs: logs))
        let overview = URL(fileURLWithPath: scan["directory"] as! String)
        let doc = overview.appendingPathComponent("CLI.md")
        let sourceDoc = try Data(contentsOf: repository.appendingPathComponent("Docs/CLI.md"))
        let exportedDoc = try Data(contentsOf: doc)
        require(sourceDoc == exportedDoc, "CLI documentation not copied exactly")
        let prompt = try String(contentsOf: overview.appendingPathComponent("agent-prompt.txt"), encoding: .utf8)
        let quotedDoc = String(decoding: try JSONEncoder().encode(doc.path), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        require(prompt.contains(quotedDoc) && prompt.contains("CLI 可执行文件") && prompt.contains(cli.path), "Prompt lacks real CLI/document paths")
        let inspect = success(try execute(cli, ["inspect", "--overview", overview.path], logs: logs))
        require(inspect["overviewID"] as? String == scan["overviewID"] as? String, "Inspect returned wrong artifact")
        require(inspect["cliDocumentation"] as? String == doc.path, "Inspect documentation path is not the exported file")
        var seen = Set<String>()
        var offset = 0
        repeat {
            let page = success(try execute(cli, ["entries", "--overview", overview.path, "--limit", "2", "--offset", String(offset)], logs: logs))
            for item in page["items"] as! [[String: Any]] {
                require(seen.insert(item["path"] as! String).inserted, "Pagination duplicated a record")
            }
            guard let next = page["nextOffset"] as? Int else { break }
            require(next > offset, "Cursor did not advance")
            offset = next
        } while true
        require(seen.count == inspect["recordCount"] as! Int, "Pagination missed records")
        let filtered = success(try execute(cli, ["entries", "--overview", overview.path, "--path-prefix", input.appendingPathComponent("app").path], logs: logs))
        let items = filtered["items"] as! [[String: Any]]
        require(items.count == 2 && items.allSatisfy { !($0["path"] as! String).contains("/app2") }, "Path prefix leaked into neighboring directory")
        print("PASS scan / inspect / paginated entries, quoted Unicode paths, component boundaries, actual CLI.md path in prompt")

        let beforeAnalysisEntries = try Data(contentsOf: overview.appendingPathComponent("entries.jsonl"))
        let missing = try execute(cli, ["findings", "--overview", overview.path], logs: logs)
        require(missing.status == 1, "findings silently ran analysis")
        _ = success(try execute(cli, ["analyze", "--overview", overview.path], logs: logs))
        let findings = success(try execute(cli, ["findings", "--overview", overview.path, "--disposition", "retain"], logs: logs))
        require(!(findings["items"] as! [[String: Any]]).isEmpty, "Findings query returned no protected fixture records")
        let afterAnalysisEntries = try Data(contentsOf: overview.appendingPathComponent("entries.jsonl"))
        require(beforeAnalysisEntries == afterAnalysisEntries, "Analysis rewrote input records")
        let pointer = overview.appendingPathComponent("latest-analysis.json")
        let previousPointer = try Data(contentsOf: pointer)
        try JSONEncoder().encode("../../outside").write(to: pointer)
        let traversal = try execute(cli, ["findings", "--overview", overview.path], logs: logs)
        require(traversal.status == 1, "Analysis traversal pointer accepted")
        let name = "analysis-" + UUID().uuidString
        let outside = fixture.appendingPathComponent("outside-analysis")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: overview.appendingPathComponent(name), withDestinationURL: outside)
        try JSONEncoder().encode(name).write(to: pointer)
        let escaped = try execute(cli, ["findings", "--overview", overview.path], logs: logs)
        require(escaped.status == 1, "Analysis symlink escape accepted")
        try previousPointer.write(to: pointer)
        print("PASS analyze / findings; original entries retained; traversal and symlinked analysis pointers rejected")

        let cachePath = input.appendingPathComponent("cached").standardizedFileURL.path
        let cacheURL = fixture.appendingPathComponent("fixture-cache.plist")
        let cache: [String: Any] = ["version": 1, "savedAt": Date(timeIntervalSince1970: 123),
            "directoryChildren": [cachePath: [["id": cachePath + "/data", "name": "data", "path": cachePath + "/data", "size": 3,
                "sizeText": "3 B", "depth": 1, "isHidden": false, "isDirectory": false]], cachePath + "-neighbor": []],
            "directorySizes": [cachePath: 3, cachePath + "-neighbor": 99], "directoryWarnings": [cachePath: "fixture warning"],
            "libraryItems": [], "expandedDirectories": []]
        let cacheBytes = try PropertyListSerialization.data(fromPropertyList: cache, format: .binary, options: 0)
        try cacheBytes.write(to: cacheURL)
        let exported = success(try execute(cli, ["export", "--cache", cacheURL.path, "--path", cachePath,
            "--lifetime", "persistent", "--output-root", reports.path], logs: logs))
        require(exported["roots"] as? [String] == [cachePath], "Cache export included unrelated roots")
        let cacheAfterExport = try Data(contentsOf: cacheURL)
        require(cacheAfterExport == cacheBytes, "CLI export overwrote cache")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: exported["directory"] as! String).appendingPathComponent("manifest.json"))) as! [String: Any]
        require(manifest["lifetime"] as? String == "持久化概述", "Persistent lifetime lost")
        let exportPrompt = try String(contentsOf: URL(fileURLWithPath: exported["directory"] as! String).appendingPathComponent("agent-prompt.txt"), encoding: .utf8)
        require(exportPrompt.contains("1970-01-01T00:02:03Z"), "Export falsely presented current time as cache refresh time")
        print("PASS read-only cache export / scope / persistent lifetime; input cache unchanged byte-for-byte")

        let standaloneRoot = fixture.appendingPathComponent("standalone")
        let resourceRoot = fixture.appendingPathComponent("trusted resources")
        try fm.createDirectory(at: standaloneRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourceRoot, withIntermediateDirectories: true)
        let standalone = standaloneRoot.appendingPathComponent("cleanmac")
        try fm.copyItem(at: cli, to: standalone)
        let bare = success(try execute(standalone, ["capabilities"], logs: logs))
        require(bare["cliDocumentation"] is NSNull, "Bare CLI invented a documentation path")
        try fm.copyItem(at: repository.appendingPathComponent("Docs/CLI.md"), to: resourceRoot.appendingPathComponent("CLI.md"))
        try fm.copyItem(at: repository.appendingPathComponent("CleanMac/Resources/Skills/cleanmac-disk-analysis/SKILL.md"), to: resourceRoot.appendingPathComponent("SKILL.md"))
        _ = success(try execute(standalone, ["scan", "--path", input.path, "--output-root", reports.path, "--resources", resourceRoot.path], logs: logs))
        print("PASS relocated CLI / explicit trusted resources / missing-resource capability null")

        for arguments in [["scan"], ["scan", "--all", "--path", input.path], ["trash"],
            ["inspect", "--overview", "relative/path"], ["entries", "--overview", overview.path, "--limit", "0"],
            ["inspect", "--overview", overview.path, "--overview", overview.path],
            ["findings", "--overview", overview.path, "--disposition", "delete"]] {
            let result = try execute(cli, arguments, logs: logs)
            require(result.status == 2 && result.json["ok"] as? Bool == false, "Invalid/destructive invocation accepted: \(arguments)")
        }
        print("PASS invalid/missing/duplicate options, relative paths, unsafe commands rejected without scanning")

        let wide = fixture.appendingPathComponent("cancel-input")
        try fm.createDirectory(at: wide, withIntermediateDirectories: true)
        for index in 0..<20_000 { fm.createFile(atPath: wide.appendingPathComponent("item-\(index)").path, contents: Data([1])) }
        for signalNumber in [SIGINT, SIGTERM] {
            let cancelOutput = fixture.appendingPathComponent("cancel-output-\(signalNumber)")
            let cancelled = try execute(cli, ["scan", "--path", wide.path, "--output-root", cancelOutput.path], logs: logs,
                cancelAfterProgress: true, cancellationSignal: signalNumber)
            require(cancelled.status == 130 && cancelled.json["ok"] as? Bool == false, "Signal did not return cancellation JSON / 130")
            let published = (try? fm.contentsOfDirectory(at: cancelOutput, includingPropertiesForKeys: nil)) ?? []
            require(published.isEmpty, "Cancelled CLI scan published an artifact")
        }
        let inputBytes = try Data(contentsOf: input.appendingPathComponent("app/payload.bin"))
        require(inputBytes == Data("one".utf8), "CLI changed an original file")
        print("PASS SIGINT / SIGTERM during real scans: exit 130, no artifact published, original inputs retained")
        print("All CLI checks passed. Fixtures retained: \(fixture.path)")
    }
}
