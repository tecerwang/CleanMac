import SwiftUI

/// 应用内导航路由（纯 UI 层概念，模型层不感知）。
nonisolated enum ScanSection: Hashable, Sendable {
    case overview
    case cleanup
    case uninstaller
    case files
    case folders
    case residues
    case libraries
    case reports
    case filesystem(String)
}

/// SF Symbol 图标映射（UI 层职责，避免模型层依赖 SwiftUI）。
nonisolated extension LibrarySource {
    var icon: String {
        switch self {
        case .npm: return "shippingbox"
        case .python: return "terminal"
        case .homebrew: return "mug"
        case .cocoapods: return "cylinder.split.1x2"
        case .rubyGems: return "diamond"
        case .cargo: return "hammer"
        case .go: return "arrow.triangle.2.circlepath"
        case .maven: return "building.columns"
        case .gradle: return "gearshape.2"
        case .nuget: return "shippingbox.fill"
        case .composer: return "music.note.list"
        case .dart: return "circle.hexagongrid"
        case .swiftPM: return "swift"
        case .carthage: return "shippingbox.and.arrow.backward"
        case .conan: return "cube.transparent"
        case .vcpkg: return "wrench.and.screwdriver"
        case .bazel: return "scope"
        }
    }
}
