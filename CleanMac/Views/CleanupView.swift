import SwiftUI
import AppKit

/// 智能清理：垃圾分类勾选、清理所选、清空废纸篓。
struct CleanupView: View {
    @ObservedObject var model: ScannerViewModel
    @State private var confirmCleanup = false
    @State private var confirmEmptyTrash = false

    private var visibleCategories: [JunkCategory] {
        model.cleanupCategories.filter { !$0.items.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if visibleCategories.isEmpty {
                ContentUnavailableView("尚未扫描垃圾文件", systemImage: "sparkles", description: Text("点击页面上方的“重新扫描”按钮开始只读分析。"))
            } else {
                List {
                    ForEach(visibleCategories) { category in
                        CategorySection(
                            category: category,
                            isFullyChecked: model.isCategoryFullyChecked(category),
                            isChecked: { model.checkedJunkIDs.contains($0.id) },
                            toggleItem: { model.setJunkChecked($0, $1) },
                            toggleCategory: { model.setCategoryChecked(category, $0) }
                        )
                    }
                }
                .listStyle(.inset)

                footerBar
            }
        }
        .navigationTitle("智能清理")
        .task {
            if model.cleanupCategories.isEmpty && !model.isScanning {
                model.scanCleanup()
            }
        }
        .confirmationDialog("确认移入废纸篓", isPresented: $confirmCleanup) {
            Button("移入废纸篓（\(model.selectedJunkItems.count) 项，\(CleanMacFormat.bytes(model.selectedJunkSize))）", role: .destructive) {
                model.runCleanup()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些内容会进入废纸篓，需要时可以从废纸篓恢复。部分正在使用的缓存可能无法移动，将在结果中列出。")
        }
        .confirmationDialog("确认清空废纸篓", isPresented: $confirmEmptyTrash) {
            Button("永久删除 \(CleanMacFormat.bytes(model.trashSize))", role: .destructive) {
                model.emptyTrash()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会永久删除废纸篓中的全部内容，无法恢复。请确认废纸篓中没有重要文件。")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("智能清理").font(.title.bold())
                Text("扫描系统缓存、浏览器缓存、日志、开发垃圾与废纸篓。清理操作会把内容移入废纸篓，误删也能找回；清空废纸篓才是永久删除。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新扫描", systemImage: "arrow.clockwise") {
                model.scanCleanup()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isScanning || model.isCleaning)
        }
        .padding(24)
    }

    private var footerBar: some View {
        HStack(spacing: 14) {
            Button("全选") { model.selectAllJunk() }
                .buttonStyle(.link)
                .controlSize(.small)
            Button("清空") { model.deselectAllJunk() }
                .buttonStyle(.link)
                .controlSize(.small)
            Divider().frame(height: 14)
            Label("已选 \(model.selectedJunkItems.count) 项 · 可释放 \(CleanMacFormat.bytes(model.selectedJunkSize))", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if model.trashSize > 0 {
                Button {
                    confirmEmptyTrash = true
                } label: {
                    Label("清空废纸篓（\(CleanMacFormat.bytes(model.trashSize))）", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(model.isScanning || model.isCleaning)
            }
            Button {
                confirmCleanup = true
            } label: {
                Label("清理所选", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(model.selectedJunkItems.isEmpty || model.isScanning || model.isCleaning)
        }
        .padding(16)
        .background(.bar)
    }
}

struct CategorySection: View {
    let category: JunkCategory
    let isFullyChecked: Bool
    let isChecked: (JunkItem) -> Bool
    let toggleItem: (JunkItem, Bool) -> Void
    let toggleCategory: (Bool) -> Void

    var body: some View {
        Section {
            ForEach(category.items) { item in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { isChecked(item) },
                        set: { toggleItem(item, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(item.permanentDeleteOnly)
                    .accessibilityLabel(item.name)
                    .accessibilityHint("勾选后包含在本次清理")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).fontWeight(.medium).lineLimit(1)
                        Text(item.displayPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Text(item.sizeText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .contextMenu {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                    }
                    Button("复制路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.path, forType: .string)
                    }
                }
            }
        } header: {
            HStack {
                Toggle("", isOn: Binding(
                    get: { isFullyChecked },
                    set: { toggleCategory($0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(category.items.allSatisfy(\.permanentDeleteOnly))
                .accessibilityLabel("选择\(category.name)")
                Label {
                    Text(category.name)
                } icon: {
                    Image(systemName: category.icon).foregroundStyle(.blue)
                }
                Spacer()
                Text(category.totalSizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(category.detail).font(.caption).foregroundStyle(.tertiary)
        }
    }
}
