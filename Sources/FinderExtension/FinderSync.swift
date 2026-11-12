import AppKit
import FinderSync
import os
import UniformTypeIdentifiers

final class FinderSync: FIFinderSync {
    private let log = Logger(subsystem: "io.github.1078302479.SuperMenu", category: "Finder")
    private var observation: NSObjectProtocol?
    private var volumeObservers: [NSObjectProtocol] = []
    private var settings = Settings()
    private var settingsRetry: DispatchWorkItem?
    private var retryCount = 0

    private lazy var menuController = FinderMenuController(context: {
        let controller = FIFinderSyncController.default()
        return FinderMenuContext(folder: controller.targetedURL(), selection: controller.selectedItemURLs() ?? [])
    }, onRequest: { [weak self] request in self?.send(request) })

    override init() {
        super.init()
        let started = Date()
        do { settings = try SharedStore.load() }
        catch { log.error("启动时暂未读取到共享配置：\(error.localizedDescription, privacy: .public)") }
        FIFinderSyncController.default().directoryURLs = FileAccessPolicy.monitoredDirectories(settings: settings)
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshFolders()
            })
        }
        observation = DistributedNotificationCenter.default().addObserver(
            forName: SharedStore.settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshFolders() }
        DispatchQueue.main.async { [weak self] in self?.prepareMenuResources() }
        log.notice("扩展初始化完成，监听目录数：\(FIFinderSyncController.default().directoryURLs.count)，耗时：\(Date().timeIntervalSince(started), privacy: .public)秒")
    }

    deinit {
        settingsRetry?.cancel()
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let observation { DistributedNotificationCenter.default().removeObserver(observation) }
    }

    private func refreshFolders() {
        do {
            settings = try SharedStore.load()
            let controller = FIFinderSyncController.default()
            let directories = FileAccessPolicy.monitoredDirectories(settings: settings)
            if controller.directoryURLs != directories { controller.directoryURLs = directories }
            settingsRetry?.cancel()
            retryCount = 0
        } catch {
            log.error("无法读取共享配置：\(error.localizedDescription, privacy: .public)")
            guard retryCount < 5 else { return }
            retryCount += 1
            settingsRetry?.cancel()
            let retry = DispatchWorkItem { [weak self] in self?.refreshFolders() }
            settingsRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
        }
    }

    private func prepareMenuResources() {
        // Finder has a short deadline for the first menu callback. Warm AppKit,
        // Launch Services and image decoding before it asks us to construct one.
        let started = Date()
        _ = NSMenu(title: "增强右键")
        for action in FinderAction.allCases where settings.isEnabled(action) {
            _ = MenuIcons.action(action, size: 16)
        }
        _ = MenuIcons.newFile(size: 16)
        _ = MenuIcons.namedFile(size: 16)
        for template in settings.orderedTemplates where template.isAvailable {
            _ = MenuIcons.document(extension: template.rawValue, size: 16)
        }
        for entry in settings.applications ?? ApplicationCatalog.entries where entry.enabled {
            for id in [entry.bundleID] + (entry.alternateBundleIdentifiers ?? []) {
                _ = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            }
            _ = MenuIcons.application(entry, size: 16)
        }
        for folder in settings.availableFavorites + settings.availableCopyDestinations {
            _ = MenuIcons.folder(at: URL(fileURLWithPath: folder.path))
        }
        _ = UTType(filenameExtension: "jpg")?.conforms(to: .image)
        log.notice("菜单资源准备完成，耗时：\(Date().timeIntervalSince(started), privacy: .public)秒")
    }

    override func beginObservingDirectory(at url: URL) {
        log.notice("已开始监听访达目录")
    }

    override var toolbarItemName: String { "增强右键" }
    override var toolbarItemToolTip: String { "使用增强右键新建文件" }
    override var toolbarItemImage: NSImage {
        let image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "新建文件") ?? NSImage()
        image.isTemplate = true
        return image
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        menuController.menu(for: menuKind, settings: settings)
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
