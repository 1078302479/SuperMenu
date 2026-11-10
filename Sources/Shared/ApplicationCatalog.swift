import Foundation

struct ApplicationEntry: Codable, Identifiable {
    let id: String
    var name: String
    var bundleIdentifier: String?
    var bookmark: Data?
    var displayName: String?
    var enabled = true
    var alternateBundleIdentifiers: [String]?

    var title: String {
        let custom = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? name : custom
    }

    var menuTitle: String {
        let custom = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? "进入 " + name : custom
    }

    var bundleID: String { bundleIdentifier ?? id }
    var isCustom: Bool { bookmark != nil }
    var isTerminal: Bool { bundleID == "com.apple.Terminal" || bundleID == "com.googlecode.iterm2" }
    var menuTag: Int {
        var hash: UInt64 = 14695981039346656037
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Int(hash % UInt64(Int32.max - 1)) + 1
    }
}

enum TerminalOpenMode: String, Codable, CaseIterable, Identifiable {
    case systemDefault, newWindow, newTab

    var id: Self { self }
    var title: String {
        switch self {
        case .systemDefault: return "应用默认方式"
        case .newWindow: return "新窗口"
        case .newTab: return "新标签页"
        }
    }
}

enum ApplicationCatalog {
    static let entries: [ApplicationEntry] = [
        entry("com.apple.Terminal", "终端"),
        entry("com.googlecode.iterm2", "iTerm2"),
        entry("com.microsoft.VSCode", "Visual Studio Code"),
        entry("com.microsoft.VSCodeInsiders", "VS Code Insiders"),
        entry("com.sublimetext.4", "Sublime Text", alternatives: ["com.sublimetext.3"]),
        entry("com.sublimemerge", "Sublime Merge"),
        entry("dev.warp.Warp-Stable", "Warp"),
        entry("com.github.marktext", "MarkText"),
        entry("md.obsidian", "Obsidian"),
        entry("org.tabby", "Tabby"),
        entry("com.microsoft.visual-studio", "Visual Studio"),
        entry("co.zeit.hyper", "Hyper"),
        entry("org.gnu.Emacs", "Emacs"),
        entry("com.jetbrains.CLion", "CLion"),
        entry("com.coteditor.CotEditor", "CotEditor"),
        entry("com.dcloud.HBuilderX", "HBuilderX"),
        entry("com.jetbrains.PhpStorm", "PhpStorm"),
        entry("com.jetbrains.pycharm", "PyCharm", alternatives: ["com.jetbrains.pycharm.ce"]),
        entry("abnerworks.Typora", "Typora"),
        entry("com.jetbrains.WebStorm", "WebStorm"),
        entry("com.jetbrains.intellij", "IntelliJ IDEA", alternatives: ["com.jetbrains.intellij.ce"]),
        entry("com.google.android.studio", "Android Studio"),
        entry("com.jetbrains.AppCode", "AppCode"),
        entry("com.jetbrains.datagrip", "DataGrip"),
        entry("com.jetbrains.goland", "GoLand"),
        entry("com.jetbrains.rider", "Rider"),
        entry("com.jetbrains.rubymine", "RubyMine"),
    ]

    private static func entry(_ id: String, _ name: String, alternatives: [String]? = nil) -> ApplicationEntry {
        ApplicationEntry(id: id, name: name, alternateBundleIdentifiers: alternatives)
    }
}

enum ExternalToolKind: String, Codable, CaseIterable, Identifiable {
    case iShot, fastZip, diskMap

    var id: Self { self }
    var title: String {
        switch self {
        case .iShot: return "iShot"
        case .fastZip: return "FastZip"
        case .diskMap: return "DiskMap"
        }
    }

    var downloadURL: URL {
        let page: String
        switch self {
        case .iShot: page = "ishot"
        case .fastZip: page = "fastzip"
        case .diskMap: page = "diskmap"
        }
        return URL(string: "https://www.aodo365.com/" + page + ".html")!
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .iShot: return ["cn.better365.ishot", "cn.better365.iShotPro"]
        case .fastZip: return ["cn.better365.FastZip"]
        case .diskMap: return []
        }
    }

    var applicationNames: [String] {
        switch self {
        case .iShot: return ["iShot", "iShot Pro", "iShotPro"]
        case .fastZip: return ["FastZip"]
        case .diskMap: return ["DiskMap"]
        }
    }

    var capabilityDescription: String {
        switch self {
        case .iShot: return "打开 iShot，截图、贴图和标注操作在 iShot 内完成。"
        case .fastZip: return "将所选项目交给 FastZip 打开，压缩和解压操作在 FastZip 内完成。"
        case .diskMap: return "打开 DiskMap，扫描目录在 DiskMap 内选择。"
        }
    }
}
