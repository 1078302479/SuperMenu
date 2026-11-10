import AppKit
import FinderSync
import os
import UniformTypeIdentifiers

final class FinderSync: FIFinderSync {
    private let log = Logger(subsystem: "io.github.1078302479.SuperMenu", category: "Finder")
    private var observation: NSObjectProtocol?
    private var volumeObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshFolders()
            })
        }
        refreshFolders()
        observation = DistributedNotificationCenter.default().addObserver(
            forName: SharedStore.settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshFolders() }
    }

    deinit {
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let observation { DistributedNotificationCenter.default().removeObserver(observation) }
    }

    private func refreshFolders() {
        do {
            let settings = try SharedStore.load()
            FIFinderSyncController.default().directoryURLs = FileAccessPolicy.monitoredDirectories(settings: settings)
        } catch {
            FIFinderSyncController.default().directoryURLs = []
            log.error("无法读取共享配置：\(error.localizedDescription, privacy: .public)")
        }
    }

    override var toolbarItemName: String { "增强右键" }
    override var toolbarItemToolTip: String { "使用增强右键新建文件" }
    override var toolbarItemImage: NSImage {
        let image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "新建文件") ?? NSImage()
        image.isTemplate = true
        return image
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard let settings = try? SharedStore.load() else { return nil }
        let controller = FIFinderSyncController.default()
        if FileAccessPolicy.usesDirectAccess {
            let urls = menuKind == .contextualMenuForItems ? (controller.selectedItemURLs() ?? []) : [controller.targetedURL()].compactMap { $0 }
            guard urls.allSatisfy({ FileAccessPolicy.allows($0, settings: settings) }) else { return nil }
        }
        let menu = NSMenu(title: "增强右键")
        switch menuKind {
        case .toolbarItemMenu:
            return Self.toolbarMenu(settings: settings, target: self)
        case .contextualMenuForContainer, .contextualMenuForSidebar:
            guard controller.targetedURL() != nil else { return nil }
            Self.addTemplates(to: menu, settings: settings, target: self)
            if let batch = try? CutState.load() {
                let pending = batch.isPending()
                if pending, settings.isEnabled(.pasteCut) {
                    addCutCommand(.pasteCut, selector: #selector(pasteCutItems(_:)), batchID: batch.id, to: menu)
                }
                if pending || batch.needsVisibilityRecovery {
                    addCutCommand(.cancelCut, selector: #selector(cancelCutItems(_:)), batchID: batch.id,
                                  title: pending ? nil : "恢复剪切项目", to: menu)
                }
            }
            add(.copyName, selector: #selector(copyFolderName), to: menu, settings: settings)
            add(.copyPath, selector: #selector(copyFolderPath), to: menu, settings: settings)
            add(.openTerminal, selector: #selector(openFolderInTerminal), to: menu, settings: settings)
            add(.addFavorite, selector: #selector(addTargetToFavorites), to: menu, settings: settings)
            add(.showHiddenFiles, selector: #selector(toolboxForFolder(_:)), to: menu, settings: settings)
            add(.hideHiddenFiles, selector: #selector(toolboxForFolder(_:)), to: menu, settings: settings)
            addWorkflowItems(to: menu, settings: settings, background: true)
            addApplications(to: menu, settings: settings)
            addFavorites(to: menu, settings: settings)
        case .contextualMenuForItems:
            let selected = controller.selectedItemURLs() ?? []
            guard !selected.isEmpty else { return nil }
            if let folder = controller.targetedURL(), FileAccessPolicy.allows(folder, settings: settings) {
                Self.addTemplates(to: menu, settings: settings, target: self)
            }
            if selected.allSatisfy({ UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) {
                addImageFormats(to: menu, settings: settings)
                if selected.count == 1 { add(.setWallpaper, selector: #selector(toolboxForSelection(_:)), to: menu, settings: settings) }
            }
            if selected.allSatisfy({ !$0.hasDirectoryPath && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }) {
                addChecksums(to: menu, settings: settings)
            }
            for action: FinderAction in [.desktopAlias, .airDrop, .hideSelected, .showSelected,
                                         .toggleExtension, .repairNames, .deletePermanently] {
                add(action, selector: #selector(toolboxForSelection(_:)), to: menu, settings: settings)
            }
            add(.cut, selector: #selector(cutSelectedItems), to: menu, settings: settings)
            addTransferMenu(.moveToFolder, selector: #selector(moveToFolder(_:)),
                            recentSelector: #selector(moveToRecent(_:)), otherSelector: #selector(moveToOther),
                            to: menu, settings: settings)
            addTransferMenu(.copyToFolder, selector: #selector(copyToFolder(_:)),
                            recentSelector: #selector(copyToRecent(_:)), otherSelector: #selector(copyToOther),
                            to: menu, settings: settings)
            add(.copyName, selector: #selector(copySelectedNames), to: menu, settings: settings)
            add(.copyPath, selector: #selector(copySelectedPaths), to: menu, settings: settings)
            if selected.count == 1, let item = selected.first {
                if item.hasDirectoryPath || (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    add(.addFavorite, selector: #selector(addSelectionToFavorites), to: menu, settings: settings)
                }
                if !item.hasDirectoryPath,
                   (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != false {
                    add(.folderFromName, selector: #selector(createFolderFromFileName), to: menu, settings: settings)
                }
                add(.openTerminal, selector: #selector(openSelectionInTerminal), to: menu, settings: settings)
            }
            addFavorites(to: menu, settings: settings)
            addWorkflowItems(to: menu, settings: settings, background: false)
            addApplications(to: menu, settings: settings)
        default:
            return nil
        }
        let selected = controller.selectedItemURLs() ?? []
        let scenes: Set<MenuScene>
        if menuKind == .contextualMenuForItems {
            scenes = Set(selected.map {
                if $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .folders }
                return UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true ? .images : .files
            })
        } else { scenes = [.background] }
        Self.customize(menu, settings: settings, scenes: scenes, count: scenes == [.background] ? 1 : selected.count)
        return menu.items.isEmpty ? nil : menu
    }

    private func add(_ action: FinderAction, selector: Selector, to menu: NSMenu, settings: Settings) {
        guard settings.isEnabled(action) else { return }
        let item = NSMenuItem(title: action.title, action: selector, keyEquivalent: "")
        item.target = self
        item.tag = FinderAction.allCases.firstIndex(of: action) ?? 0
        item.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        item.image = MenuIcons.action(action, size: 16)
            ?? NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    private func addCutCommand(_ action: FinderAction, selector: Selector, batchID: Int,
                               title: String? = nil, to menu: NSMenu) {
        let item = NSMenuItem(title: title ?? action.title, action: selector, keyEquivalent: "")
        item.target = self
        item.tag = batchID
        item.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    private func addWorkflowItems(to menu: NSMenu, settings: Settings, background: Bool) {
        let actions: [FinderAction] = background ? [.iShotCapture, .diskMap] :
            [.grantWrite, .compressZIP, .compress7z, .extractArchive, .iShotAnnotate, .diskMap, .openFastZip]
        for action in actions {
            if action == .extractArchive,
               !selection.allSatisfy({ ["zip","7z","tar","gz","tgz","bz2","xz","rar"].contains($0.pathExtension.lowercased()) }) {
                continue
            }
            add(action, selector: background ? #selector(toolboxForFolder(_:)) : #selector(toolboxForSelection(_:)),
                to: menu, settings: settings)
        }
        if !background, selection.count == 1, let folder = selection.first,
           folder.hasDirectoryPath || (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            add(.dissolveFolder, selector: #selector(toolboxForSelection(_:)), to: menu, settings: settings)
        }
    }

    private func addApplications(to menu: NSMenu, settings: Settings) {
        let submenu = NSMenu(title: settings.menuName(.openWithApp))
        let entries = settings.applications ?? ApplicationCatalog.entries
        for entry in entries where entry.enabled && entry.bundleID != "com.apple.Terminal" {
            if entry.isTerminal && selection.count > 1 { continue }
            let ids = [entry.bundleID] + (entry.alternateBundleIdentifiers ?? [])
            guard entry.isCustom || ids.contains(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) else { continue }
            guard entries.filter({ $0.menuTag == entry.menuTag }).count == 1 else { continue }
            let item = NSMenuItem(title: entry.menuTitle, action: #selector(openInApplication(_:)), keyEquivalent: "")
            item.target = self
            item.tag = entry.menuTag
            item.image = MenuIcons.application(entry, size: 16) ?? NSImage(systemSymbolName: entry.isTerminal ? "terminal" : "app", accessibilityDescription: nil)
            submenu.addItem(item)
        }
        if !submenu.items.isEmpty { attach(submenu, action: .openWithApp, to: menu) }
    }

    static func customize(_ menu: NSMenu, settings: Settings, scenes: Set<MenuScene>, count: Int) {
        let order = Dictionary(uniqueKeysWithValues: settings.orderedActions.enumerated().map { ($0.element, $0.offset) })
        let tagged = menu.items.enumerated().compactMap { index, item -> (Int, NSMenuItem, FinderAction?)? in
            let action = item.identifier.flatMap { FinderAction(rawValue: $0.rawValue) }
            if let action, !settings.allows(action, scenes: scenes, count: count) { return nil }
            let recovery = action == .cancelCut && item.title == "恢复剪切项目" && settings.menuRules?[.cancelCut]?.name == nil
            if let action, !(action == .newText && item.submenu == nil), !recovery {
                item.title = settings.menuName(action)
            }
            return (index, item, action)
        }.sorted { lhs, rhs in
            let a = lhs.2.flatMap { order[$0] } ?? Int.max
            let b = rhs.2.flatMap { order[$0] } ?? Int.max
            return a == b ? lhs.0 < rhs.0 : a < b
        }
        menu.removeAllItems()
        var groups: [MenuGroup: NSMenu] = [:]
        for (_, item, action) in tagged {
            if let action, action != .setWallpaper,
               settings.mergedMenuGroups?.contains(settings.menuGroup(action)) == true {
                let group = settings.menuGroup(action)
                let submenu: NSMenu
                if let existing = groups[group] { submenu = existing }
                else {
                    let title = (settings.interfaceLanguage ?? .system).usesEnglish ? InterfaceText.english(group.title) : group.title
                    submenu = NSMenu(title: title)
                    groups[group] = submenu
                    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    parent.submenu = submenu
                    menu.addItem(parent)
                }
                if (action == .openWithApp || action == .convertImage), let nested = item.submenu {
                    let children = nested.items
                    nested.removeAllItems()
                    for child in children { submenu.addItem(child) }
                } else { submenu.addItem(item) }
            } else if (action == .openWithApp || action == .convertImage), let nested = item.submenu {
                let children = nested.items
                nested.removeAllItems()
                for child in children { menu.addItem(child) }
            } else { menu.addItem(item) }
        }
        if settings.showMenuIcons == false { removeIcons(menu, preservingTransferMenus: true) }
    }

    private static func removeIcons(_ menu: NSMenu, preservingTransferMenus: Bool = false) {
        for item in menu.items {
            if preservingTransferMenus,
               [FinderAction.copyToFolder.rawValue, FinderAction.moveToFolder.rawValue, FinderAction.openFavorite.rawValue, FinderAction.newText.rawValue].contains(item.identifier?.rawValue ?? "") { continue }
            item.image = nil
            if let submenu = item.submenu { removeIcons(submenu, preservingTransferMenus: preservingTransferMenus) }
        }
    }

    private func addImageFormats(to menu: NSMenu, settings: Settings) {
        let formats = settings.orderedImageFormats.filter { settings.enabledImageFormats?.contains($0) ?? true }
        guard !formats.isEmpty else { return }
        let submenu = NSMenu(title: "图片转换")
        for format in formats {
            let item = NSMenuItem(title: settings.imageMenuName(format), action: #selector(convertSelectedImages(_:)), keyEquivalent: "")
            item.target = self
            item.tag = ImageFormat.allCases.firstIndex(of: format) ?? 0
            item.image = MenuIcons.action(.convertImage, size: 16)
            submenu.addItem(item)
        }
        attach(submenu, action: .convertImage, to: menu)
    }

    static func toolbarMenu(settings: Settings, target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: settings.menuName(.newText))
        addTemplates(to: menu, settings: settings, target: target, toolbar: true)
        if menu.items.isEmpty {
            let title = settings.isEnabled(.newText) ? "没有启用的文件模板" : "新建文件已关闭"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }

    static func addTemplates(to menu: NSMenu, settings: Settings, target: AnyObject, toolbar: Bool = false) {
        let templates = settings.visibleTemplates
        let custom = (settings.customTemplates?.entries ?? []).filter(\.enabled)
        guard settings.isEnabled(.newText) else { return }
        let submenu = toolbar ? menu : NSMenu(title: FinderAction.newText.title)
        if settings.allowsNamedCreation {
            let selector = toolbar ? #selector(createNamedFromToolbar) : #selector(createNamedDocument)
            let item = NSMenuItem(title: settings.namedCreationTitle, action: selector, keyEquivalent: "")
            item.target = target
            item.image = settings.showsTemplateIcons == false ? nil : MenuIcons.namedFile(size: 16)
            item.identifier = NSUserInterfaceItemIdentifier(FinderAction.newText.rawValue)
            if !toolbar && settings.promotesNamedCreation == true { menu.addItem(item) }
            else { submenu.addItem(item) }
        }
        for template in templates {
            let selector: Selector
            switch template {
            case .text: selector = #selector(createText)
            case .markdown: selector = #selector(createMarkdown)
            case .richText: selector = #selector(createRichText)
            case .xml: selector = #selector(createXML)
            default: selector = #selector(createBundledTemplate(_:))
            }
            let isPromoted = !toolbar && settings.promotedTemplates?.contains(template) == true
            let name = settings.templateTitle(template)
            let item = NSMenuItem(title: isPromoted && settings.templateDisplayNames?[template] == nil
                                  ? "新建 \(name) 文件" : name,
                                  action: toolbar ? #selector(createBundledFromToolbar(_:)) : selector, keyEquivalent: "")
            item.target = target
            item.tag = template.menuTag
            item.identifier = NSUserInterfaceItemIdentifier(FinderAction.newText.rawValue)
            item.image = settings.showsTemplateIcons == false ? nil : MenuIcons.document(extension: template.rawValue, size: 16)
            if isPromoted { menu.addItem(item) } else { submenu.addItem(item) }
        }
        if !submenu.items.isEmpty && custom.contains(where: { toolbar || $0.showsInMainMenu != true }) {
            submenu.addItem(.separator())
        }
        for template in custom {
            let selector = toolbar ? #selector(createCustomFromToolbar(_:)) : #selector(createCustomTemplate(_:))
            let item = NSMenuItem(title: template.title, action: selector, keyEquivalent: "")
            item.target = target
            item.tag = template.id
            item.image = settings.showsTemplateIcons == false ? nil : MenuIcons.document(extension: template.fileExtension, size: 16)
            if !toolbar && template.showsInMainMenu == true {
                item.identifier = NSUserInterfaceItemIdentifier(FinderAction.newText.rawValue)
                menu.addItem(item)
            } else {
                submenu.addItem(item)
            }
        }
        guard !toolbar, !submenu.items.isEmpty else { return }
        let parent = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        parent.image = settings.showsTemplateIcons == false ? nil : MenuIcons.newFile(size: 16)
        parent.submenu = submenu
        parent.identifier = NSUserInterfaceItemIdentifier(FinderAction.newText.rawValue)
        menu.addItem(parent)
    }

    private func addChecksums(to menu: NSMenu, settings: Settings) {
        guard settings.isEnabled(.fileInfo) else { return }
        let submenu = NSMenu(title: FinderAction.fileInfo.title)
        for (index, algorithm) in FileChecksum.allCases.enumerated() {
            let item = NSMenuItem(title: algorithm.rawValue, action: #selector(calculateChecksum(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            submenu.addItem(item)
        }
        attach(submenu, action: .fileInfo, to: menu)
        menu.items.last?.image = MenuIcons.action(.fileInfo, size: 16)
    }

    @objc private func calculateChecksum(_ sender: NSMenuItem) {
        let algorithms = FileChecksum.allCases
        let paths = selection.map(\.path)
        guard algorithms.indices.contains(sender.tag), !paths.isEmpty else { return }
        send(FinderRequest(action: .fileInfo, paths: paths, created: Date(), checksum: algorithms[sender.tag]))
    }

    private func addFavorites(to menu: NSMenu, settings: Settings) {
        guard settings.isEnabled(.openFavorite), !settings.availableFavorites.isEmpty else { return }
        let submenu = NSMenu(title: FinderAction.openFavorite.title)
        addFolderItems(settings.availableFavorites, selector: #selector(openFavorite(_:)), to: submenu)
        if settings.showsFavoriteIcons == false { Self.removeIcons(submenu) }
        attach(submenu, action: .openFavorite, to: menu)
        if settings.showsFavoriteIcons == false { menu.items.last?.image = nil }
    }

    private func addTransferMenu(_ action: FinderAction, selector: Selector, recentSelector: Selector,
                                 otherSelector: Selector, to menu: NSMenu, settings: Settings) {
        guard settings.isEnabled(action) else { return }
        let submenu = NSMenu(title: action.title)
        let presets = settings.availableCopyDestinations
        addFolderItems(presets, selector: selector, to: submenu)
        let recent = (settings.recentTransfers?.entries ?? []).map { SavedFolder(id: $0.id, path: $0.folder.path) }
        if !recent.isEmpty {
            let recentMenu = NSMenu(title: "最近目标")
            addFolderItems(recent, selector: recentSelector, to: recentMenu)
            let item = NSMenuItem(title: recentMenu.title, action: nil, keyEquivalent: "")
            item.submenu = recentMenu
            submenu.addItem(item)
        }
        if !submenu.items.isEmpty { submenu.addItem(.separator()) }
        let other = NSMenuItem(title: "自定义路径", action: otherSelector, keyEquivalent: "")
        other.target = self
        other.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        submenu.addItem(other)
        if settings.showsTransferIcons == false { Self.removeIcons(submenu) }
        attach(submenu, action: action, to: menu)
        if settings.showsTransferIcons == false { menu.items.last?.image = nil }
    }

    private func addFolderItems(_ folders: [SavedFolder], selector: Selector, to submenu: NSMenu) {
        let nameCounts = Dictionary(grouping: folders, by: \.name).mapValues(\.count)
        for folder in folders {
            let title = nameCounts[folder.name] == 1 ? folder.name : folder.path
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.tag = folder.id
            item.image = MenuIcons.folder(at: URL(fileURLWithPath: folder.path))
            submenu.addItem(item)
        }
    }

    private func attach(_ submenu: NSMenu, action: FinderAction, to menu: NSMenu) {
        let parent = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        parent.image = MenuIcons.action(action, size: 16)
            ?? NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        parent.submenu = submenu
        parent.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        menu.addItem(parent)
    }

    // Finder supplies the active context again when it dispatches an action.
    @objc private func createText() { perform(.newText, urls: targetedFolder, template: .text) }
    @objc private func createMarkdown() { perform(.newText, urls: targetedFolder, template: .markdown) }
    @objc private func createRichText() { perform(.newText, urls: targetedFolder, template: .richText) }
    @objc private func createXML() { perform(.newText, urls: targetedFolder, template: .xml) }
    @objc private func createNamedDocument() { perform(.newText, urls: targetedFolder, promptsForFileName: true) }
    @objc private func createBundledTemplate(_ sender: NSMenuItem) {
        guard let template = DocumentTemplate.allCases.first(where: { $0.menuTag == sender.tag }) else { return }
        perform(.newText, urls: targetedFolder, template: template)
    }
    @objc private func createCustomTemplate(_ sender: NSMenuItem) {
        guard sender.tag > 0 else { return }
        perform(.newText, urls: targetedFolder, customTemplateID: sender.tag)
    }

    @objc private func createNamedFromToolbar() {
        perform(.newText, urls: targetedFolder, promptsForFileName: true, fromToolbar: true)
    }

    @objc private func createBundledFromToolbar(_ sender: NSMenuItem) {
        guard let template = DocumentTemplate.allCases.first(where: { $0.menuTag == sender.tag }) else { return }
        perform(.newText, urls: targetedFolder, template: template, fromToolbar: true)
    }

    @objc private func createCustomFromToolbar(_ sender: NSMenuItem) {
        guard sender.tag > 0 else { return }
        perform(.newText, urls: targetedFolder, customTemplateID: sender.tag, fromToolbar: true)
    }
    @objc private func copyFolderPath() { perform(.copyPath, urls: targetedFolder) }
    @objc private func copyFolderName() { perform(.copyName, urls: targetedFolder) }
    @objc private func openFolderInTerminal() { perform(.openTerminal, urls: targetedFolder) }
    @objc private func copySelectedPaths() { perform(.copyPath, urls: selection) }
    @objc private func copySelectedNames() { perform(.copyName, urls: selection) }
    @objc private func cutSelectedItems() { perform(.cut, urls: selection) }
    @objc private func pasteCutItems(_ sender: NSMenuItem) {
        guard sender.tag > 0, let folder = targetedFolder.first else { return }
        send(FinderRequest(action: .pasteCut, paths: [folder.path], created: Date(), cutBatchID: sender.tag))
    }

    @objc private func cancelCutItems(_ sender: NSMenuItem) {
        guard sender.tag > 0 else { return }
        send(FinderRequest(action: .cancelCut, paths: [], created: Date(), cutBatchID: sender.tag))
    }

    @objc private func toolboxForSelection(_ sender: NSMenuItem) {
        guard FinderAction.allCases.indices.contains(sender.tag) else { return }
        perform(FinderAction.allCases[sender.tag], urls: selection)
    }

    @objc private func toolboxForFolder(_ sender: NSMenuItem) {
        guard FinderAction.allCases.indices.contains(sender.tag) else { return }
        perform(FinderAction.allCases[sender.tag], urls: targetedFolder)
    }

    @objc private func convertSelectedImages(_ sender: NSMenuItem) {
        guard ImageFormat.allCases.indices.contains(sender.tag), !selection.isEmpty else { return }
        send(FinderRequest(action: .convertImage, paths: selection.map(\.path), created: Date(),
                           imageFormat: ImageFormat.allCases[sender.tag]))
    }

    @objc private func openInApplication(_ sender: NSMenuItem) {
        guard let settings = try? SharedStore.load() else { return }
        let entries = settings.applications ?? ApplicationCatalog.entries
        let matching = entries.filter { $0.menuTag == sender.tag }
        guard matching.count == 1, let entry = matching.first else { return }
        let urls = selection.isEmpty ? targetedFolder : selection
        guard !urls.isEmpty else { return }
        send(FinderRequest(action: .openWithApp, paths: urls.map(\.path), created: Date(), applicationID: entry.id))
    }
    @objc private func createFolderFromFileName() { perform(.folderFromName, urls: selection) }
    @objc private func addTargetToFavorites() { perform(.addFavorite, urls: targetedFolder) }
    @objc private func addSelectionToFavorites() { perform(.addFavorite, urls: selection) }
    @objc private func openFavorite(_ sender: NSMenuItem) {
        guard sender.tag > 0 else { return }
        send(FinderRequest(action: .openFavorite, paths: [], created: Date(), favoriteFolderID: sender.tag))
    }
    @objc private func copyToFolder(_ sender: NSMenuItem) {
        sendTransfer(.copyToFolder, destinationID: sender.tag)
    }

    @objc private func moveToFolder(_ sender: NSMenuItem) {
        sendTransfer(.moveToFolder, destinationID: sender.tag)
    }

    @objc private func copyToRecent(_ sender: NSMenuItem) {
        sendTransfer(.copyToFolder, destinationID: sender.tag, target: .recent)
    }

    @objc private func moveToRecent(_ sender: NSMenuItem) {
        sendTransfer(.moveToFolder, destinationID: sender.tag, target: .recent)
    }

    @objc private func copyToOther() { sendTransfer(.copyToFolder, target: .other) }
    @objc private func moveToOther() { sendTransfer(.moveToFolder, target: .other) }

    private func sendTransfer(_ action: FinderAction, destinationID: Int? = nil, target: TransferTarget? = nil) {
        let paths = selection.map(\.path)
        guard !paths.isEmpty, target == .other || (destinationID ?? 0) > 0 else { return }
        send(FinderRequest(action: action, paths: paths, created: Date(), copyDestinationID: destinationID,
                           transferTarget: target))
    }
    @objc private func openSelectionInTerminal() {
        let urls = selection
        guard urls.count == 1 else { return }
        perform(.openTerminal, urls: urls)
    }

    private var targetedFolder: [URL] {
        FIFinderSyncController.default().targetedURL().map { [$0] } ?? []
    }

    private var selection: [URL] {
        FIFinderSyncController.default().selectedItemURLs() ?? []
    }

    private func perform(_ action: FinderAction, urls: [URL], template: DocumentTemplate? = nil,
                         customTemplateID: Int? = nil, promptsForFileName: Bool? = nil, fromToolbar: Bool? = nil) {
        guard !urls.isEmpty || fromToolbar == true else {
            log.error("Finder 未提供动作目标：\(action.rawValue, privacy: .public)")
            return
        }
        send(FinderRequest(action: action, paths: urls.map(\.path), created: Date(),
                           template: template, customTemplateID: customTemplateID,
                           promptsForFileName: promptsForFileName, fromToolbar: fromToolbar))
    }

    private func send(_ request: FinderRequest) {
        do {
            let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try FinderHandoff.send(request, to: app) { [log] error in
                if let error { log.error("无法打开增强右键：\(error.localizedDescription, privacy: .public)") }
            }
        } catch {
            log.error("无法发送 Finder 请求：\(error.localizedDescription, privacy: .public)")
        }
    }
}
