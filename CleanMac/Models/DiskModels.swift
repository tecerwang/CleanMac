import Foundation

// MARK: - 文件系统浏览

nonisolated struct DirectoryEntry: Identifiable, Sendable, Codable {
    let id: String
    let name: String
    let path: String
    let size: Int64
    let sizeText: String
    let depth: Int
    let isHidden: Bool
    var isDirectory: Bool = true
}

nonisolated struct DirectoryScanResult: Sendable, Codable {
    var entries: [DirectoryEntry] = []
    var rootSize: Int64 = 0
    var unreadableCount = 0
    var cancelled = false
    var childrenByPath: [String: [DirectoryEntry]] = [:]
    var sizesByPath: [String: Int64] = [:]
}

// MARK: - 磁盘条目

nonisolated enum DiskItemKind: Sendable, Codable {
    case file, folder
}

nonisolated struct DiskItem: Identifiable, Sendable, Codable {
    let id: String
    let name: String
    let absolutePath: String
    let path: String
    let size: Int64
    let sizeText: String
    let source: String
    let evidence: String
    let kind: DiskItemKind
    let isResidue: Bool
    let isHidden: Bool
}

nonisolated struct InstalledApp: Sendable, Codable {
    let name: String
    let bundleIdentifier: String
    /// 显示路径（以 ~ 开头缩写），非绝对路径
    let displayPath: String
    let version: String
    let isSystemApp: Bool
}

nonisolated struct ScanResult: Sendable, Codable {
    let generatedAt: String
    let duration: TimeInterval
    let entryCount: Int
    let installedApps: [InstalledApp]
    let largestFiles: [DiskItem]
    let largestFolders: [DiskItem]
    let residues: [DiskItem]
    let errors: [String]
    let scanLimitReached: Bool
    let cancelled: Bool
    var directorySnapshot: DirectoryScanResult? = nil

    var durationText: String { String(format: "%.1f 秒", duration) }

    var hasPermissionErrors: Bool {
        errors.contains {
            $0.localizedCaseInsensitiveContains("permission") ||
            $0.localizedCaseInsensitiveContains("denied") ||
            $0.localizedCaseInsensitiveContains("不允许") ||
            $0.localizedCaseInsensitiveContains("权限")
        }
    }
}

nonisolated struct ScanProgress: Sendable {
    let phase: String
    let scannedEntries: Int
    /// nil 表示进度不可预估（不确定进度条）
    let fraction: Double?
}

// MARK: - 磁盘卷

nonisolated struct VolumeInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let total: Int64
    let used: Int64
    let free: Int64

    var usedFraction: Double {
        total > 0 ? min(1, max(0, Double(used) / Double(total))) : 0
    }
}
