import Foundation

enum CloudMenuModifier: String, Codable, CaseIterable, Identifiable {
    case shift, option, command, control
    var id: Self { self }
    var title: String {
        switch self {
        case .shift: return "Shift"
        case .option: return "Option"
        case .command: return "Command"
        case .control: return "Control"
        }
    }
}

struct CloudMenuSettings: Codable {
    var modifierRightClick = false
    var modifier: CloudMenuModifier = .shift
    var middleClick = false

    static func isCloudFolder(_ url: URL, home: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").pathComponents
        let providers = home.appendingPathComponent("Library/CloudStorage").pathComponents
        return parts.starts(with: iCloud) || (parts.starts(with: providers) && parts.count > providers.count &&
            parts[providers.count].hasPrefix("OneDrive"))
    }
}
