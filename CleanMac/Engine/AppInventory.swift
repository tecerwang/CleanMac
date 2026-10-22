import Foundation
import AppKit

/// 已安装应用清单（/Applications、/System/Applications、~/Applications）。
/// 独立成类型后，DiskScanner 与 UninstallerScanner 都依赖它，
/// 不再产生 Uninstaller → Disk 的跨类型耦合。
nonisolated struct AppInventory {
    private let fileManager = FileManager.default
    private let homeURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL
    }

    func apps(token: ScanToken? = nil) -> [InstalledApp] {
        let locations = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            homeURL.appendingPathComponent("Applications")
        ]
        var result: [InstalledApp] = []
        var seen = Set<String>()
        for location in locations {
            if token?.isCancelled == true { return [] }
            guard let enumerator = fileManager.enumerator(
                at: location,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let app as URL in enumerator where app.pathExtension == "app" && seen.insert(app.path).inserted {
                if token?.isCancelled == true { return [] }
                enumerator.skipDescendants()
                let infoURL = app.appendingPathComponent("Contents/Info.plist")
                let info = NSDictionary(contentsOf: infoURL) as? [String: Any]
                let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent
                let identifier = (info?["CFBundleIdentifier"] as? String) ?? ""
                let version = (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String) ?? ""
                let isSystem = app.path.hasPrefix("/System/")
                result.append(InstalledApp(
                    name: name,
                    bundleIdentifier: identifier,
                    displayPath: CleanMacPath.display(app.path, home: homeURL.path),
                    version: version,
                    isSystemApp: isSystem
                ))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
