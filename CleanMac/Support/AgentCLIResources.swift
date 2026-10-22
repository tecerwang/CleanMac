import Foundation

nonisolated enum AgentCLIResources {
    static let documentationRelativePath = "CLI.md"

    static var executableURL: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cleanmac")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.standardizedFileURL }
        let launched = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        if launched.lastPathComponent == "cleanmac", FileManager.default.isExecutableFile(atPath: launched.path) { return launched }
        return nil
    }

    static func resource(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent(name)) }
        let launched = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let folder = launched.deletingLastPathComponent()
        candidates += [folder.appendingPathComponent(name),
            folder.appendingPathComponent("../Resources/" + name).standardizedFileURL,
            folder.appendingPathComponent("CleanMac.app/Contents/Resources/" + name)]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
