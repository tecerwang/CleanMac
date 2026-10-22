import SwiftUI
import AppKit

/// 概览：磁盘容量、快速入口、分析摘要与权限提示。
struct OverviewView: View {
    @ObservedObject var model: ScannerViewModel
    let select: (ScanSection) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if !model.volumes.isEmpty {
                    volumeSection
                }

                if let result = model.result, result.hasPermissionErrors {
                    permissionBanner
                }

                quickActions

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    MetricCard(title: "最大文件", value: model.result?.largestFiles.first?.sizeText ?? "—", icon: "doc.fill", color: .blue) { select(.files) }
                    MetricCard(title: "最大目录", value: model.result?.largestFolders.first?.sizeText ?? "—", icon: "folder.fill", color: .orange) { select(.folders) }
                    MetricCard(title: "应用残留", value: "\(model.result?.residues.count ?? 0) 项", icon: "app.badge.checkmark", color: .pink) { select(.residues) }
                }

                if let result = model.result {
                    summarySection(result)

                    if result.cancelled {
                        Label("本次分析已被取消，结果可能不完整。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                    } else if result.scanLimitReached {
                        Label("已达到本次分析的安全上限，结果可能不完整。请缩小分析范围后再次运行。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                    }

                    DisclosureGroup {
                        Text("“应用残留”是基于证据的识别结果，不代表绝对证明：工具会检查路径中的 Bundle Identifier 是否仍有对应的 .app，并保留完整路径和判断依据。无法可靠匹配的项目不会直接归入残留。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Label("识别说明", systemImage: "shield.checkered")
                    }
                }
            }
            .padding(30)
        }
        .navigationTitle("概览")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("磁盘空间分析")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("识别大文件、大型目录、垃圾缓存与应用卸载后仍然驻留的数据。分析阶段均为只读，只有在你明确确认后才会把内容移入废纸篓。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(
            LinearGradient(
                colors: [.blue.opacity(0.22), .indigo.opacity(0.08), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22)
        )
    }

    private var volumeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.volumes) { volume in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: volume.path == "/" ? "internaldrive.fill" : "externaldrive.fill")
                                .foregroundStyle(.secondary)
                            Text(volume.name).fontWeight(.medium)
                            Spacer()
                            Text("已用 \(CleanMacFormat.bytes(volume.used)) / \(CleanMacFormat.bytes(volume.total))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: volume.usedFraction)
                            .progressViewStyle(.linear)
                            .tint(volume.usedFraction > 0.9 ? .red : volume.usedFraction > 0.75 ? .orange : .blue)
                        HStack {
                            Text("可用 \(CleanMacFormat.bytes(volume.free))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .padding(6)
        } label: {
            Label("磁盘容量", systemImage: "externaldrive")
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("部分目录无法读取").fontWeight(.semibold)
                Text("建议在 系统设置 → 隐私与安全性 → 完全磁盘访问权限 中允许 CleanMac，以便完整统计隐藏目录（如 ~/Library）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开系统设置") {
                let urls = [
                    "x-apple.systemsettings:com.apple.Privacy-Security.extension",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                ].compactMap(URL.init(string:))
                for url in urls where NSWorkspace.shared.open(url) {
                    break
                }
            }
        }
        .padding(14)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var quickActions: some View {
        HStack(spacing: 14) {
            QuickActionButton(title: "智能清理", subtitle: "缓存 · 日志 · 废纸篓", icon: "sparkles", color: .green) { select(.cleanup) }
            QuickActionButton(title: "大文件", subtitle: "找出占用最多的文件", icon: "doc.fill", color: .blue) { select(.files) }
            QuickActionButton(title: "卸载器", subtitle: "卸载应用并清理残留", icon: "trash.slash", color: .pink) { select(.uninstaller) }
        }
    }

    private func summarySection(_ result: ScanResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(title: "已分析条目", value: result.entryCount.formatted())
                InfoRow(title: "已识别应用", value: "\(result.installedApps.count) 个")
                InfoRow(title: "分析耗时", value: result.durationText)
                InfoRow(title: "无法读取", value: "\(result.errors.count) 项")
            }
        } label: {
            Label("分析摘要", systemImage: "info.circle")
        }
    }
}

struct QuickActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                Text(title).fontWeight(.semibold).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .padding(16)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                Text(title).foregroundStyle(.secondary)
                Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .padding(18)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.20)))
        }
        .buttonStyle(.plain)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }
}
