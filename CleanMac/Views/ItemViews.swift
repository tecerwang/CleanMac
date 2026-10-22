import SwiftUI
import AppKit

/// 通用列表视图（大文件 / 大型目录 / 应用残留）。
struct ItemListView: View {
    let title: String
    let subtitle: String
    let items: [DiskItem]
    @ObservedObject var model: ScannerViewModel
    @State private var searchText = ""

    private var filteredItems: [DiskItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { item in
            item.name.localizedCaseInsensitiveContains(searchText) ||
            item.path.localizedCaseInsensitiveContains(searchText) ||
            item.source.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title.bold())
                    Text(subtitle).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("搜索名称、路径或来源", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
            }
            .padding(24)
            Divider()

            if filteredItems.isEmpty {
                ContentUnavailableView("没有发现项目", systemImage: "checkmark.circle", description: Text("扫描结果中没有匹配项。"))
            } else {
                List(filteredItems) { item in
                    ItemRow(item: item, model: model)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(title)
    }
}

/// 磁盘条目行（含移到废纸篓操作）。
struct ItemRow: View {
    let item: DiskItem
    @ObservedObject var model: ScannerViewModel
    @State private var confirmTrash = false
    @State private var trashResult: CleanupReport?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.kind == .file ? "doc.fill" : "folder.fill")
                .foregroundStyle(item.kind == .file ? .blue : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isHidden {
                        Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(item.sizeText)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                Text(item.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(item.source).font(.caption).foregroundStyle(item.isResidue ? .pink : .secondary)
                    if item.isResidue { Text("疑似残留").font(.caption).foregroundStyle(.pink) }
                }
                if !item.evidence.isEmpty {
                    Text(item.evidence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(item.evidence)
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(item.absolutePath, inFileViewerRootedAtPath: "") }
            Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.absolutePath, forType: .string) }
            Divider()
            Button("移入废纸篓…", role: .destructive) { confirmTrash = true }
        }
        .confirmationDialog("确认移到废纸篓", isPresented: $confirmTrash) {
            Button("移入废纸篓（\(item.sizeText)）", role: .destructive) {
                model.trashSingleItem(item.absolutePath) { report in
                    trashResult = report
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(item.name)\n\n内容会进入废纸篓，需要时可以恢复。")
        }
        .alert("操作完成", isPresented: Binding(
            get: { trashResult != nil },
            set: { if !$0 { trashResult = nil } }
        )) {
            Button("好", role: .cancel) { trashResult = nil }
        } message: {
            if let report = trashResult {
                Text(report.failedCount == 0 ? "已移入废纸篓，释放 \(report.freedText)。" : "部分项目移动失败：\(report.errors.first ?? "未知错误")")
            }
        }
    }
}
