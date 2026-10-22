import Foundation

/// Plain values are assembled off the main actor. Never mutate an @Published
/// dictionary per directory: Combine's value snapshots can force repeated copies.
nonisolated struct PreparedScanPublication: Sendable {
    var summary: ScanResult?
    var children: [String: [DirectoryEntry]]
    var sizes: [String: Int64]
    var warnings: [String: String]
    var expanded: Set<String>
    var rows: [DirectoryEntry]
}

nonisolated enum ScanPublicationPreparer {
    typealias Progress = @Sendable (_ stage: String, _ count: Int) -> Void

    static func fullScan(_ result: ScanResult, previous: PreparedScanPublication,
                         roots: [DirectoryEntry], token: ScanToken,
                         progress: Progress = { _, _ in }) throws -> PreparedScanPublication {
        try token.checkCancellation()
        if result.cancelled { throw CancellationError() }
        var summary = result
        // The UI/cache already own the tree separately. Do not keep another
        // long-lived copy in ScanResult when a subtree is subsequently refreshed.
        summary.directorySnapshot = nil
        guard let snapshot = result.directorySnapshot else {
            var prepared = previous
            prepared.summary = summary
            return prepared
        }
        if snapshot.cancelled { throw CancellationError() }
        var warnings: [String: String] = [:]
        if snapshot.unreadableCount > 0 {
            warnings.reserveCapacity(snapshot.childrenByPath.count)
            let warning = "有 \(snapshot.unreadableCount) 项无法读取，当前为可读取内容的统计。"
            var count = 0
            for path in snapshot.childrenByPath.keys {
                try token.checkCancellation()
                warnings[path] = warning
                count += 1
                if count.isMultiple(of: 16_384) { progress("告警", count) }
            }
        }
        let rows = try filesystemRows(roots: roots, children: snapshot.childrenByPath,
            sizes: snapshot.sizesByPath, expanded: previous.expanded, token: token, progress: progress)
        try token.checkCancellation()
        return PreparedScanPublication(summary: summary, children: snapshot.childrenByPath,
            sizes: snapshot.sizesByPath, warnings: warnings, expanded: previous.expanded, rows: rows)
    }

    static func directoryRefresh(_ outcome: DirectoryScanResult, root: String,
                                 previous: PreparedScanPublication, roots: [DirectoryEntry], token: ScanToken,
                                 progress: Progress = { _, _ in }) throws -> PreparedScanPublication {
        try token.checkCancellation()
        if outcome.cancelled { throw CancellationError() }
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        func belongsToRefresh(_ path: String) -> Bool {
            path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
        }
        var prepared = previous
        var count = 0
        // Mutate local, ordinary dictionaries only. The old state remains intact
        // until all preparation and the final cancellation check have succeeded.
        for path in previous.children.keys {
            try token.checkCancellation()
            if belongsToRefresh(path) { prepared.children.removeValue(forKey: path) }
            count += 1
            if count.isMultiple(of: 16_384) { progress("替换目录", count) }
        }
        for path in previous.sizes.keys {
            try token.checkCancellation()
            if belongsToRefresh(path) { prepared.sizes.removeValue(forKey: path) }
        }
        for path in previous.warnings.keys {
            try token.checkCancellation()
            if belongsToRefresh(path) { prepared.warnings.removeValue(forKey: path) }
        }
        let warning = outcome.unreadableCount > 0
            ? "有 \(outcome.unreadableCount) 项无法读取，当前占用为可读取部分。请检查完全磁盘访问权限。" : nil
        count = 0
        for (path, entries) in outcome.childrenByPath {
            try token.checkCancellation()
            prepared.children[path] = entries
            prepared.warnings[path] = warning
            count += 1
            if count.isMultiple(of: 16_384) { progress("合并目录", count) }
        }
        for (path, size) in outcome.sizesByPath {
            try token.checkCancellation()
            prepared.sizes[path] = size
        }
        prepared.sizes[root] = outcome.rootSize
        prepared.expanded.insert(root)
        prepared.rows = try filesystemRows(roots: roots, children: prepared.children,
            sizes: prepared.sizes, expanded: prepared.expanded, token: token, progress: progress)
        try token.checkCancellation()
        return prepared
    }

    static func filesystemRows(roots: [DirectoryEntry], children: [String: [DirectoryEntry]],
                               sizes: [String: Int64], expanded: Set<String>, token: ScanToken,
                               progress: Progress = { _, _ in }) throws -> [DirectoryEntry] {
        var rows: [DirectoryEntry] = []
        // Iterative traversal also avoids stack overflow for deeply expanded trees.
        var pending = roots.reversed().map { (entry: $0, depth: 0, rootID: $0.path) }
        while let item = pending.popLast() {
            try token.checkCancellation()
            let entry = item.entry
            let size = sizes[entry.path] ?? entry.size
            rows.append(DirectoryEntry(id: item.rootID + "::" + entry.path, name: entry.name,
                path: entry.path, size: size, sizeText: sizes[entry.path] != nil ? CleanMacFormat.bytes(size) : entry.sizeText,
                depth: item.depth, isHidden: entry.isHidden))
            if rows.count.isMultiple(of: 16_384) { progress("可见目录", rows.count) }
            guard expanded.contains(entry.path), let descendants = children[entry.path] else { continue }
            for child in descendants.reversed() where child.isDirectory {
                try token.checkCancellation()
                pending.append((entry: child, depth: item.depth + 1, rootID: item.rootID))
            }
        }
        return rows
    }
}
