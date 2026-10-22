import Foundation

// MARK: - 垃圾清理

nonisolated struct JunkItem: Identifiable, Sendable {
    let id: String
    let path: String
    let displayPath: String
    let name: String
    let size: Int64
    let sizeText: String
    let categoryID: String
    /// 已经位于废纸篓中的项目只能永久删除，不能再“移入废纸篓”
    let permanentDeleteOnly: Bool
}

nonisolated struct JunkCategory: Identifiable, Sendable {
    let id: String
    let name: String
    let icon: String
    let detail: String
    let defaultChecked: Bool
    let items: [JunkItem]

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var totalSizeText: String { CleanMacFormat.bytes(totalSize) }
}

// MARK: - 卸载器

nonisolated struct AppEntry: Identifiable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let path: String
    let version: String
    let size: Int64
    let sizeText: String
    let isSystemApp: Bool
}

// MARK: - 清理报告

nonisolated struct CleanupReport: Sendable {
    let movedCount: Int
    let failedCount: Int
    let freedBytes: Int64
    let errors: [String]

    var freedText: String { CleanMacFormat.bytes(freedBytes) }
}
