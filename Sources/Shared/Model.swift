import Foundation
import Darwin

enum FinderAction: String, Codable, CaseIterable, Identifiable {
    case newText, copyPath, copyName, folderFromName, openTerminal, openFavorite, copyToFolder, moveToFolder
    case cut, pasteCut, cancelCut
    case addFavorite
    case fileInfo, hideSelected, showSelected, showHiddenFiles, hideHiddenFiles, toggleExtension
    case repairNames, desktopAlias, airDrop, deletePermanently
    case convertImage, setFileIcon, restoreFileIcon
    case openWithApp, dissolveFolder, setWallpaper, grantWrite, iShotCapture, iShotAnnotate
    case compressZIP, compress7z, extractArchive, diskMap
    case openFastZip

    var id: Self { self }
    var title: String {
        switch self {
        case .newText: return "新建文件"
        case .copyPath: return "拷贝路径"
        case .copyName: return "拷贝文件（夹）名称"
        case .folderFromName: return "使用文件名新建文件夹"
        case .openTerminal: return "在终端打开"
        case .openFavorite: return "常用目录"
        case .copyToFolder: return "复制文件到…"
        case .moveToFolder: return "移动文件到…"
        case .cut: return "剪切"
        case .pasteCut: return "粘贴"
        case .cancelCut: return "取消剪切"
        case .addFavorite: return "添加到常用目录"
        case .fileInfo: return "文件信息"
        case .hideSelected: return "隐藏已选文件"
        case .showSelected: return "取消隐藏已选文件"
        case .showHiddenFiles: return "取消隐藏所有文件"
        case .hideHiddenFiles: return "隐藏所有文件"
        case .toggleExtension: return "隐藏 / 显示文件扩展名"
        case .repairNames: return "修复乱码文件名"
        case .desktopAlias: return "发送快捷方式到桌面"
        case .airDrop: return "隔空投送"
        case .deletePermanently: return "彻底删除"
        case .convertImage: return "图片转换"
        case .setFileIcon: return "设置文件（夹）图标"
        case .restoreFileIcon: return "恢复原图标"
        case .openWithApp: return "进入 App"
        case .dissolveFolder: return "解散文件夹"
        case .setWallpaper: return "设置为墙纸"
        case .grantWrite: return "授予所选文件写入权限"
        case .iShotCapture: return "iShot 截图"
        case .iShotAnnotate: return "iShot 贴图、标注"
        case .compressZIP: return "压缩为 ZIP"
        case .compress7z: return "压缩为 7z"
        case .extractArchive: return "解压到当前文件夹"
        case .diskMap: return "扫描磁盘（DiskMap）"
        case .openFastZip: return "交给 FastZip 打开"
        }
    }
    var symbol: String {
        switch self {
        case .newText: return "doc.badge.plus"
        case .copyPath: return "link"
        case .copyName: return "doc.on.clipboard"
        case .folderFromName: return "folder.badge.plus"
        case .openTerminal: return "terminal"
        case .openFavorite: return "star"
        case .copyToFolder: return "doc.on.doc"
        case .moveToFolder: return "folder.badge.plus"
        case .cut: return "scissors"
        case .pasteCut: return "clipboard"
        case .cancelCut: return "arrow.uturn.backward"
        case .addFavorite: return "heart.badge.plus"
        case .fileInfo: return "info.circle"
        case .hideSelected, .hideHiddenFiles: return "eye.slash"
        case .showSelected, .showHiddenFiles: return "eye"
        case .toggleExtension: return "doc.text"
        case .repairNames: return "character.cursor.ibeam"
        case .desktopAlias: return "arrowshape.turn.up.right"
        case .airDrop: return "airplayaudio"
        case .deletePermanently: return "trash"
        case .convertImage: return "photo"
        case .setFileIcon: return "folder.badge.gearshape"
        case .restoreFileIcon: return "arrow.uturn.backward"
        case .openWithApp: return "app"
        case .dissolveFolder: return "folder.badge.minus"
        case .setWallpaper: return "desktopcomputer"
        case .grantWrite: return "lock.open"
        case .iShotCapture: return "camera.viewfinder"
        case .iShotAnnotate: return "pencil.tip.crop.circle"
        case .compressZIP, .compress7z: return "archivebox"
        case .extractArchive: return "archivebox.fill"
        case .diskMap: return "internaldrive"
        case .openFastZip: return "archivebox"
        }
    }
}

struct FolderAccess: Codable, Identifiable {
    let path: String
    let bookmark: Data
    var id: String { path }
}

struct Settings: Codable {
    var usageScope: UsageScope?
    var toolboxItemOrder: [String]?
    var toolboxDisplayNames: [String: String]?
    var enabledTextServices: Set<String>?
    var folders: [FolderAccess] = []
    var enabled: Set<FinderAction> = [.newText, .copyPath, .openTerminal]
    // Older settings files omit this field. An explicitly empty set hides all templates.
    var enabledTemplates: Set<DocumentTemplate>?
    var promotedTemplates: Set<DocumentTemplate>?
    var templateDisplayNames: [DocumentTemplate: String]?
    var templateOrder: [DocumentTemplate]?
    var showsNamedCreation: Bool?
    var namedCreationDisplayName: String?
    var promotesNamedCreation: Bool?
    var showsTemplateIcons: Bool?
    var opensNewDocuments: Bool?
    var playsCreationSound: Bool?
    var customTemplates: CustomTemplateLibrary?
    var favorites: SavedFolders?
    var showsFavoriteIcons: Bool?
    var copyDestinations: SavedFolders?
    var showsTransferIcons: Bool?
    var transferDestinationsVersion: Int?
    var showsMoveMenu: Bool?
    var showsCopyName: Bool?
    var showsFolderFromName: Bool?
    var showsCut: Bool?
    var hidesCutItems: Bool?
    var conflictPolicy: TransferConflictPolicy?
    var recentTransfers: RecentTransfers?
    var toolboxEnabled: Set<FinderAction>?
    var confirmsPermanentDelete: Bool?
    var desktopFolder: FolderAccess?
    var fileIconSelection: String?
    var showsFileIcons: Bool?
    var disabledFileIcons: Set<String>?
    var fileIconOrder: [String]?
    var fileIconNames: [String: String]?
    var enabledImageFormats: Set<ImageFormat>?
    var imageQuality: Double?
    var imageBackground: ImageBackground?
    var actionOrder: [FinderAction]?
    var menuRules: [FinderAction: MenuRule]?
    var mergedMenuGroups: Set<MenuGroup>?
    var showMenuIcons: Bool?
    var showsStatusItem: Bool?
    var launchesQuietly: Bool?
    var interfaceLanguage: InterfaceLanguage?
    var applications: [ApplicationEntry]?
    var terminalMode: TerminalOpenMode?
    var terminalModes: [String: TerminalOpenMode]?
    var workflowEnabled: Set<FinderAction>?
    var disabledFolderPaths: Set<String>?

    func isEnabled(_ action: FinderAction) -> Bool {
        switch action {
        case .openFavorite: return favorites?.showsMenu ?? true
        case .copyToFolder: return copyDestinations?.showsMenu ?? true
        case .moveToFolder: return showsMoveMenu ?? true
        case .copyName: return showsCopyName ?? true
        case .folderFromName: return showsFolderFromName ?? true
        case .cut, .pasteCut: return showsCut ?? true
        case .cancelCut: return true
        case .addFavorite: return isEnabled(.openFavorite)
        case .fileInfo, .hideSelected, .showSelected, .showHiddenFiles, .hideHiddenFiles, .toggleExtension,
             .repairNames, .desktopAlias, .airDrop:
            return toolboxEnabled?.contains(action) ?? true
        case .deletePermanently: return toolboxEnabled?.contains(action) ?? false
        case .setFileIcon, .restoreFileIcon: return true
        case .convertImage: return enabledImageFormats?.isEmpty != true
        case .openWithApp: return true
        case .dissolveFolder, .setWallpaper, .grantWrite, .iShotCapture, .iShotAnnotate,
             .compressZIP, .compress7z, .extractArchive, .diskMap, .openFastZip:
            return workflowEnabled?.contains(action) ?? false
        default: return enabled.contains(action)
        }
    }

    var orderedTemplates: [DocumentTemplate] {
        var seen: Set<DocumentTemplate> = []
        return ((templateOrder ?? []) + DocumentTemplate.allCases).filter { seen.insert($0).inserted }
    }

    var visibleTemplates: [DocumentTemplate] {
        orderedTemplates.filter { $0.isAvailable && (enabledTemplates?.contains($0) ?? true) }
    }

    var allowsNamedCreation: Bool { isEnabled(.newText) && (showsNamedCreation ?? true) }

    var namedCreationTitle: String {
        let name = namedCreationDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? NamedDocument.title : name
    }

    func templateTitle(_ template: DocumentTemplate) -> String {
        templateDisplayNames?[template] ?? template.title
    }

    mutating func resetTemplateSettings() {
        enabledTemplates = nil
        promotedTemplates = nil
        templateDisplayNames = nil
        templateOrder = nil
        showsNamedCreation = nil
        namedCreationDisplayName = nil
        promotesNamedCreation = nil
        showsTemplateIcons = nil
        opensNewDocuments = nil
        playsCreationSound = nil
        if var library = customTemplates {
            library.entries = library.entries.sorted { $0.id < $1.id }.map {
                CustomTemplate(id: $0.id, fileName: $0.fileName)
            }
            customTemplates = library
        }
    }

    mutating func renameTemplate(_ template: DocumentTemplate, to title: String) {
        var names = templateDisplayNames ?? [:]
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        names[template] = name.isEmpty || name == template.title ? nil : name
        templateDisplayNames = names.isEmpty ? nil : names
    }

    mutating func moveTemplate(_ template: DocumentTemplate, by offset: Int) {
        var order = orderedTemplates
        guard let index = order.firstIndex(of: template), order.indices.contains(index + offset) else { return }
        order.insert(order.remove(at: index), at: index + offset)
        templateOrder = order
    }

    mutating func moveTemplate(_ template: DocumentTemplate, to target: DocumentTemplate) {
        let order = orderedTemplates
        guard let source = order.firstIndex(of: template), let destination = order.firstIndex(of: target),
              source != destination else { return }
        moveTemplate(template, by: destination - source)
    }
}

enum FileChecksum: String, CaseIterable, Codable {
    case md5 = "MD5"
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

struct FinderRequest: Codable {
    let action: FinderAction
    let paths: [String]
    let created: Date
    var template: DocumentTemplate?
    var customTemplateID: Int?
    var favoriteFolderID: Int?
    var copyDestinationID: Int?
    var promptsForFileName: Bool?
    var fromToolbar: Bool?
    var cutBatchID: Int?
    var transferTarget: TransferTarget?
    var imageFormat: ImageFormat?
    var applicationID: String?
    var checksum: FileChecksum?
    var fileIconID: String?
    var removesCustomIcon: Bool?
}

enum SuperMenuError: LocalizedError {
    case sharedStorage, chooseFolder, staleBookmark, invalidTarget, terminalUnavailable, noFileName, clipboard, templateDisabled
    case favoriteUnavailable, folderOpenFailed, copyDestinationUnavailable, recursiveCopy, unsupportedCopySource
    case alreadyInDestination, templateResourceMissing, newDocumentOpenFailed, invalidFileName
    case crossVolumeVerificationFailed, crossVolumeSourceRetained(String), crossVolumeCleanupFailed(String, String)
    case replacementBackupKept(String)
    case folderSourceMustBeFile
    case folderNameConflict(String)
    case cutUnavailable, cutSourceChanged
    case cutStateUpdateFailed(Int)

    var errorDescription: String? {
        switch self {
        case .sharedStorage: return "无法访问主应用与 Finder 扩展的共享空间。请检查测试包的签名和系统授权。"
        case .chooseFolder: return "请先在增强右键中添加此目录。"
        case .staleBookmark: return "目录授权已过期，请重新添加该目录。"
        case .invalidTarget: return "目标不存在，或已移出授权目录。"
        case .terminalUnavailable: return "找不到系统终端。"
        case .noFileName: return "可用文件名已用尽。"
        case .clipboard: return "无法写入剪贴板。"
        case .templateDisabled: return "此文件模板已关闭。"
        case .favoriteUnavailable: return "这个常用目录无法打开。可在「常用目录」中重新添加。"
        case .folderOpenFailed: return "Finder 无法打开这个目录，请检查目录是否仍然存在。"
        case .copyDestinationUnavailable: return "目标目录已移除、已关闭或已取消授权。"
        case .recursiveCopy: return "不能将文件夹复制或移动到自身或它的子目录。"
        case .unsupportedCopySource: return "请选择普通文件或文件夹。"
        case .crossVolumeVerificationFailed: return "跨卷副本校验未通过。源项目仍在原处。"
        case .crossVolumeSourceRetained(let path): return "复制后源项目或目标发生了变化，源项目未删除。请核对：\(path)"
        case .crossVolumeCleanupFailed(let path, let reason): return "目标副本已校验，但源项目清理未完成。请核对：\(path)（\(reason)）"
        case .replacementBackupKept(let path): return "替换未完成。原目标已保存在：\(path)"
        case .alreadyInDestination: return "项目已经在目标目录中。"
        case .templateResourceMissing: return "此格式的模板文件缺失。"
        case .newDocumentOpenFailed: return "文件已创建，但无法用默认应用打开。"
        case .invalidFileName: return "请输入有效的文件名。文件名不能是「.」或「..」，不能包含斜线、冒号或控制字符，且不能超过 255 字节。"
        case .folderSourceMustBeFile: return "请选择一个普通文件，再使用文件名新建文件夹。"
        case .folderNameConflict(let name): return "当前目录中已存在名为「\(name)」的项目。"
        case .cutUnavailable: return "这批剪切项目已失效。请重新剪切，再打开粘贴菜单。"
        case .cutSourceChanged: return "原位置已换成另一个项目，已跳过。"
        case .cutStateUpdateFailed(let completed): return "已粘贴 \(completed) 项，但无法更新剪切记录。请先核对目标目录，再重新剪切剩余项目。"
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
        if let path = Bundle.main.object(forInfoDictionaryKey: "SuperMenuHomeRelativeStorage") as? String,
           let home = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
                .appendingPathComponent(String(path.dropFirst()), isDirectory: true)
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
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
