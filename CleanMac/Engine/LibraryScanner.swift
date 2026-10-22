import Foundation

/// 开发库查询：统计各开发生态（npm / Python / Homebrew 等）库目录的占用。
nonisolated struct LibraryScanner {
    private let fileManager = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser

    func scan(source: LibrarySource, token: ScanToken? = nil, progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async -> [DiskItem] {
        if token?.isCancelled == true { return [] }
        let roots = libraryRoots(for: source, token: token, progress: progress)
        var seen = Set<String>()
        var results: [DiskItem] = []
        for root in roots where seen.insert(root.path).inserted {
            if token?.isCancelled == true { break }
            let outcome = await DirectoryScanner().scanDirectory(at: root, token: token, includeRootWhenEmpty: true) { update in
                progress(ScanProgress(phase: "查询 \(source.rawValue)：\(root.path)", scannedEntries: update.scannedEntries, fraction: nil))
            }
            results += outcome.entries.map { child in
                DiskItem(
                    id: child.id,
                    name: child.name,
                    absolutePath: child.path,
                    path: displayPath(child.path),
                    size: child.size,
                    sizeText: child.sizeText,
                    source: "\(source.rawValue) 库",
                    evidence: "库目录：\(displayPath(root.path))",
                    kind: .folder,
                    isResidue: false,
                    isHidden: child.isHidden
                )
            }
        }
        return results.sorted { $0.size > $1.size }
    }

    private func libraryRoots(for source: LibrarySource, token: ScanToken?, progress: @escaping @Sendable (ScanProgress) -> Void) -> [URL] {
        let roots: [URL]
        switch source {
        case .npm:
            roots = [
                home.appendingPathComponent(".npm"),
                home.appendingPathComponent("node_modules"),
                home.appendingPathComponent("Library/Caches/Yarn"),
                home.appendingPathComponent("Library/pnpm/store"),
                home.appendingPathComponent("Library/Caches/pnpm"),
                URL(fileURLWithPath: "/usr/local/lib/node_modules"),
                URL(fileURLWithPath: "/opt/homebrew/lib/node_modules")
            ]
        case .python:
            roots = [
                home.appendingPathComponent("Library/Python"),
                home.appendingPathComponent(".cache/pip"),
                home.appendingPathComponent(".local/lib"),
                home.appendingPathComponent(".pyenv/versions")
            ]
        case .homebrew:
            roots = [
                URL(fileURLWithPath: "/opt/homebrew/Cellar"),
                URL(fileURLWithPath: "/usr/local/Cellar"),
                URL(fileURLWithPath: "/opt/homebrew/var/homebrew/linked"),
                URL(fileURLWithPath: "/usr/local/var/homebrew/linked")
            ]
        case .cocoapods:
            roots = [
                home.appendingPathComponent("Library/Caches/CocoaPods"),
                home.appendingPathComponent(".cocoapods")
            ]
        case .rubyGems:
            roots = [
                home.appendingPathComponent(".gem"),
                URL(fileURLWithPath: "/Library/Ruby/Gems"),
                URL(fileURLWithPath: "/opt/homebrew/lib/ruby/gems"),
                URL(fileURLWithPath: "/usr/local/lib/ruby/gems")
            ]
        case .cargo:
            roots = [home.appendingPathComponent(".cargo/registry"), home.appendingPathComponent(".cargo/git")]
        case .go:
            roots = [home.appendingPathComponent("go/pkg/mod"), home.appendingPathComponent("Library/Caches/go-build")]
        case .maven:
            roots = [home.appendingPathComponent(".m2/repository")]
        case .gradle:
            roots = [home.appendingPathComponent(".gradle/caches"), home.appendingPathComponent(".gradle/wrapper/dists")]
        case .nuget:
            roots = [home.appendingPathComponent(".nuget/packages")]
        case .composer:
            roots = [home.appendingPathComponent(".composer/cache"), home.appendingPathComponent("Library/Caches/composer")]
        case .dart:
            roots = [home.appendingPathComponent(".pub-cache")]
        case .swiftPM:
            roots = [
                home.appendingPathComponent("Library/Caches/org.swift.swiftpm"),
                home.appendingPathComponent("Library/org.swift.swiftpm")
            ]
        case .carthage:
            roots = [home.appendingPathComponent("Library/Caches/org.carthage.CarthageKit")]
        case .conan:
            roots = [home.appendingPathComponent(".conan2"), home.appendingPathComponent(".conan")]
        case .vcpkg:
            roots = [home.appendingPathComponent(".vcpkg"), URL(fileURLWithPath: "/usr/local/share/vcpkg")]
        case .bazel:
            roots = [home.appendingPathComponent("Library/Caches/bazel"), home.appendingPathComponent(".cache/bazel")]
        }
        return normalizedExistingRoots(roots + discoverProjectRoots(for: source, token: token, progress: progress))
    }

    private func discoverProjectRoots(for source: LibrarySource, token: ScanToken?, progress: @escaping @Sendable (ScanProgress) -> Void) -> [URL] {
        let names: Set<String>
        switch source {
        case .npm: names = ["node_modules"]
        case .python: names = ["site-packages", "dist-packages", ".venv"]
        case .cocoapods: names = ["Pods"]
        case .go, .composer: names = ["vendor"]
        case .swiftPM: names = ["checkouts"]
        case .carthage: names = ["Carthage"]
        default: return []
        }

        guard let enumerator = fileManager.enumerator(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        let maximumEntries = 500_000
        var scanned = 0
        var matches: [URL] = []
        for case let url as URL in enumerator {
            if token?.isCancelled == true { return [] }
            scanned += 1
            guard scanned <= maximumEntries else { break }
            if scanned.isMultiple(of: 2_000) {
                progress(ScanProgress(phase: "定位项目库", scannedEntries: scanned, fraction: nil))
            }
            guard names.contains(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            matches.append(url)
            enumerator.skipDescendants()
        }
        return matches
    }

    private func normalizedExistingRoots(_ roots: [URL]) -> [URL] {
        let unique = Array(Set(roots.map { $0.standardizedFileURL.path })).sorted { $0.count < $1.count }
        var selected: [String] = []
        for path in unique where fileManager.fileExists(atPath: path) {
            guard !selected.contains(where: { path.hasPrefix($0 + "/") || path == $0 }) else { continue }
            selected.append(path)
        }
        return selected.map(URL.init(fileURLWithPath:))
    }

    private func displayPath(_ path: String) -> String {
        CleanMacPath.display(path, home: home.path)
    }
}
