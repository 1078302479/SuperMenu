import AppKit
import ApplicationServices
import FinderSync
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings = Settings()
    @Published private(set) var storageAvailable = false
    @Published private(set) var extensionEnabled = false
    @Published private(set) var extensionPermission: Bool?
    @Published private(set) var protectedDirectoryPermission = ProtectedDirectoryPermission.unknown
    @Published private(set) var permissionsCheckedAt: Date?
    @Published private(set) var checkingPermissions = false
    @Published private(set) var permissionProbeAvailable = false
    @Published private(set) var accessibilityEnabled = false
    @Published private(set) var finderAutomationEnabled = false
    @Published var showsAuthorizationHelp = false
    @Published private(set) var cloudTriggerAvailable = false
    let cloudMenus = CloudMenuController()
    @Published var message = ""
    @Published var showsMessage = false
    @Published var page: SettingsPage? = .overview
    @Published var selectedToolboxID: String?
    @Published var selectedTransferID: Int?
    @Published var selectedFavoriteID: Int?
    @Published var toolboxSearch = ""
    private let cutTransfer = CutTransfer()
    private let toolbox = ToolboxController()
    private let imageTools = ImageToolsController()
    let integrations = IntegrationController()
    let updates = UpdateChecker()
    @Published var selectedFileIconID: String?
    @Published private(set) var importedIcons: [FileIconStore.Imported] = []
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginStatus = ""
    private var isNamingDocument = false
    private var isPickingCreationFolder = false

    init() {
        refresh()
        cloudMenus.onRequest = { [weak self] request in
            Task { @MainActor in
                do { try await self?.perform(request) }
                catch { self?.report(error) }
            }
        }
    }

    func setCloudMenu(_ change: (inout CloudMenuSettings) -> Void) {
        var preferences = settings.cloudMenu ?? CloudMenuSettings()
        change(&preferences)
        if (preferences.modifierRightClick || preferences.middleClick) && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        var next = settings
        next.cloudMenu = preferences
        save(next)
    }

    private func refreshCloudTriggers(snapshot: PermissionSnapshot? = nil) {
        if let snapshot {
            accessibilityEnabled = snapshot.accessibility
            finderAutomationEnabled = snapshot.automation
        }
        if !accessibilityEnabled || !finderAutomationEnabled {
            cloudMenus.stop()
        } else if snapshot == nil || !cloudMenus.available {
            cloudMenus.configure(settings)
        }
        cloudTriggerAvailable = cloudMenus.available
    }

    func requestFinderAutomation() {
        finderAutomationEnabled = FinderAutomation.requestPermission()
        if !finderAutomationEnabled {
            message = "未获得访达访问权限，请在系统设置的「隐私与安全 → 自动化」中允许增强右键控制访达。"
            showsMessage = true
        }
    }

    func openFinderAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func revealInstalledApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func refresh() {
        do {
            settings = try SharedStore.load()
            if FileAccessPolicy.usesDirectAccess, settings.transferDestinationsVersion == nil {
                settings.initializeTransferDestinations()
                try SharedStore.save(settings)
            }
            importedIcons = (try? FileIconStore.imported()) ?? []
            storageAvailable = true
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginStatus = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置中批准登录项。" : ""
        } catch {
            storageAvailable = false
        }
    }

    func refreshPermissions() async {
        guard !checkingPermissions else { return }
        if let last = permissionsCheckedAt, Date().timeIntervalSince(last) < 3 { return }
        checkingPermissions = true
        defer { checkingPermissions = false }
        async let snapshot = PermissionSnapshot.fresh()
        let enabled = await FinderExtensionPermission.isEnabled()
        let previous = extensionEnabled
        extensionPermission = enabled
        if let enabled { extensionEnabled = enabled }
        let latest = await snapshot
        protectedDirectoryPermission = latest.map {
            $0.protectedAccess == "accessible" ? .accessible : $0.protectedAccess == "denied" ? .denied : .unknown
        } ?? .unknown
        permissionsCheckedAt = Date()
        permissionProbeAvailable = latest != nil
        if let latest { refreshCloudTriggers(snapshot: latest) }
        else { cloudMenus.stop(); cloudTriggerAvailable = false }
        if previous != extensionEnabled {
            DistributedNotificationCenter.default().post(name: SharedStore.settingsChanged, object: nil)
        }
    }

    func openFinderExtensionSettings() { FIFinderSyncController.showExtensionManagementInterface() }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func addFolder(asFavorite: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = asFavorite ? "添加常用目录" : "添加发送目标目录"
        panel.prompt = "添加目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        do {
            // Keep the picker URL and its sandbox grant when creating the bookmark.
            let bookmark = try picked.bookmarkData(options: FileAccessPolicy.bookmarkCreationOptions, includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
            let path = picked.standardizedFileURL.path
            var next = settings
            next.folders.removeAll { $0.path == path }
            next.folders.append(FolderAccess(path: path, bookmark: bookmark))
            if asFavorite {
                var favorites = next.favorites ?? SavedFolders()
                favorites.add(path: path)
                next.favorites = favorites
            }
            save(next)
        } catch {
            report(error, context: "无法保存目录")
        }
    }

    func remove(_ folder: FolderAccess) {
        var next = settings
        next.folders.removeAll { $0.id == folder.id }
        next.copyDestinations?.remove(path: folder.path)
        next.recentTransfers?.remove(path: folder.path)
        save(next)
    }

    func setEnabled(_ action: FinderAction, _ enabled: Bool) {
        if action == .openFavorite {
            updateFavorites { $0.showsMenu = enabled }
            return
        }
        var next = settings
        if [.dissolveFolder, .setWallpaper, .grantWrite, .iShotCapture, .iShotAnnotate,
            .compressZIP, .compress7z, .extractArchive, .diskMap, .openFastZip].contains(action) {
            var selected = next.workflowEnabled ?? []
            if enabled { selected.insert(action) } else { selected.remove(action) }
            next.workflowEnabled = selected
            save(next)
            return
        }
        if action == .setFileIcon || action == .restoreFileIcon {
            next.showsFileIcons = enabled
            save(next)
            return
        }
        let toolboxActions: [FinderAction] = [.fileInfo, .hideSelected, .showSelected, .showHiddenFiles, .hideHiddenFiles,
                                             .toggleExtension, .repairNames, .desktopAlias, .airDrop, .deletePermanently]
        if toolboxActions.contains(action) {
            var selected = next.toolboxEnabled ?? Set(toolboxActions.filter { next.isEnabled($0) })
            if enabled { selected.insert(action) } else { selected.remove(action) }
            next.toolboxEnabled = selected
            save(next)
            return
        }
        if action == .copyToFolder {
            var destinations = next.copyDestinations ?? SavedFolders()
            destinations.showsMenu = enabled
            next.copyDestinations = destinations
        } else if action == .moveToFolder {
            next.showsMoveMenu = enabled
        } else if action == .copyName {
            next.showsCopyName = enabled
        } else if action == .folderFromName {
            next.showsFolderFromName = enabled
        } else if action == .cut {
            next.showsCut = enabled
        } else if enabled {
            next.enabled.insert(action)
        } else {
            next.enabled.remove(action)
        }
        save(next)
    }

    func setDeleteConfirmation(_ confirms: Bool) {
        if !confirms {
            let alert = NSAlert()
            alert.messageText = "关闭彻底删除确认？"
            alert.informativeText = "之后点击「彻底删除」会立即永久删除选中的项目。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "关闭确认").hasDestructiveAction = true
            alert.addButton(withTitle: "取消")
            guard alert.runLocalizedModal() == .alertFirstButtonReturn else { return }
        }
        var next = settings
        next.confirmsPermanentDelete = confirms
        save(next)
    }

    func resetDesktopFolder() {
        var next = settings
        next.desktopFolder = nil
        save(next)
    }

    var fileIconEntries: [FileIconEntry] {
        FileIconLibrary.orderedEntries(settings: settings, imported: importedIcons)
    }

    func importFileIcon() {
        let panel = NSOpenPanel()
        panel.title = "添加自定义图标"
        panel.prompt = "添加"
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        defer { source.stopAccessingSecurityScopedResource() }
        do {
            let entry = try FileIconStore.importImage(source)
            importedIcons = try FileIconStore.imported()
            selectedFileIconID = entry.id
        } catch { report(error, context: "无法导入图标") }
    }

    func changeFileIcons(restore: Bool) {
        let iconID = restore ? nil : selectedFileIconID
        guard restore || iconID != nil else { return }
        let panel = NSOpenPanel()
        panel.title = restore ? "选择要恢复图标的文件或文件夹" : "选择要应用图标的文件或文件夹"
        panel.prompt = restore ? "恢复原图标" : "应用图标"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            do {
                try await imageTools.setIcons(urls, restore: restore, settings: settings, iconID: iconID)
            } catch {
                report(error, context: restore ? "无法恢复原图标" : "无法应用图标")
            }
        }
    }

    func removeSelectedFileIcon() {
        guard let id = selectedFileIconID, importedIcons.contains(where: { $0.id == id }) else { return }
        do {
            try FileIconStore.removeImported(id)
            importedIcons = try FileIconStore.imported()
            selectedFileIconID = nil
            setSystemPreference {
                $0.fileIconOrder?.removeAll { $0 == id }
                $0.fileIconNames?.removeValue(forKey: id)
                $0.disabledFileIcons?.remove(id)
                if $0.fileIconSelection == id { $0.fileIconSelection = nil }
            }
        } catch { report(error, context: "无法移除图标") }
    }

    func resetFileIconLibrary() {
        setSystemPreference {
            $0.fileIconOrder = nil
            $0.fileIconNames = nil
            $0.disabledFileIcons = nil
            $0.showsFileIcons = true
        }
        selectedFileIconID = nil
    }

    func setFileIconsEnabled(_ ids: [String], enabled: Bool) {
        setSystemPreference {
            var disabled = $0.disabledFileIcons ?? []
            if enabled { disabled.subtract(ids) }
            else { disabled.formUnion(ids) }
            $0.disabledFileIcons = disabled
        }
    }

    func renameFileIcon(_ id: String, to name: String) {
        setSystemPreference {
            var names = $0.fileIconNames ?? [:]
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            names[id] = trimmed.isEmpty ? nil : trimmed
            $0.fileIconNames = names
        }
    }

    func moveFileIcon(_ source: String, to target: String) -> Bool {
        var ids = fileIconEntries.map(\.id)
        guard source != target, let from = ids.firstIndex(of: source), let to = ids.firstIndex(of: target) else { return false }
        ids.remove(at: from)
        ids.insert(source, at: to)
        setSystemPreference { $0.fileIconOrder = ids }
        selectedFileIconID = source
        return true
    }

    func setImageFormat(_ format: ImageFormat, enabled: Bool) {
        var next = settings
        var formats = next.enabledImageFormats ?? Set(ImageFormat.allCases)
        if enabled { formats.insert(format) } else { formats.remove(format) }
        next.enabledImageFormats = formats
        save(next)
    }

    func setImageQuality(_ quality: Double) {
        var next = settings
        next.imageQuality = quality
        save(next)
    }

    func setImageBackground(_ background: ImageBackground) {
        var next = settings
        next.imageBackground = background
        save(next)
    }

    func setSystemPreference(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        save(next)
    }

    func setLoginEnabled(_ enabled: Bool) {
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                if enabled { setSystemPreference { $0.launchesQuietly = true } }
                refresh()
            } catch { refresh(); report(error, context: "无法设置登录启动") }
        }
    }

    func exportPreferences() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "增强右键-preferences.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(PortablePreferences(settings)).write(to: url, options: .atomic)
        } catch { report(error, context: "无法导出配置") }
    }

    func importPreferences() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 2_000_000 else {
                throw ToolboxError.message("配置文件过大。")
            }
            let preference = try JSONDecoder().decode(PortablePreferences.self, from: Data(contentsOf: url))
            let alert = NSAlert()
            alert.messageText = "导入功能配置？"
            alert.informativeText = "将更新菜单及功能偏好，目录授权、本机应用和模板库将继续使用当前配置。"
            alert.addButton(withTitle: "导入")
            alert.addButton(withTitle: "取消")
            guard alert.runLocalizedModal() == .alertFirstButtonReturn else { return }
            save(try preference.merging(into: SharedStore.load()))
        } catch { report(error, context: "无法导入配置") }
    }

    func updateMenuRule(_ action: FinderAction, change: (inout MenuRule) -> Void) {
        var next = settings
        var rules = next.menuRules ?? [:]
        var rule = rules[action] ?? MenuRule()
        change(&rule)
        rules[action] = rule
        next.menuRules = rules
        save(next)
    }

    func renameAction(_ action: FinderAction) {
        let alert = NSAlert()
        alert.messageText = "编辑菜单名称"
        alert.informativeText = "留空可恢复默认名称。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = settings.menuRules?[action]?.name ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runLocalizedModal() == .alertFirstButtonReturn else { return }
        updateMenuRule(action) { $0.name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func moveAction(_ action: FinderAction, by offset: Int) {
        setSystemPreference { $0.moveAction(action, by: offset) }
    }

    func renameApplication(_ entry: ApplicationEntry, to name: String) {
        var entries = settings.applications ?? ApplicationCatalog.entries
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].displayName = name.isEmpty ? nil : name
        setSystemPreference {
            $0.applications = entries
            if entry.bundleID == "com.apple.Terminal" { $0.menuRules?[.openTerminal]?.name = nil }
        }
    }

    func resetToolbox() {
        let alert = NSAlert()
        alert.messageText = "重置工具箱？"
        alert.informativeText = "恢复工具箱名称、顺序、开关和菜单合并设置，并移除自定义进入 App。不会删除应用或文件。"
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        guard alert.runLocalizedModal() == .alertFirstButtonReturn else { return }
        setSystemPreference {
            $0.enabled.formUnion([.copyPath, .openTerminal])
            $0.toolboxEnabled = nil
            $0.workflowEnabled = nil
            $0.hidesCutItems = nil
            $0.confirmsPermanentDelete = nil
            $0.showsCopyName = nil
            $0.showsFolderFromName = nil
            $0.showsCut = nil
            $0.enabledImageFormats = nil
            $0.applications = nil
            $0.terminalModes = nil
            $0.terminalMode = nil
            $0.menuRules = nil
            $0.actionOrder = nil
            $0.toolboxItemOrder = nil
            $0.toolboxDisplayNames = nil
            $0.showMenuIcons = nil
            $0.mergedMenuGroups = nil
            $0.enabledTextServices = nil
        }
    }

    func showPermissionInstructions() {
        let alert = NSAlert()
        alert.messageText = "权限设置教学"
        alert.informativeText = "1. 在系统设置中启用增强右键的 Finder 扩展。\n2. 使用范围在通用设置中选择，普通目录无需逐个授权。\n3. 若受保护的位置无法访问，在「隐私与安全性 → 完全磁盘访问权限」中添加并启用当前的增强右键.app。\n4. 权限变更后退出并重新打开增强右键。"
        alert.addButton(withTitle: "好")
        alert.runLocalizedModal()
    }

    func showPermissionGuide() {
        let alert = NSAlert()
        alert.messageText = "权限设置引导"
        alert.informativeText = "菜单不显示时启用 Finder 扩展；受保护的位置无法访问时设置完全磁盘访问权限。"
        alert.addButton(withTitle: "完全磁盘访问权限")
        alert.addButton(withTitle: "Finder 扩展")
        alert.addButton(withTitle: "取消")
        switch alert.runLocalizedModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        case .alertSecondButtonReturn: FIFinderSyncController.showExtensionManagementInterface()
        default: break
        }
    }

    func setApplication(_ entry: ApplicationEntry, enabled: Bool) {
        var entries = settings.applications ?? ApplicationCatalog.entries
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].enabled = enabled
        setSystemPreference {
            $0.applications = entries
            if entry.bundleID == "com.apple.Terminal" {
                if enabled { $0.enabled.insert(.openTerminal) } else { $0.enabled.remove(.openTerminal) }
            }
        }
    }

    func removeApplication(_ entry: ApplicationEntry) {
        guard entry.isCustom else { return }
        var entries = settings.applications ?? ApplicationCatalog.entries
        entries.removeAll { $0.id == entry.id }
        setSystemPreference { $0.applications = entries }
    }

    func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.title = "选择应用"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { throw SuperMenuError.invalidTarget }
            let bookmark = try url.bookmarkData(options: FileAccessPolicy.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            var entries = settings.applications ?? ApplicationCatalog.entries
            if let index = entries.firstIndex(where: { $0.bundleID == bundleID }) {
                entries[index].bookmark = bookmark
                entries[index].enabled = true
            } else {
                entries.append(ApplicationEntry(id: "custom." + UUID().uuidString,
                                                name: url.deletingPathExtension().lastPathComponent,
                                                bundleIdentifier: bundleID, bookmark: bookmark))
            }
            setSystemPreference { $0.applications = entries }
        } catch { report(error, context: "无法添加应用") }
    }

    func openExternalTool(_ tool: ExternalToolKind) {
        Task {
            do { try await ApplicationLauncher.openTool(tool) }
            catch { report(error) }
        }
    }

    func setHidesCutItems(_ hides: Bool) {
        var next = settings
        next.hidesCutItems = hides
        save(next)
    }

    func cancelCurrentCut() {
        Task {
            do {
                if let batch = try CutState.load(), batch.isPending() || batch.needsVisibilityRecovery {
                    try await cutTransfer.cancel(batchID: batch.id)
                }
            } catch { report(error) }
        }
    }

    func recoverExpiredCut() {
        Task { [cutTransfer] in try? await cutTransfer.recoverExpired() }
    }

    func addTransferDestination() {
        let panel = NSOpenPanel()
        panel.title = "添加发送目标目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            var next = settings
            var collection = next.copyDestinations ?? SavedFolders()
            for url in panel.urls {
                defer { url.stopAccessingSecurityScopedResource() }
                let access = try makeFolderAccess(url)
                next.folders.removeAll { $0.path == access.path }
                next.folders.append(access)
                collection.add(path: access.path)
            }
            next.copyDestinations = collection
            next.transferDestinationsVersion = 1
            save(next)
        } catch { report(error, context: "无法添加发送目标") }
    }

    func removeTransferDestination() {
        guard let id = selectedTransferID, let folder = settings.copyDestinations?.entries.first(where: { $0.id == id }) else { return }
        setSystemPreference { $0.copyDestinations?.remove(path: folder.path) }
        selectedTransferID = nil
    }

    func resetTransferDestinations() {
        let alert = NSAlert()
        alert.messageText = "重置发送文件到？"
        alert.informativeText = "恢复下载、图片、音乐、影片、文稿五个默认目录及其名称和顺序。仅重置此页设置，不会删除文件。"
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        guard alert.runLocalizedModal() == .alertFirstButtonReturn else { return }
        setSystemPreference {
            var destinations = $0.copyDestinations ?? SavedFolders()
            destinations.resetTransferDestinations()
            destinations.showsMenu = true
            $0.copyDestinations = destinations
            $0.transferDestinationsVersion = 1
            $0.showsTransferIcons = true
            $0.showsMoveMenu = true
        }
        selectedTransferID = nil
    }

    func setCopyDestination(_ folder: FolderAccess, enabled: Bool) {
        var next = settings
        guard next.folders.contains(where: { $0.id == folder.id }) else { return }
        var destinations = next.copyDestinations ?? SavedFolders()
        if enabled { destinations.add(folder) } else { destinations.remove(path: folder.path) }
        next.copyDestinations = destinations
        save(next)
    }

    func setConflictPolicy(_ policy: TransferConflictPolicy) {
        var next = settings
        next.conflictPolicy = policy
        save(next)
    }

    func clearRecentTransfers() {
        var next = settings
        next.recentTransfers?.clear()
        save(next)
    }

    func addFavorite(_ folder: FolderAccess) {
        guard settings.folders.contains(where: { $0.id == folder.id }) else { return }
        updateFavorites { $0.add(folder) }
    }

    func removeFavorite(_ favorite: SavedFolder) {
        updateFavorites { $0.remove(path: favorite.path) }
    }

    func resetFavorites() {
        let alert = NSAlert()
        alert.messageText = "重置常用目录？"
        alert.informativeText = "清空收藏并恢复此页开关。"
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        guard alert.runLocalizedModal() == .alertFirstButtonReturn else { return }
        setSystemPreference {
            var favorites = $0.favorites ?? SavedFolders()
            favorites.removeAll()
            favorites.showsMenu = true
            $0.favorites = favorites
            $0.showsFavoriteIcons = true
        }
        selectedFavoriteID = nil
    }

    private func makeFolderAccess(_ url: URL) throws -> FolderAccess {
        let bookmark = try url.bookmarkData(options: FileAccessPolicy.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        return FolderAccess(path: url.standardizedFileURL.path, bookmark: bookmark)
    }

    private func updateFavorites(_ change: (inout SavedFolders) -> Void) {
        var next = settings
        var favorites = next.favorites ?? SavedFolders()
        change(&favorites)
        next.favorites = favorites
        save(next)
    }

    func setTemplateEnabled(_ template: DocumentTemplate, _ enabled: Bool) {
        var next = settings
        var templates = next.enabledTemplates ?? Set(DocumentTemplate.allCases)
        if enabled { templates.insert(template) } else { templates.remove(template) }
        next.enabledTemplates = templates
        save(next)
    }

    func renameTemplate(_ template: DocumentTemplate, to name: String) {
        setSystemPreference { $0.renameTemplate(template, to: name) }
    }

    func renameTemplate(_ entry: CustomTemplate, to name: String) {
        setSystemPreference { $0.customTemplates?.renameTemplate(id: entry.id, to: name) }
    }

    func moveTemplate(_ template: DocumentTemplate, by offset: Int) {
        var next = settings
        next.moveTemplate(template, by: offset)
        save(next)
    }

    func moveTemplate(_ entry: CustomTemplate, by offset: Int) {
        var next = settings
        next.customTemplates?.moveTemplate(id: entry.id, by: offset)
        save(next)
    }

    func reorderTemplate(_ template: DocumentTemplate, to target: DocumentTemplate) {
        var next = settings
        next.moveTemplate(template, to: target)
        save(next)
    }

    func reorderTemplate(id: Int, to target: Int) {
        var next = settings
        next.customTemplates?.moveTemplate(id: id, to: target)
        save(next)
    }

    func setNamedCreation(_ enabled: Bool) {
        var next = settings
        next.showsNamedCreation = enabled
        save(next)
    }

    func setTemplatePromoted(_ template: DocumentTemplate, _ promoted: Bool) {
        var next = settings
        var templates = next.promotedTemplates ?? []
        if promoted { templates.insert(template) } else { templates.remove(template) }
        next.promotedTemplates = templates
        save(next)
    }

    func setOpensNewDocuments(_ enabled: Bool) {
        var next = settings
        next.opensNewDocuments = enabled
        save(next)
    }

    func setPlaysCreationSound(_ enabled: Bool) {
        var next = settings
        next.playsCreationSound = enabled
        save(next)
    }

    func importTemplate() {
        let panel = NSOpenPanel()
        panel.title = "选择要导入的文件模板"
        panel.prompt = "导入"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            settings = try TemplateStore.importFile(source, into: settings)
        } catch { report(error, context: "无法导入模板") }
    }

    func setCustomTemplateEnabled(_ entry: CustomTemplate, _ enabled: Bool) {
        var next = settings
        guard let index = next.customTemplates?.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        next.customTemplates?.entries[index].enabled = enabled
        save(next)
    }

    func setCustomTemplatePromoted(_ entry: CustomTemplate, _ promoted: Bool) {
        setSystemPreference {
            guard let index = $0.customTemplates?.entries.firstIndex(where: { $0.id == entry.id }) else { return }
            $0.customTemplates?.entries[index].showsInMainMenu = promoted
        }
    }

    func resetTemplateSettings() {
        let alert = NSAlert()
        alert.messageText = "重置新建文件设置？"
        alert.informativeText = "恢复内置和导入模板的默认名称、顺序、启用状态及菜单设置。已导入的模板文件会保留。"
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        guard alert.runLocalizedModal() == .alertFirstButtonReturn else { return }
        setSystemPreference { $0.resetTemplateSettings() }
    }

    func showTemplateHelp() {
        let alert = NSAlert()
        alert.messageText = "新建文件帮助"
        alert.informativeText = "在访达目录空白处右键，打开「新建文件」，选择模板即可创建。\n\n在设置中勾选「主菜单」，可以把该模板直接放到右键菜单。双击名称可修改菜单文字，拖动行可调整顺序。\n\n点击「添加模版文件」可导入自己的模板。"
        alert.addButton(withTitle: "好")
        alert.runLocalizedModal()
    }

    func showTemplateTroubleshooting() {
        let alert = NSAlert()
        alert.messageText = "右键菜单失效的解决办法"
        alert.informativeText = "1. 在系统设置中启用增强右键的 Finder 扩展。\n2. 在「通用设置 → 使用范围」中确认包含当前目录。\n3. 在「新建文件」中启用至少一个模板，在访达目录空白处重新打开右键菜单。\n4. 扩展已启用但菜单仍未出现时，可退出并重新打开增强右键。"
        alert.addButton(withTitle: "打开 Finder 扩展设置")
        alert.addButton(withTitle: "关闭")
        if alert.runLocalizedModal() == .alertFirstButtonReturn {
            FIFinderSyncController.showExtensionManagementInterface()
        }
    }

    func removeTemplate(_ entry: CustomTemplate) {
        do {
            settings = try TemplateStore.remove(entry, from: settings)
        } catch { report(error, context: "无法移除模板") }
    }

    func perform(_ request: FinderRequest) async throws {
        let current = try SharedStore.load()
        guard current.isEnabled(request.action) else { throw SuperMenuError.invalidTarget }
        let isToolbarCreation = request.action == .newText && request.fromToolbar == true
        let urls: [URL]
        if request.action == .cancelCut {
            guard request.paths.isEmpty else { throw SuperMenuError.invalidTarget }
            urls = []
        } else if request.action == .openFavorite {
            page = .favorites
            guard let id = request.favoriteFolderID else { throw SuperMenuError.favoriteUnavailable }
            let favorite = try current.favoriteFolder(id: id)
            urls = [URL(fileURLWithPath: favorite.path, isDirectory: true)]
        } else {
            guard isToolbarCreation || !request.paths.isEmpty,
                  [.copyPath, .copyName, .copyToFolder, .moveToFolder, .cut, .fileInfo, .hideSelected, .showSelected,
                   .toggleExtension, .repairNames, .desktopAlias, .airDrop, .deletePermanently].contains(request.action)
                    || [.convertImage, .setFileIcon, .restoreFileIcon, .openWithApp, .grantWrite,
                        .compressZIP, .compress7z, .extractArchive, .iShotAnnotate, .openFastZip].contains(request.action)
                    || request.paths.count == 1 || (isToolbarCreation && request.paths.isEmpty),
                  request.paths.allSatisfy({ $0.hasPrefix("/") }) else { throw SuperMenuError.invalidTarget }
            urls = request.paths.map { URL(fileURLWithPath: $0) }
        }

        switch request.action {
        case .openWithApp:
            guard let id = request.applicationID,
                  let entry = (current.applications ?? ApplicationCatalog.entries).first(where: { $0.id == id && $0.enabled })
            else { throw SuperMenuError.invalidTarget }
            try await integrations.openApplication(entry, urls: urls, settings: current)
        case .dissolveFolder, .setWallpaper, .grantWrite, .iShotCapture, .iShotAnnotate,
             .compressZIP, .compress7z, .extractArchive, .diskMap, .openFastZip:
            try await integrations.perform(request.action, urls: urls, settings: current)
        case .convertImage:
            guard let format = request.imageFormat else { throw SuperMenuError.invalidTarget }
            try await imageTools.convert(urls, format: format, settings: current)
        case .setFileIcon, .restoreFileIcon:
            try await imageTools.setIcons(urls, restore: request.action == .restoreFileIcon, settings: current,
                                          iconID: request.fileIconID, removesCustomIcon: request.removesCustomIcon == true)
        case .fileInfo, .hideSelected, .showSelected, .showHiddenFiles, .hideHiddenFiles, .toggleExtension,
             .repairNames, .desktopAlias, .airDrop, .deletePermanently:
            try await toolbox.perform(request.action, urls: urls, settings: current, checksum: request.checksum)
        case .cut:
            try await cutTransfer.cut(urls)
        case .pasteCut:
            guard let batchID = request.cutBatchID else { throw SuperMenuError.cutUnavailable }
            try await cutTransfer.paste(into: urls[0], batchID: batchID)
        case .cancelCut:
            guard let batchID = request.cutBatchID else { throw SuperMenuError.cutUnavailable }
            try await cutTransfer.cancel(batchID: batchID)
        case .copyPath, .copyName:
            for url in urls {
                try FileActions.withAuthorizedURL(url, settings: current) { _ in }
            }
            try FileActions.copyLocationText(request.paths, namesOnly: request.action == .copyName, to: .general)
        case .folderFromName:
            _ = try FileActions.withAuthorizedURL(urls[0], settings: current, rejectSymbolicLink: true) { url in
                try FileActions.createFolderFromName(of: url)
            }
        case .newText:
            if request.promptsForFileName == true {
                guard request.template == nil, request.customTemplateID == nil else { throw SuperMenuError.invalidTarget }
                guard current.allowsNamedCreation else { throw SuperMenuError.templateDisabled }
            }
            if isToolbarCreation, !isAuthorizedCreationFolder(urls.first, settings: current) {
                try createInPickedFolder(request)
                return
            }
            guard let target = urls.first else { throw SuperMenuError.invalidTarget }
            if request.promptsForFileName == true {
                try createNamedDocument(in: target, settings: current)
                return
            }
            try withCreationFolder(target, settings: current) { url in
                try createQuickDocument(request, in: url, settings: current)
            }
        case .openTerminal:
            let terminal = (current.applications ?? ApplicationCatalog.entries).first { $0.bundleID == "com.apple.Terminal" }
                ?? ApplicationCatalog.entries.first { $0.bundleID == "com.apple.Terminal" }!
            try await integrations.openApplication(terminal, urls: urls, settings: current)
        case .openFavorite:
            do {
                try withCreationFolder(urls[0], settings: current) { url in
                    guard NSWorkspace.shared.open(url) else { throw SuperMenuError.folderOpenFailed }
                }
            } catch { throw SuperMenuError.favoriteUnavailable }
        case .addFavorite:
            try withCreationFolder(urls[0], settings: current) { _ in
                let path = urls[0].standardizedFileURL.path
                updateFavorites { $0.add(path: path) }
            }
        case .copyToFolder, .moveToFolder:
            try await transferSelection(request)
        }
    }

    private func transferSelection(_ request: FinderRequest) async throws {
        let mode: FileTransfer.Mode = request.action == .copyToFolder ? .copy : .move
        let picked: URL?
        if request.transferTarget == .other {
            let panel = NSOpenPanel()
            panel.title = "选择\(mode.verb)目标"
            panel.prompt = "\(mode.verb)到这里"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            picked = folder
        } else {
            picked = nil
        }
        defer { picked?.stopAccessingSecurityScopedResource() }
        let pickedAccess = picked.flatMap { try? makeFolderAccess($0) }
        let (result, folder) = try await Task.detached(priority: .userInitiated) { () throws -> (FileTransfer.BatchResult, FolderAccess?) in
            let current = try SharedStore.load()
            guard current.isEnabled(request.action) else { throw SuperMenuError.copyDestinationUnavailable }
            if let picked {
                let result = try FileTransfer.transferSelection(request.paths, into: picked, mode: mode, settings: current)
                return (result, pickedAccess)
            }
            guard let id = request.copyDestinationID else { throw SuperMenuError.copyDestinationUnavailable }
            let access: FolderAccess
            if request.transferTarget == .recent {
                guard let entry = current.recentTransfers?.entries.first(where: { $0.id == id }) else {
                    throw SuperMenuError.copyDestinationUnavailable
                }
                access = entry.folder
            } else {
                let destination = try current.transferDestination(id: id, action: request.action)
                if FileAccessPolicy.usesDirectAccess {
                    access = FolderAccess(path: destination.path, bookmark: Data())
                } else {
                    guard let folder = current.folders.first(where: { $0.path == destination.path }) else {
                        throw SuperMenuError.copyDestinationUnavailable
                    }
                    access = folder
                }
            }
            let url = URL(fileURLWithPath: access.path, isDirectory: true)
            let result = try FileActions.withAuthorizedURL(url, settings: Settings(usageScope: current.usageScope, folders: [access])) { target in
                try FileTransfer.transferSelection(request.paths, into: target, mode: mode, settings: current)
            }
            return (result, access)
        }.value
        if result.completed > 0, let folder {
            var latest = try SharedStore.load()
            var history = latest.recentTransfers ?? RecentTransfers()
            history.record(folder)
            latest.recentTransfers = history
            save(latest)
        }
        if let notice = result.notice(for: mode) { throw notice }
    }

    private func withCreationFolder(_ target: URL, settings: Settings, perform: (URL) throws -> Void) throws {
        try FileActions.withAuthorizedURL(target, settings: settings) { url in
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw SuperMenuError.invalidTarget
            }
            try perform(url)
        }
    }

    private func isAuthorizedCreationFolder(_ url: URL?, settings: Settings) -> Bool {
        guard let url else { return false }
        return (try? withCreationFolder(url, settings: settings) { _ in }) != nil
    }

    private func createQuickDocument(_ request: FinderRequest, in folder: URL, settings: Settings) throws {
        guard settings.isEnabled(.newText) else { throw SuperMenuError.templateDisabled }
        let output: URL
        if let id = request.customTemplateID {
            guard let library = settings.customTemplates else { throw SuperMenuError.templateDisabled }
            let entry = try library.enabledTemplate(id: id)
            output = try TemplateStore.createDocument(from: entry, in: folder)
        } else {
            let template = request.template ?? .text
            guard settings.visibleTemplates.contains(template) else { throw SuperMenuError.templateDisabled }
            output = try FileActions.createDocument(template, in: folder)
        }
        try finishCreating(output, settings: settings)
    }

    private func createInPickedFolder(_ request: FinderRequest) throws {
        guard !isPickingCreationFolder, !isNamingDocument else { return }
        isPickingCreationFolder = true
        defer { isPickingCreationFolder = false }
        let panel = NSOpenPanel()
        panel.title = "选择新文件的保存位置"
        panel.prompt = "选择文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        defer { folder.stopAccessingSecurityScopedResource() }

        let latest = try SharedStore.load()
        if request.promptsForFileName == true {
            guard latest.allowsNamedCreation else { throw SuperMenuError.templateDisabled }
            guard let document = askForDocumentName(in: folder) else { return }
            let afterNaming = try SharedStore.load()
            guard afterNaming.allowsNamedCreation else { throw SuperMenuError.templateDisabled }
            try finishCreating(FileActions.createDocument(document, in: folder), settings: afterNaming)
        } else {
            try createQuickDocument(request, in: folder, settings: latest)
        }
    }

    private func createNamedDocument(in target: URL, settings: Settings) throws {
        guard settings.allowsNamedCreation else { throw SuperMenuError.templateDisabled }
        guard !isNamingDocument, !isPickingCreationFolder else { return }
        try withCreationFolder(target, settings: settings) { _ in }
        isNamingDocument = true
        defer { isNamingDocument = false }
        guard let document = askForDocumentName(in: target) else { return }

        let latest = try SharedStore.load()
        guard latest.allowsNamedCreation else { throw SuperMenuError.templateDisabled }
        try withCreationFolder(target, settings: latest) { folder in
            let output = try FileActions.createDocument(document, in: folder)
            try finishCreating(output, settings: latest)
        }
    }

    private func askForDocumentName(in target: URL) -> NamedDocument? {
        let folderName = FileManager.default.displayName(atPath: target.path)
        let instructions = "在「\(folderName)」中创建。可输入带后缀的名称，如「工作记录.txt」。同名文件会自动编号。"
        var input = ""
        var validation: String?
        NSApp.activate(ignoringOtherApps: true)
        while true {
            let alert = NSAlert()
            alert.messageText = NamedDocument.title
            alert.informativeText = validation.map { "\(instructions)\n\n\($0)" } ?? instructions
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = "文件名"
            field.setAccessibilityLabel("文件名")
            field.stringValue = input
            alert.accessoryView = field
            alert.addButton(withTitle: "创建")
            alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            alert.window.initialFirstResponder = field
            guard alert.runLocalizedModal() == .alertFirstButtonReturn else { return nil }
            input = field.stringValue
            do { return try NamedDocument(input) }
            catch { validation = error.localizedDescription }
        }
    }

    private func finishCreating(_ output: URL, settings: Settings) throws {
        if settings.playsCreationSound == true { NSSound(named: "Pop")?.play() }
        if settings.opensNewDocuments == true, !NSWorkspace.shared.open(output) {
            throw SuperMenuError.newDocumentOpenFailed
        }
    }

    func report(_ error: Error, context: String? = nil) {
        let detail = error as NSError
        if let context {
            message = "\(context)：\(detail.localizedDescription)（\(detail.domain) \(detail.code)）"
        } else {
            message = detail.localizedDescription
        }
        if FileAccessPolicy.usesDirectAccess,
           (detail.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(detail.code)
            || detail.domain == NSPOSIXErrorDomain && [1, 13].contains(detail.code)) {
            message += "\n\n请检查文件权限；受系统保护的位置可在通用设置的「权限设置引导」中授予完全磁盘访问权限。"
        }
        showsMessage = true
    }

    private func save(_ next: Settings) {
        do {
            try SharedStore.save(next)
            settings = next
            storageAvailable = true
            refreshCloudTriggers()
        } catch { report(error, context: "无法写入共享配置") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = SettingsModel()
    private var window: NSWindow?
    private var receivedRequest = false
    private var statusItem: NSStatusItem?
    private var preferencesObserver: NSObjectProtocol?
    private var services: ServiceRouter?
    private var showingExtensionPrompt = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        services = ServiceRouter(text: model.integrations.textServices)
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        updateStatusItem()
        preferencesObserver = DistributedNotificationCenter.default().addObserver(forName: SharedStore.settingsChanged,
                                                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        model.updates.check(automatically: true, enabled: model.settings.automaticallyChecksForUpdates ?? true)
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.updates.check(automatically: true, enabled: self.model.settings.automaticallyChecksForUpdates ?? true)
            }
        }
        Task { await model.refreshPermissions() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.model.refreshPermissions() }
        }
        model.recoverExpiredCut()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.recoverExpiredCut() }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.receivedRequest else { return }
            if self.model.settings.launchesQuietly == true { self.checkFinderExtension() }
            else { self.showSettings() }
        }
    }

    private func updateStatusItem() {
        let settings = (try? SharedStore.load()) ?? model.settings
        if settings.showsStatusItem == false {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        if let button = statusItem?.button, button.image == nil {
            let icon = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg")
                .flatMap { NSImage(contentsOf: $0) }
                ?? NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil)
            icon?.isTemplate = true
            button.image = icon
            button.setAccessibilityLabel("增强右键")
        }
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: InterfaceText.current("偏好设置…"), action: #selector(openSettingsFromStatus), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quit = NSMenuItem(title: InterfaceText.current("退出"), action: #selector(quitFromStatus), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    @objc private func openSettingsFromStatus() { showSettings() }
    @objc private func quitFromStatus() { NSApp.terminate(nil) }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refresh()
        Task { await model.refreshPermissions() }
        model.recoverExpiredCut()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedRequest = true
        Task {
            for url in urls {
                do {
                    if let request = try SharedStore.consume(url) { try await model.perform(request) }
                } catch {
                    showSettings()
                    model.report(error)
                }
            }
        }
    }

    private func showSettings() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: controller)
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.title = "增强右键"
            created.minSize = NSSize(width: 800, height: 490)
            created.setContentSize(NSSize(width: 1060, height: 760))
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        checkFinderExtension()
    }

    private func checkFinderExtension() {
        guard !showingExtensionPrompt else { return }
        showingExtensionPrompt = true
        Task { @MainActor in
            defer { showingExtensionPrompt = false }
            // Allow the extension registration state to settle after launch or reopening.
            try? await Task.sleep(for: .milliseconds(700))
            guard await FinderExtensionPermission.isEnabled() == false else { return }
            let alert = NSAlert()
            alert.messageText = "请启用增强右键的访达扩展"
            alert.informativeText = "在系统设置中启用增强右键的访达扩展，才能在访达中使用右键菜单。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runLocalizedModal() == .alertFirstButtonReturn {
                FIFinderSyncController.showExtensionManagementInterface()
            }
        }
    }
}

#if !SUPERMENU_TEST
@main
struct SuperMenuApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--permission-status-probe") {
            if let data = try? JSONEncoder().encode(PermissionSnapshot.capture()) {
                FileHandle.standardOutput.write(data)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .aqua)
        app.run()
    }
}
#endif
