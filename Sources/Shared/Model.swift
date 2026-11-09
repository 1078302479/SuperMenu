import Foundation

enum FinderAction: String, Codable, CaseIterable, Identifiable {
    case newText, copyPath, openTerminal

    var id: Self { self }
    var title: String {
        switch self {
        case .newText: return "新建文件"
        case .copyPath: return "拷贝路径"
        case .openTerminal: return "在终端打开"
        }
    }
    var symbol: String {
        switch self {
        case .newText: return "doc.badge.plus"
        case .copyPath: return "link"
        case .openTerminal: return "terminal"
        }
    }
}

struct FolderAccess: Codable, Identifiable {
    let path: String
    let bookmark: Data
    var id: String { path }
}

struct Settings: Codable {
    var folders: [FolderAccess] = []
    var enabled: Set<FinderAction> = Set(FinderAction.allCases)
    // Older settings files omit this field. An explicitly empty set hides all templates.
    var enabledTemplates: Set<DocumentTemplate>?

    var visibleTemplates: [DocumentTemplate] {
        DocumentTemplate.allCases.filter { enabledTemplates?.contains($0) ?? true }
    }
}

struct FinderRequest: Codable {
    let action: FinderAction
    let paths: [String]
    let created: Date
    var template: DocumentTemplate?
}

enum SuperMenuError: LocalizedError {
    case sharedStorage, chooseFolder, staleBookmark, invalidTarget, terminalUnavailable, noFileName, clipboard, templateDisabled

    var errorDescription: String? {
        switch self {
        case .sharedStorage: return "无法访问主应用与 Finder 扩展的共享空间。请检查测试包的签名和系统授权。"
        case .chooseFolder: return "请先在 SuperMenu 中添加此目录。"
        case .staleBookmark: return "目录授权已过期，请重新添加该目录。"
        case .invalidTarget: return "目标不存在，或已移出授权目录。"
        case .terminalUnavailable: return "找不到系统终端。"
        case .noFileName: return "可用文件名已用尽。"
        case .clipboard: return "无法写入剪贴板。"
        case .templateDisabled: return "此文件模板已关闭。"
        }
    }
}

enum SharedStore {
    static var scheme: String {
        #if SUPER_MENU_LOCAL_BUILD
        if let scheme = Bundle.main.object(forInfoDictionaryKey: "SuperMenuLocalScheme") as? String {
            return scheme
        }
        #endif
        return "supermenu-local"
    }
    static let settingsChanged = Notification.Name("io.github.1078302479.SuperMenu.settingsChanged")

    static func directory() throws -> URL {
        #if SUPER_MENU_LOCAL_BUILD
        if let path = Bundle.main.object(forInfoDictionaryKey: "SuperMenuLocalStorage") as? String {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        guard let group = Bundle.main.object(forInfoDictionaryKey: "SuperMenuAppGroup") as? String,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw SuperMenuError.sharedStorage
        }
        return root
    }

    static func load() throws -> Settings {
        let url = try directory().appendingPathComponent("settings.json")
        do {
            return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Settings()
        }
    }

    static func save(_ settings: Settings) throws {
        let root = try directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
        DistributedNotificationCenter.default().post(name: settingsChanged, object: nil)
    }

    static func enqueue(_ request: FinderRequest) throws -> URL {
        let folder = try requestsDirectory()
        let id = UUID()
        try JSONEncoder().encode(request).write(to: folder.appendingPathComponent(id.uuidString), options: .atomic)
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "action"
        parts.path = "/" + id.uuidString
        guard let url = parts.url else { throw SuperMenuError.invalidTarget }
        return url
    }

    static func consume(_ url: URL) throws -> FinderRequest? {
        guard url.scheme == scheme, url.host == "action", url.pathComponents.count == 2,
              let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        let folder = try requestsDirectory()
        let source = folder.appendingPathComponent(id.uuidString)
        let claimed = folder.appendingPathComponent(id.uuidString + ".claimed")
        // Rename before reading so a repeated URL cannot execute the same request.
        do {
            try FileManager.default.moveItem(at: source, to: claimed)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: claimed) }
        let request = try JSONDecoder().decode(FinderRequest.self, from: Data(contentsOf: claimed))
        let age = Date().timeIntervalSince(request.created)
        return (0...120).contains(age) ? request : nil
    }

    private static func requestsDirectory() throws -> URL {
        let folder = try directory().appendingPathComponent("Requests", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
