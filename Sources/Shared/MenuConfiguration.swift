import Foundation

enum MenuGroup: String, Codable, CaseIterable, Identifiable {
    case files, images, applications
    var id: Self { self }
    var title: String {
        switch self {
        case .files: return "文件操作"
        case .images: return "图片工具"
        case .applications: return "进入 App"
        }
    }
}

enum MenuScene: String, Codable, CaseIterable, Identifiable {
    case background, files, folders, images
    var id: Self { self }
    var title: String {
        switch self {
        case .background: return "空白处"
        case .files: return "文件"
        case .folders: return "文件夹"
        case .images: return "图片"
        }
    }
}

struct MenuRule: Codable {
    var name: String?
    var group: MenuGroup?
    var scenes: Set<MenuScene>?
    var requiresSingleSelection: Bool?
}

enum InterfaceLanguage: String, Codable, CaseIterable, Identifiable {
    case system, chinese, english
    var id: Self { self }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
    var usesEnglish: Bool {
        self == .english || (self == .system && Locale.preferredLanguages.first?.hasPrefix("en") == true)
    }
    var localeIdentifier: String { usesEnglish ? "en" : "zh-Hans" }
}

extension Settings {
    var orderedActions: [FinderAction] {
        var seen: Set<FinderAction> = []
        return ((actionOrder ?? []) + FinderAction.allCases).filter { seen.insert($0).inserted }
    }

    func menuName(_ action: FinderAction) -> String {
        let name = menuRules?[action]?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        if action == .openTerminal,
           let terminal = (applications ?? ApplicationCatalog.entries).first(where: { $0.bundleID == "com.apple.Terminal" }) {
            let custom = terminal.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !custom.isEmpty { return custom }
            if !(interfaceLanguage ?? .system).usesEnglish { return terminal.menuTitle }
        }
        return (interfaceLanguage ?? .system).usesEnglish ? action.englishTitle : action.title
    }

    func menuGroup(_ action: FinderAction) -> MenuGroup {
        if let group = menuRules?[action]?.group { return group }
        if [.convertImage, .setFileIcon, .restoreFileIcon, .setWallpaper].contains(action) { return .images }
        if [.openTerminal, .openWithApp].contains(action) { return .applications }
        return .files
    }

    func allows(_ action: FinderAction, scenes: Set<MenuScene>, count: Int) -> Bool {
        let rule = menuRules?[action]
        if rule?.requiresSingleSelection == true && count > 1 { return false }
        guard let allowed = rule?.scenes else { return true }
        return scenes.isSubset(of: allowed)
    }

    mutating func moveAction(_ action: FinderAction, by offset: Int) {
        var order = orderedActions
        guard let index = order.firstIndex(of: action), order.indices.contains(index + offset) else { return }
        order.insert(order.remove(at: index), at: index + offset)
        actionOrder = order
    }
}

struct PortablePreferences: Codable {
    let version: Int
    var settings: Settings

    init(_ original: Settings) {
        version = 1
        var settings = original
        // Machine-specific grants, paths and local-only resource references are excluded.
        settings.folders = []
        settings.customTemplates = nil
        settings.favorites = nil
        settings.copyDestinations = nil
        settings.recentTransfers = nil
        settings.desktopFolder = nil
        settings.applications = nil
        settings.disabledFolderPaths = nil
        settings.fileIconSelection = nil
        settings.fileIconOrder = nil
        settings.fileIconNames = nil
        settings.disabledFileIcons = nil
        self.settings = settings
    }

    func merging(into current: Settings) throws -> Settings {
        guard version == 1 else { throw SuperMenuError.invalidTarget }
        var clean = PortablePreferences(settings).settings
        clean.folders = current.folders
        clean.customTemplates = current.customTemplates
        clean.favorites = current.favorites
        clean.copyDestinations = current.copyDestinations
        clean.recentTransfers = current.recentTransfers
        clean.desktopFolder = current.desktopFolder
        clean.applications = current.applications
        clean.disabledFolderPaths = current.disabledFolderPaths
        clean.fileIconSelection = current.fileIconSelection
        clean.fileIconOrder = current.fileIconOrder
        clean.fileIconNames = current.fileIconNames
        clean.disabledFileIcons = current.disabledFileIcons
        clean.confirmsPermanentDelete = current.confirmsPermanentDelete
        return clean
    }
}
