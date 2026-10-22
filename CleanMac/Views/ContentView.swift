import SwiftUI
import AppKit

/// 根视图：侧边栏导航 + 详情区域 + 全局扫描遮罩。
struct ContentView: View {
    @StateObject private var model = ScannerViewModel()
    @StateObject private var reports = OverviewReportViewModel()
    @State private var selection: ScanSection = .overview

    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
            .disabled(model.isScanning || model.isCleaning || reports.isBusy)

            if model.isScanning || model.isCleaning || reports.isBusy {
                BlockingOverlay(
                    title: reports.isBusy ? "正在处理概述" : model.isCleaning ? "正在清理" : "正在分析磁盘",
                    progress: reports.isBusy ? ScanProgress(phase: reports.phase, scannedEntries: 0, fraction: nil) : model.progress,
                    phase: reports.isBusy ? reports.phase : model.isCleaning ? model.cleaningPhase : model.progress.phase,
                    countLabel: model.isCleaning ? "已处理" : "已分析",
                    cancellable: reports.isBusy ? reports.canCancel : model.canCancelScan,
                    cancel: { if reports.isBusy { reports.cancel() } else { model.cancelScan() } }
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .frame(minWidth: 1_050, minHeight: 700)
        .onChange(of: model.completedDiskRefresh) { _, refresh in
            guard let refresh, let cache = model.overviewCache() else { return }
            reports.generateRefreshHandoff(cache: cache, refresh: refresh)
        }
        .sheet(item: Binding(
            get: { reports.agentHandoff },
            set: { value in if value == nil { reports.dismissAgentHandoff() } }
        )) { handoff in
            AgentAnalysisHandoffSheet(handoff: handoff,
                dismiss: { reports.dismissAgentHandoff() }, retry: { reports.retryAgentHandoff() })
        }
        .alert("清理结果", isPresented: Binding(
            get: { model.cleanupReport != nil },
            set: { if !$0 { model.dismissCleanupReport() } }
        )) {
            Button("好", role: .cancel) { model.dismissCleanupReport() }
        } message: {
            if let report = model.cleanupReport {
                Text(report.failedCount == 0
                     ? "已处理 \(report.movedCount) 项，释放 \(report.freedText)。"
                     : "已处理 \(report.movedCount) 项，释放 \(report.freedText)。\(report.failedCount) 项失败：\(report.errors.prefix(3).joined(separator: "；"))")
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("概览") {
                Label("分析概览", systemImage: "gauge.with.dots.needle.33percent")
                    .tag(ScanSection.overview)
            }

            Section("清理") {
                Label("智能清理", systemImage: "sparkles")
                    .badge(model.selectedJunkItems.count > 0 ? Text("\(model.selectedJunkItems.count)") : nil)
                    .tag(ScanSection.cleanup)
                Label("卸载器", systemImage: "trash.slash")
                    .badge(model.apps.count)
                    .tag(ScanSection.uninstaller)
            }

            Section("磁盘空间分析") {
                Label("大文件", systemImage: "doc.fill")
                    .badge(model.result?.largestFiles.count ?? 0)
                    .tag(ScanSection.files)
                Label("大型目录", systemImage: "folder.fill")
                    .badge(model.result?.largestFolders.count ?? 0)
                    .tag(ScanSection.folders)
                Label("应用残留", systemImage: "app.badge.checkmark")
                    .badge(model.result?.residues.count ?? 0)
                    .tag(ScanSection.residues)
            }

            Section("工具") {
                Label("概述与归属分析", systemImage: "doc.text.magnifyingglass")
                    .tag(ScanSection.reports)
                ForEach(model.filesystemRows) { entry in
                    FileSystemRow(entry: entry, isExpanded: model.isDirectoryExpanded(entry.path), refresh: {
                        model.refreshDirectory(entry.path)
                    }, toggle: {
                        model.toggleDirectory(entry.path)
                    })
                    .padding(.leading, CGFloat(entry.depth) * 14)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = .filesystem(entry.path)
                    }
                    .tag(ScanSection.filesystem(entry.path))
                }
                Label("开发库查询", systemImage: "shippingbox")
                    .tag(ScanSection.libraries)
            }

        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("空间管理中心")
                        .font(.headline)
                    if model.isScanning {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if let result = model.result {
                    Text("最近一次分析：\(result.generatedAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("准备开始一次只读分析")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !model.cacheStatus.isEmpty {
                    Text(model.cacheStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.scan()
            } label: {
                Label(model.isScanning ? "分析中…" : "全面分析", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isScanning)
            .help("扫描整个磁盘：大文件、大型目录与应用残留")
            .padding()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview:
            OverviewView(model: model, select: { selection = $0 })
        case .cleanup:
            CleanupView(model: model)
        case .uninstaller:
            UninstallerView(model: model)
        case .files:
            ItemListView(title: "大文件", subtitle: "按文件大小排序，显示完整路径与来源分类", items: model.result?.largestFiles ?? [], model: model)
        case .folders:
            ItemListView(title: "大型目录", subtitle: "目录大小包含所有可读取子目录的累计占用（含隐藏目录）", items: model.result?.largestFolders ?? [], model: model)
        case .residues:
            ItemListView(title: "应用残留", subtitle: "依据应用数据目录、Bundle Identifier 与已安装应用清单识别", items: model.result?.residues ?? [], model: model)
        case .libraries:
            LibraryQueryView(model: model)
        case .reports:
            OverviewReportView(scanner: model, model: reports)
        case .filesystem(let path):
            DirectoryDetailView(path: path, children: model.children(for: path), totalSize: model.directorySize(for: path), warning: model.directoryWarnings[path], refresh: { model.refreshDirectory(path) }, openDirectory: { selection = .filesystem($0) })
        }
    }
}

// MARK: - 扫描遮罩

struct BlockingOverlay: View {
    let title: String
    let progress: ScanProgress
    let phase: String
    let countLabel: String
    let cancellable: Bool
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    if progress.fraction == nil {
                        ProgressView()
                            .controlSize(.large)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                        Text(phase.isEmpty ? "请稍候…" : phase)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }

                HStack {
                    Text("\(countLabel) \(progress.scannedEntries.formatted()) 项")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    if cancellable {
                        Button("取消", action: cancel)
                    }
                }
            }
            .padding(28)
            .frame(width: 470)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，\(countLabel) \(progress.scannedEntries) 项")
    }
}
