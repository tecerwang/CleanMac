import Foundation

/// Keep scan snapshots in Application Support: they survive restarts and have
/// no expiry. Refreshing is the only operation that replaces these records.
nonisolated struct PersistedScanCache: Codable, Sendable {
    var version = 1
    var savedAt = Date()
    var result: ScanResult?
    var directoryChildren: [String: [DirectoryEntry]]
    var directorySizes: [String: Int64]
    var directoryWarnings: [String: String]
    var libraryItems: [DiskItem]
    var librarySource: String?
    var expandedDirectories: Set<String>
    var libraryResults: [String: [DiskItem]]? = nil
}

actor ScanCacheStore {
    private let url: URL

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CleanMac/scan-cache.plist")) {
        self.url = url
    }

    func load() throws -> PersistedScanCache? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let cache = try PropertyListDecoder().decode(PersistedScanCache.self, from: Data(contentsOf: url))
        guard cache.version == 1 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return cache
    }

    func save(_ cache: PersistedScanCache) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(cache)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic replacement leaves the previous snapshot intact if writing fails.
        try data.write(to: url, options: .atomic)
    }
}
