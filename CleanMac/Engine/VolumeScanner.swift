import Foundation

/// 磁盘卷信息：总量 / 已用 / 可用。
nonisolated struct VolumeScanner {
    private let fileManager = FileManager.default

    func volumes() -> [VolumeInfo] {
        var urls: [URL] = [URL(fileURLWithPath: "/")]
        if let mounted = try? fileManager.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil, options: []) {
            urls += mounted
        }
        var result: [VolumeInfo] = []
        var seen = Set<String>()
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey, .isVolumeKey]) else { continue }
            guard values.isVolume == true, let total = values.volumeTotalCapacity, total > 0 else { continue }
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let used = max(Int64(0), Int64(total) - available)
            let name = values.volumeName ?? (url.path == "/" ? FileManager.default.displayName(atPath: "/") : url.lastPathComponent)
            result.append(VolumeInfo(id: url.path, name: name, path: url.path, total: Int64(total), used: used, free: available))
        }
        return result.sorted { $0.path == "/" ? true : ($0.path < $1.path) }
    }
}
