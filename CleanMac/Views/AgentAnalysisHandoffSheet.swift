import SwiftUI
import AppKit

struct AgentAnalysisHandoffSheet: View {
    let handoff: AgentAnalysisHandoff
    let dismiss: () -> Void
    let retry: () -> Void
    @State private var text: String
    @State private var copyStatus = ""

    init(handoff: AgentAnalysisHandoff, dismiss: @escaping () -> Void, retry: @escaping () -> Void) {
        self.handoff = handoff
        self.dismiss = dismiss
        self.retry = retry
        _text = State(initialValue: handoff.prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(handoff.errorMessage == nil ? "刷新完成，复制给 Agent 分析" : "刷新完成，临时概述生成失败",
                  systemImage: handoff.errorMessage == nil ? "doc.on.clipboard" : "exclamationmark.triangle")
                .font(.title2.bold())
            if let error = handoff.errorMessage {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                Text("最新扫描记录已保留。可重试生成概述，成功后再复制真实文件位置。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("文本包含本次临时概述的完整路径、Skill 入口及分析要求。可编辑后复制，粘贴到能读取本机文件的 Agent 对话框。")
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                    .accessibilityLabel("Agent 分析文本")
                    .onChange(of: text) { _, _ in copyStatus = "" }
                Text(copyStatus.isEmpty ? "仅生成清理建议；文本不会授权 Agent 删除文件或停止服务。" : copyStatus)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let directory = handoff.artifactDirectory {
                    Button("打开临时概述目录", systemImage: "folder") { NSWorkspace.shared.open(directory) }
                }
                Spacer()
                Button("关闭", action: dismiss).keyboardShortcut(.cancelAction)
                if handoff.errorMessage != nil {
                    Button("重试生成", action: retry).buttonStyle(.borderedProminent)
                } else {
                    Button(copyStatus == "已复制到系统剪贴板" ? "已复制" : "复制到剪贴板", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        copyStatus = NSPasteboard.general.setString(text, forType: .string)
                            ? "已复制到系统剪贴板" : "复制失败，请选择文本后手动复制。"
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
            }
        }
        .padding(24)
        .frame(width: 760, height: handoff.errorMessage == nil ? 600 : 260)
    }
}
