import Foundation

enum ImageFormat: String, Codable, CaseIterable, Identifiable {
    case png, jpg, webp, heic, icns, macOS, iOS
    var id: Self { self }
    var title: String {
        switch self {
        case .macOS: return "macOS 图标集"
        case .iOS: return "iOS 图标集"
        default: return rawValue.uppercased()
        }
    }
    var outputExtension: String {
        switch self {
        case .macOS: return "iconset"
        case .iOS: return "ios-iconset"
        default: return rawValue
        }
    }
}

enum ImageBackground: String, Codable, CaseIterable, Identifiable {
    case white, black
    var id: Self { self }
    var title: String { self == .white ? "白色" : "黑色" }
}
