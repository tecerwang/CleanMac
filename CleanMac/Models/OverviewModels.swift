import Foundation

nonisolated enum OverviewLifetime: String, CaseIterable, Identifiable, Sendable {
    case temporary = "临时概述"
    case persistent = "持久化概述"
    var id: String { rawValue }
}

nonisolated struct ServiceEvidence: Codable, Sendable {
    let label: String
    let plistPath: String
    let executable: String?
    let referencedPaths: [String]
}

nonisolated struct OpenFileEvidence: Codable, Sendable, Hashable {
    let pid: Int
    let command: String
    let path: String
}

nonisolated struct RuntimeEvidence: Codable, Sendable {
    var observedAt = Date()
    var openFiles: [OpenFileEvidence] = []
    var warnings: [String] = []
    var querySucceeded = false
}

nonisolated struct OverviewManifest: Codable, Sendable {
    var schemaVersion = 1
    let id: String
    let createdAt: Date
    let cacheSavedAt: Date?
    let homePath: String
    let lifetime: String
    let roots: [String]
    let recordCount: Int
    let warnings: [String]
    let applications: [InstalledApp]
    let services: [ServiceEvidence]
    let runtime: RuntimeEvidence
}

nonisolated struct OverviewRecord: Codable, Sendable {
    let path: String
    let cachedBytes: Int64
    let isDirectory: Bool
}

nonisolated struct OwnershipEvidence: Codable, Sendable, Hashable {
    let owner: String
    let kind: String
    let confidence: String
    let reason: String
    let sourcePath: String?
    let pid: Int?
}

nonisolated struct FileFingerprint: Codable, Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedAt: Date
    var treeDigest: String? = nil
}

nonisolated struct OverviewFinding: Codable, Identifiable, Sendable {
    var id: String { path }
    let path: String
    let cachedBytes: Int64
    let isDirectory: Bool
    let evidence: [OwnershipEvidence]
    /// retain / unknown / review: never an authorization to delete.
    let disposition: String
    let reason: String
    let fingerprint: FileFingerprint?
}

nonisolated struct OverviewAnalysis: Codable, Sendable {
    let schemaVersion: Int
    let overviewID: String
    let analyzedAt: Date
    let recordCount: Int
    let unknownCount: Int
    let reviewCount: Int
    let retainedCount: Int
    let warnings: [String]
}

nonisolated struct OverviewArtifact: Identifiable, Sendable {
    let id: String
    let directory: URL
    let manifest: OverviewManifest
    var analysis: OverviewAnalysis?
    var preview: [OverviewFinding] = []
    var cliExecutablePath: String? = nil
}

nonisolated struct OverviewAudit: Codable, Sendable {
    let overviewID: String
    let path: String
    let checkedAt: Date
    let outcome: String
    let message: String
    let trashPath: String?
}

nonisolated enum OverviewError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
