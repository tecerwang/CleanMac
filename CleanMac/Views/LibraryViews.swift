import SwiftUI

/// 开发库查询视图。
struct LibraryQueryView: View {
    @ObservedObject var model: ScannerViewModel
    @State private var source: LibrarySource = .npm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("开发库查询").font(.title.bold())
                }
                Spacer()
                Picker("库生态", selection: $source) {
                    ForEach(LibrarySource.allCases) { item in
                        Label(item.rawValue, systemImage: item.icon).tag(item)
                    }
                }
                .frame(width: 180)
                Button("查询", systemImage: "magnifyingglass") {
                    model.queryLibraries(source)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isScanning)
            }
            .padding(24)
            .background(.blue.opacity(0.06))
            Divider()

            if model.libraryItems.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView("尚未查询开发库", systemImage: "shippingbox", description: Text("选择一种开发生态后开始只读查询，包括隐藏目录（如 ~/.npm、~/.cargo）。"))
                    Button("开始查询", systemImage: "magnifyingglass") {
                        model.queryLibraries(source)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isScanning)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.libraryItems) { item in
                    ItemRow(item: item, model: model)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("开发库查询")
        .onAppear { source = model.librarySource }
        .onChange(of: source) { _, selected in model.showCachedLibraries(selected) }
    }
}
