import SwiftUI
import AppKit

/// 侧边栏文件系统行（展开/刷新/跳转）。
struct FileSystemRow: View {
    let entry: DirectoryEntry
    let isExpanded: Bool
    let refresh: () -> Void

    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: toggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .frame(width: 15, height: 20)
            }
            .buttonStyle(.plain)
            Image(systemName: entry.path == "/" ? "internaldrive.fill" : "folder.fill")
                .foregroundStyle(.orange)
            if entry.isHidden {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Text(entry.name)
                .lineLimit(1)
                .foregroundStyle(entry.isHidden ? .secondary : .primary)
            Spacer(minLength: 4)
            Text(entry.sizeText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("刷新此目录及其子目录")
        }
        .padding(.vertical, 2)
    }
}

/// 文件系统目录详情：列出子目录大小（含隐藏目录）。
struct DirectoryDetailView: View {
    let path: String
    let children: [DirectoryEntry]
    let totalSize: Int64?
    let warning: String?
    let refresh: () -> Void
    let openDirectory: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(path == "/" ? "文件系统根目录" : path == FileManager.default.homeDirectoryForCurrentUser.path ? "用户主目录" : URL(fileURLWithPath: path).lastPathComponent)
                        .font(.title.bold())
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let totalSize {
                        Label("已统计占用 \(CleanMacFormat.bytes(totalSize))", systemImage: "internaldrive")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.top, 2)
                    }
                }
                Spacer()
                if path != "/" {
                    Button("上一级", systemImage: "arrow.up") {
                        openDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                    }
                }
                Button(totalSize == nil ? "扫描此目录" : "刷新此目录", systemImage: "arrow.clockwise", action: refresh)
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            Divider()
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding()
            }
            if children.isEmpty {
                ContentUnavailableView(totalSize == nil ? "此目录暂无缓存" : "目录为空或无法读取", systemImage: "folder", description: Text(totalSize == nil ? "点击“扫描此目录”生成记录，之后可随时浏览缓存。" : "当前扫描记录没有可显示的内容。"))
            } else {
                List(children) { child in
                    HStack {
                        Image(systemName: child.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(child.isDirectory ? .orange : .blue)
                        if child.isHidden {
                            Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        Text(child.name)
                            .foregroundStyle(child.isHidden ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(child.sizeText).font(.system(.body, design: .monospaced)).monospacedDigit()
                        if child.isDirectory {
                            Button { openDirectory(child.path) } label: {
                                Image(systemName: "chevron.right")
                            }
                            .buttonStyle(.borderless)
                            .help("查看目录内容")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if child.isDirectory { openDirectory(child.path) }
                    }
                    .help(child.path)
                    .contextMenu {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.selectFile(child.path, inFileViewerRootedAtPath: "")
                        }
                        Button("复制路径") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(child.path, forType: .string)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("文件系统")
    }
}
