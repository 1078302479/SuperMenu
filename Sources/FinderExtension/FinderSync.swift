import AppKit
import FinderSync
import os

final class FinderSync: FIFinderSync {
    private let log = Logger(subsystem: "io.github.1078302479.SuperMenu", category: "Finder")
    private var observation: NSObjectProtocol?

    override init() {
        super.init()
        refreshFolders()
        observation = DistributedNotificationCenter.default().addObserver(
            forName: SharedStore.settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshFolders() }
    }

    deinit {
        if let observation { DistributedNotificationCenter.default().removeObserver(observation) }
    }

    private func refreshFolders() {
        do {
            FIFinderSyncController.default().directoryURLs = Set(try SharedStore.load().folders.map {
                URL(fileURLWithPath: $0.path, isDirectory: true)
            })
        } catch {
            FIFinderSyncController.default().directoryURLs = []
            log.error("无法读取共享配置：\(error.localizedDescription, privacy: .public)")
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard let settings = try? SharedStore.load() else { return nil }
        let controller = FIFinderSyncController.default()
        let menu = NSMenu(title: "SuperMenu")
        switch menuKind {
        case .contextualMenuForContainer, .contextualMenuForSidebar:
            guard controller.targetedURL() != nil else { return nil }
            addTemplates(to: menu, settings: settings)
            add(.copyPath, selector: #selector(copyFolderPath), to: menu, settings: settings)
            add(.openTerminal, selector: #selector(openFolderInTerminal), to: menu, settings: settings)
        case .contextualMenuForItems:
            let count = controller.selectedItemURLs()?.count ?? 0
            guard count > 0 else { return nil }
            add(.copyPath, selector: #selector(copySelectedPaths), to: menu, settings: settings)
            if count == 1 {
                add(.openTerminal, selector: #selector(openSelectionInTerminal), to: menu, settings: settings)
            }
        default:
            return nil
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func add(_ action: FinderAction, selector: Selector, to menu: NSMenu, settings: Settings) {
        guard settings.enabled.contains(action) else { return }
        let item = NSMenuItem(title: action.title, action: selector, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    private func addTemplates(to menu: NSMenu, settings: Settings) {
        let templates = settings.visibleTemplates
        guard settings.enabled.contains(.newText), !templates.isEmpty else { return }
        let submenu = NSMenu(title: FinderAction.newText.title)
        for template in templates {
            let selector: Selector
            switch template {
            case .text: selector = #selector(createText)
            case .markdown: selector = #selector(createMarkdown)
            case .richText: selector = #selector(createRichText)
            case .xml: selector = #selector(createXML)
            }
            let item = NSMenuItem(title: template.title, action: selector, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: FinderAction.newText.symbol, accessibilityDescription: nil)
        parent.submenu = submenu
        menu.addItem(parent)
    }

    // Finder supplies the active context again when it dispatches an action.
    @objc private func createText() { perform(.newText, urls: targetedFolder, template: .text) }
    @objc private func createMarkdown() { perform(.newText, urls: targetedFolder, template: .markdown) }
    @objc private func createRichText() { perform(.newText, urls: targetedFolder, template: .richText) }
    @objc private func createXML() { perform(.newText, urls: targetedFolder, template: .xml) }
    @objc private func copyFolderPath() { perform(.copyPath, urls: targetedFolder) }
    @objc private func openFolderInTerminal() { perform(.openTerminal, urls: targetedFolder) }
    @objc private func copySelectedPaths() { perform(.copyPath, urls: selection) }
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

    private func perform(_ action: FinderAction, urls: [URL], template: DocumentTemplate? = nil) {
        guard !urls.isEmpty else {
            log.error("Finder 未提供动作目标：\(action.rawValue, privacy: .public)")
            return
        }
        do {
            let request = FinderRequest(action: action, paths: urls.map(\.path), created: Date(), template: template)
            let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try FinderHandoff.send(request, to: app) { [log] error in
                if let error { log.error("无法打开 SuperMenu：\(error.localizedDescription, privacy: .public)") }
            }
        } catch {
            log.error("无法发送 Finder 请求：\(error.localizedDescription, privacy: .public)")
        }
    }
}
