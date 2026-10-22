import SwiftUI
import AppKit

struct OverviewReportView: View {
    @ObservedObject var scanner: ScannerViewModel
    @ObservedObject var model: OverviewReportViewModel
    @State private var lifetime: OverviewLifetime = .persistent
    @State private var pendingTrash: OverviewFinding?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.phase).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { model.cancel() }
                }.padding()
            }
            if let artifact = model.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summary(artifact)
                        if let analysis = artifact.analysis {
                            HStack(spacing: 20) {
                                Label("待复核 \(analysis.reviewCount)", systemImage: "checklist")
                                Label("未知归属 \(analysis.unknownCount)", systemImage: "questionmark.folder")
                                Label("保留 \(analysis.retainedCount)", systemImage: "lock.shield")
                            }.font(.callout)
                            Text("下方预览各类重点记录 \(artifact.preview.count) 条（最多 200 条）；全部分析记录保存在概述目录中。目录与子项大小重叠，不能直接求和。")
                                .font(.caption).foregroundStyle(.secondary)
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(artifact.preview) { finding in findingRow(finding) }
                            }
                        } else {
                            ContentUnavailableView("概述已就绪", systemImage: "doc.text.magnifyingglass",
                                description: Text("点击“分析此概述”生成归属证据，或打开概述目录交给 AI Agent 分析。"))
                        }
                    }.padding(24)
                }
            } else {
                ContentUnavailableView("生成可分析的文件概述", systemImage: "doc.text",
                    description: Text("基于上次扫描缓存，导出文件占用、应用清单、服务配置和进程使用证据。"))
            }
        }
        .navigationTitle("概述与归属分析")
        .alert("概述操作", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .confirmationDialog("确认复核并移入废纸篓", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("检查后移入废纸篓", role: .destructive) {
                if let finding = pendingTrash { model.trash(finding) }
                pendingTrash = nil
            }
            Button("取消", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("\(pendingTrash?.path ?? "")\n\n将重新检查文件标识与当前使用证据。建议不等于可安全删除，请先确认用途和可重建性。操作仅移入废纸篓并记录审计。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("概述与归属分析").font(.title.bold())
            Text("导出概述 → 分析证据 → 人工复核 → 移入废纸篓 → 验证与恢复")
                .foregroundStyle(.secondary)
            HStack {
                Picker("保存方式", selection: $lifetime) {
                    ForEach(OverviewLifetime.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 200)
                Button("生成概述", systemImage: "doc.badge.plus") { model.generate(cache: scanner.overviewCache(), lifetime: lifetime) }
                    .buttonStyle(.borderedProminent)
                Button("打开已有概述…", systemImage: "folder") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = "选择包含 manifest.json 和 entries.jsonl 的概述目录"
                    if panel.runModal() == .OK, let url = panel.url { model.open(url) }
                }
            }.disabled(model.isBusy || scanner.isScanning || scanner.isCleaning)
            if !model.artifacts.isEmpty {
                Picker("已有概述", selection: $model.selectedID) {
                    ForEach(model.artifacts) { artifact in
                        Text("\(artifact.manifest.createdAt.formatted()) · \(artifact.manifest.recordCount) 条 · \(artifact.manifest.lifetime)")
                            .tag(Optional(artifact.id))
                    }
                }.disabled(model.isBusy)
            }
        }.padding(24)
    }

    private func summary(_ artifact: OverviewArtifact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(artifact.manifest.recordCount.formatted()) 条记录", systemImage: "doc.text")
                Spacer()
                Button("打开概述目录", systemImage: "folder") { NSWorkspace.shared.open(artifact.directory) }
                Button("分析此概述", systemImage: "magnifyingglass") { model.analyze() }
                    .disabled(model.isBusy)
            }
            Text(artifact.directory.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("缓存时间：\(artifact.manifest.cacheSavedAt?.formatted() ?? "未知") · 进程观察：\(artifact.manifest.runtime.observedAt.formatted())")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("来源与覆盖限制（\(artifact.manifest.warnings.count)）") {
                ForEach(Array(artifact.manifest.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding().background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func findingRow(_ finding: OverviewFinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: finding.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(.orange)
                Text(URL(fileURLWithPath: finding.path).lastPathComponent).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(finding.disposition == "review" ? "待复核" : finding.disposition == "unknown" ? "未知归属" : "保留")
                    .foregroundStyle(finding.disposition == "review" ? Color.orange : Color.secondary)
                Text(CleanMacFormat.bytes(finding.cachedBytes)).monospacedDigit()
            }
            Text(finding.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(finding.reason).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, evidence in
                Text("\(evidence.owner) · \(evidence.confidence) · \(evidence.reason)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Finder 中显示") { NSWorkspace.shared.selectFile(finding.path, inFileViewerRootedAtPath: "") }
                if finding.disposition == "review", finding.fingerprint != nil {
                    Button("复核移除…", role: .destructive) { pendingTrash = finding }.disabled(model.isBusy)
                }
            }.controlSize(.small)
        }.padding().background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
