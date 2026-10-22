import Foundation

/// 路径缩写/展开与隐藏判断的统一实现（零依赖模块）。
/// 消除 Engine/ViewModel 中多处重复的 displayPath / expandPath / 隐藏判断逻辑。
nonisolated enum CleanMacPath {
    /// 把绝对路径缩写为 ~ 开头的显示路径。
    static func display(_ path: String, home: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// 把可能以 ~ 开头的路径展开为绝对路径。
    static func expand(_ path: String, home: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return home + path.dropFirst()
    }

    /// 判断路径是否为隐藏项（优先文件属性，回退名称前缀）。
    static func isHidden(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if let hidden = try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden {
            return hidden
        }
        return url.lastPathComponent.hasPrefix(".")
    }
}
