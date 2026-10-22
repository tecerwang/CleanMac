import SwiftUI
import AppKit

/// 卸载器：应用列表 + 相关数据勾选卸载。
struct UninstallerView: View {
    @ObservedObject var model: ScannerViewModel
    @State private var searchText = ""
    @State private var confirmUninstall = false

    private var filteredApps: [AppEntry] {
        guard !searchText.isEmpty else { return model.apps }
        return model.apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText) ||
            $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedRelatedSize: Int64 {
        model.relatedItems
            .filter { model.checkedRelatedIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    var body: some View {
        HSplitView {
            appList
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 480)
            detailPane
                .frame(minWidth: 480)
        }
        .navigationTitle("卸载器")
        .task {
            if model.apps.isEmpty && !model.isScanning {
                model.scanUninstaller()
            }
        }
        .onChange(of: model.selectedAppID) { _, newValue in
            model.loadRelatedData(for: newValue)
        }
        .confirmationDialog("确认卸载", isPresented: $confirmUninstall) {
            Button("移入废纸篓（应用 + \(model.relatedItems.filter { model.checkedRelatedIDs.contains($0.id) }.count) 项数据）", role: .destructive) {
                model.uninstallSelectedApp()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("应用及其勾选的数据会被移入废纸篓，需要时可以恢复。")
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TextField("搜索名称、Bundle ID 或路径", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
                Button {
                    model.scanUninstaller()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新读取应用")
                .disabled(model.isScanning)
            }
            .padding(14)
            Divider()
            if model.apps.isEmpty {
                ContentUnavailableView("尚未读取应用", systemImage: "app.badge.checkmark", description: Text("点击刷新按钮读取已安装应用。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApps.isEmpty {
                ContentUnavailableView("没有匹配的应用", systemImage: "magnifyingglass", description: Text("换个关键词试试，或清除搜索条件。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredApps, selection: $model.selectedAppID) { app in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(app.name).fontWeight(.medium).lineLimit(1)
                            if app.isSystemApp {
                                Text("系统").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.orange.opacity(0.2), in: Capsule())
                            }
                            Spacer()
                            Text(app.sizeText).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(app.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .tag(app.id)
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let app = model.selectedApp {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.title2.bold())
                            if !app.version.isEmpty {
                                Text("版本 \(app.version)").foregroundStyle(.secondary)
                            }
                            Text(app.bundleIdentifier.isEmpty ? "无 Bundle Identifier" : app.bundleIdentifier)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(app.sizeText).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(app.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(20)
                .background(.blue.opacity(0.06))
                Divider()

                if app.isSystemApp {
                    VStack {
                        Spacer()
                        Label("这是 macOS 自带的系统应用，卸载可能影响系统稳定。", systemImage: "lock.shield")
                            .foregroundStyle(.orange)
                            .padding(24)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("应用本体（必选）")
                                Spacer()
                                Text(app.sizeText).foregroundStyle(.secondary)
                            }
                            ForEach(model.relatedItems) { item in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: Binding(
                                        get: { model.checkedRelatedIDs.contains(item.id) },
                                        set: { model.setRelatedChecked(item, $0) }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .accessibilityLabel(item.name)
                                    .accessibilityHint("勾选后随应用一起移入废纸篓")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).lineLimit(1)
                                        Text(item.displayPath)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(item.sizeText).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                                .contextMenu {
                                    Button("在 Finder 中显示") {
                                        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                                    }
                                }
                            }
                            if model.relatedItems.isEmpty {
                                Text("未发现与该应用相关的数据目录。")
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("相关数据（\(model.relatedItems.count) 项）")
                        }
                    }
                    .listStyle(.inset)

                    HStack(spacing: 14) {
                        Label("将移除应用 + \(CleanMacFormat.bytes(selectedRelatedSize)) 相关数据", systemImage: "trash")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Button {
                            confirmUninstall = true
                        } label: {
                            Label("卸载所选", systemImage: "trash")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(model.isScanning || model.isCleaning)
                    }
                    .padding(16)
                    .background(.bar)
                }
            }
        } else {
            ContentUnavailableView("选择要卸载的应用", systemImage: "hand.tap", description: Text("在左侧列表中选择一个应用，查看它的占用大小与相关数据。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
