import Foundation

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case home, chat, models, compare, library, performance, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .chat: "Chat"
        case .models: "Models"
        case .compare: "Compare"
        case .library: "Library"
        case .performance: "Performance"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "circle.hexagongrid"
        case .chat: "bubble.left.and.text.bubble.right"
        case .models: "cube.transparent"
        case .compare: "rectangle.split.2x1"
        case .library: "books.vertical"
        case .performance: "gauge.with.dots.needle.67percent"
        case .settings: "gearshape"
        }
    }
}

enum SidebarSelection: Hashable {
    case section(SidebarSection)
    case conversation(UUID)
}
