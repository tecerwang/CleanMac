import Foundation

/// 删除引擎：把选中的项目移入废纸篓（可恢复）或永久删除（仅废纸篓内容）。
/// 所有删除入口都经过受保护路径校验，避免误伤系统目录。
nonisolated struct CleanupEngine {
    private let fileManager = FileManager.default

    /// 判断路径是否属于系统保护目录（拒绝删除）。
    static func isProtectedPath(_ path: String, home: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized == "/" || normalized == home || normalized == "/Users" || normalized == "/Applications" {
            return true
        }
        let protectedRoots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/opt", "/Volumes"]
        for root in protectedRoots where normalized == root || normalized.hasPrefix(root + "/") {
            return true
        }
        return false
    }

    /// 去掉父子嵌套路径：父目录已被选中时，其子孙无需重复处理。
    private func deduplicated(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths))
        return unique.filter { candidate in
            !unique.contains { other in
                candidate != other && candidate.hasPrefix(other + "/")
            }
        }
    }

    /// 把选中的项目移入废纸篓（可恢复）。
    func moveToTrash(_ paths: [String], token: ScanToken? = nil, progress: @escaping @Sendable (Int, Int, String) -> Void = { _, _, _ in }) -> CleanupReport {
        let ordered = deduplicated(paths)
        let home = fileManager.homeDirectoryForCurrentUser.path
        var moved = 0
        var freed: Int64 = 0
        var failures: [String] = []
        let total = ordered.count
        for (index, path) in ordered.enumerated() {
            if token?.isCancelled == true { break }
            progress(index + 1, total, path)
            if Self.isProtectedPath(path, home: home) {
                failures.append("\(path)：受系统保护的路径，已跳过")
                continue
            }
            let url = URL(fileURLWithPath: path)
            let size = DirectoryScanner().sizeOf(url)
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                moved += 1
                freed += size
            } catch {
                failures.append("\(path)：\(error.localizedDescription)")
            }
        }
        return CleanupReport(movedCount: moved, failedCount: failures.count, freedBytes: freed, errors: failures)
    }

    /// 永久删除（仅用于已经在废纸篓里的内容，即“清空废纸篓”）。
    func permanentlyDelete(_ paths: [String], token: ScanToken? = nil, progress: @escaping @Sendable (Int, Int, String) -> Void = { _, _, _ in }) -> CleanupReport {
        let ordered = deduplicated(paths)
        var removed = 0
        var freed: Int64 = 0
        var failures: [String] = []
        let total = ordered.count
        for (index, path) in ordered.enumerated() {
            if token?.isCancelled == true { break }
            progress(index + 1, total, path)
            let url = URL(fileURLWithPath: path)
            let size = DirectoryScanner().sizeOf(url)
            do {
                try fileManager.removeItem(at: url)
                removed += 1
                freed += size
            } catch {
                failures.append("\(path)：\(error.localizedDescription)")
            }
        }
        return CleanupReport(movedCount: removed, failedCount: failures.count, freedBytes: freed, errors: failures)
    }
}
