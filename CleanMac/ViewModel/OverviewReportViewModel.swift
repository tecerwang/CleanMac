import Foundation
import Combine

@MainActor
final class OverviewReportViewModel: ObservableObject {
    @Published private(set) var artifacts: [OverviewArtifact] = []
    @Published var selectedID: String?
    @Published private(set) var isBusy = false
    @Published private(set) var phase = ""
    @Published private(set) var canCancel = false
    @Published var message: String?
    @Published var agentHandoff: AgentAnalysisHandoff?
    private var token: ScanToken?
    private var failedHandoffRequest: (PersistedScanCache, DiskRefreshCompletion)?

    var selected: OverviewArtifact? { artifacts.first { $0.id == selectedID } }

    init() {
        Task {
            let records = await Task.detached(priority: .utility) {
                let root = OverviewReportEngine.persistentRoot
                let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                return folders.compactMap { try? OverviewReportEngine().open($0) }.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
            }.value
            // Loading a catalog does not analyze it or overwrite a new export.
            for record in records where !artifacts.contains(where: { $0.id == record.id }) { artifacts.append(record) }
            if selectedID == nil { selectedID = artifacts.first?.id }
        }
    }

    func cancel() {
        guard isBusy, canCancel else { return }
        token?.cancel()
        phase = "正在取消，保留已有概述与扫描记录…"
        canCancel = false
    }

    private func applyPhase(_ phase: String, token currentToken: ScanToken) {
        guard isBusy, token === currentToken, !currentToken.isCancelled else { return }
        self.phase = phase
    }

    func dismissAgentHandoff() {
        agentHandoff = nil
        failedHandoffRequest = nil
    }

    func retryAgentHandoff() {
        guard let (cache, refresh) = failedHandoffRequest else { return }
        agentHandoff = nil
        failedHandoffRequest = nil
        generateRefreshHandoff(cache: cache, refresh: refresh)
    }

    func generateRefreshHandoff(cache: PersistedScanCache, refresh: DiskRefreshCompletion) {
        guard !isBusy else { return }
        isBusy = true
        canCancel = true
        phase = "刷新已完成，正在生成临时概述与 Agent 分析文本"
        let currentToken = ScanToken()
        token = currentToken
        Task {
            do {
                let artifact = try await Task.detached(priority: .userInitiated) {
                    let scoped = AgentAnalysisHandoffBuilder.scopedCache(cache, refresh: refresh)
                    return try OverviewReportEngine().generate(cache: scoped, lifetime: .temporary, refresh: refresh, token: currentToken) { phase in
                        Task { @MainActor in self.applyPhase(phase, token: currentToken) }
                    }
                }.value
                try currentToken.checkCancellation()
                artifacts.insert(artifact, at: 0)
                selectedID = artifact.id
                failedHandoffRequest = nil
                phase = "临时概述与 Agent 分析文本已就绪"
                isBusy = false
                canCancel = false
                agentHandoff = AgentAnalysisHandoff(artifactDirectory: artifact.directory,
                    prompt: AgentAnalysisHandoffBuilder.prompt(for: artifact, refresh: refresh))
            } catch is CancellationError {
                phase = "已取消生成 Agent 分析文本，扫描记录已保留"
                isBusy = false
                canCancel = false
            } catch {
                failedHandoffRequest = (cache, refresh)
                phase = "临时概述生成失败，扫描记录已保留"
                isBusy = false
                canCancel = false
                agentHandoff = AgentAnalysisHandoff(artifactDirectory: nil, prompt: "", errorMessage: error.localizedDescription)
            }
        }
    }

    func generate(cache: PersistedScanCache?, lifetime: OverviewLifetime) {
        guard !isBusy else { return }
        guard let cache else { message = "请先完成一次目录扫描，再生成概述。"; return }
        isBusy = true
        canCancel = true
        phase = "准备导出扫描缓存"
        let currentToken = ScanToken()
        token = currentToken
        Task {
            do {
                let artifact = try await Task.detached(priority: .userInitiated) {
                    try OverviewReportEngine().generate(cache: cache, lifetime: lifetime, token: currentToken) { phase in
                        Task { @MainActor in self.applyPhase(phase, token: currentToken) }
                    }
                }.value
                try currentToken.checkCancellation()
                artifacts.insert(artifact, at: 0)
                selectedID = artifact.id
                phase = "概述已生成"
            } catch is CancellationError { phase = "生成已取消" }
            catch { message = error.localizedDescription }
            isBusy = false
            canCancel = false
        }
    }

    func open(_ directory: URL) {
        guard !isBusy else { return }
        isBusy = true
        phase = "读取概述清单"
        Task {
            do {
                let artifact = try await Task.detached(priority: .utility) { try OverviewReportEngine().open(directory) }.value
                artifacts.removeAll { $0.id == artifact.id }
                artifacts.insert(artifact, at: 0)
                selectedID = artifact.id
            } catch { message = error.localizedDescription }
            isBusy = false
        }
    }

    func analyze() {
        guard !isBusy, let artifact = selected else { return }
        isBusy = true
        canCancel = true
        phase = "分析应用、服务和使用证据"
        let currentToken = ScanToken()
        token = currentToken
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try OverviewReportEngine().analyze(artifact, token: currentToken) { phase in
                        Task { @MainActor in self.applyPhase(phase, token: currentToken) }
                    }
                }.value
                try currentToken.checkCancellation()
                if let index = artifacts.firstIndex(where: { $0.id == result.id }) { artifacts[index] = result }
                phase = "归属分析完成"
            } catch is CancellationError { phase = "分析已取消，上次结果保留" }
            catch { message = error.localizedDescription }
            isBusy = false
            canCancel = false
        }
    }

    func trash(_ finding: OverviewFinding) {
        guard !isBusy, let artifact = selected else { return }
        isBusy = true
        phase = "重新检查当前使用情况与文件标识"
        Task {
            do {
                let audit = try await Task.detached(priority: .userInitiated) {
                    try OverviewReportEngine().trashReviewed(finding, artifact: artifact)
                }.value
                message = audit.message
                if let index = artifacts.firstIndex(where: { $0.id == artifact.id }) {
                    artifacts[index].preview.removeAll { UsageEvidenceCollector.contains(finding.path, $0.path) }
                }
                phase = "已移入废纸篓并记录审计"
            } catch { message = error.localizedDescription }
            isBusy = false
        }
    }
}
