import Foundation

/// 全局格式化工具（零依赖模块，供 Models / Engine / Views 共用）。
nonisolated enum CleanMacFormat {
    // ByteCountFormatter / DateFormatter 构造开销大且线程安全，
    // 缓存实例避免在扫描热路径上反复创建。
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        byteFormatter.string(fromByteCount: count)
    }

    static func timestamp() -> String {
        dateFormatter.string(from: Date())
    }
}
