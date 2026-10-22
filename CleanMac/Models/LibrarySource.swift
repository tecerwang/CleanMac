import Foundation

/// 开发库生态（纯数据枚举；SF Symbol 图标映射位于 Views 层扩展，
/// 避免模型层依赖 SwiftUI）。
nonisolated enum LibrarySource: String, CaseIterable, Identifiable, Sendable {
    case npm = "npm"
    case python = "Python"
    case homebrew = "Homebrew"
    case cocoapods = "CocoaPods"
    case rubyGems = "RubyGems"
    case cargo = "Rust Cargo"
    case go = "Go Modules"
    case maven = "Maven"
    case gradle = "Gradle"
    case nuget = "NuGet"
    case composer = "Composer"
    case dart = "Dart / Pub"
    case swiftPM = "Swift Package Manager"
    case carthage = "Carthage"
    case conan = "Conan"
    case vcpkg = "vcpkg"
    case bazel = "Bazel"

    var id: String { rawValue }
}
