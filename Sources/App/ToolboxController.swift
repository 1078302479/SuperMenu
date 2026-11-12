import AppKit

@MainActor
final class ToolboxController: NSObject, NSWindowDelegate, NSSharingServiceDelegate {
    private struct InformationSession {
        let task: Task<Void, Never>
        let text: NSTextView
    }
    private var informationWindows: [NSWindow: InformationSession] = [:]
    private var shares: [NSSharingService: [URL]] = [:]
    private var isPrompting = false

    func perform(_ action: FinderAction, urls: [URL], settings: Settings, checksum: FileChecksum? = nil) async throws {
        switch action {
        case .fileInfo:
            showInformation(urls, settings: settings, checksum: checksum)
        case .showHiddenFiles, .hideHiddenFiles:
            try setFinderHiddenVisibility(action == .showHiddenFiles)
        case .airDrop:
            try share(urls, settings: settings)
        case .repairNames:
            guard !isPrompting else { return }
            isPrompting = true
            defer { isPrompting = false }
            try repairNames(urls, settings: settings)
        case .deletePermanently:
            guard !isPrompting else { return }
            isPrompting = true
            defer { isPrompting = false }
            let identities = try urls.map { url in
                try FileActions.withAuthorizedURL(url, settings: settings, rejectSymbolicLink: true) {
                    try ToolboxActions.identity($0)
                }
            }
            if settings.confirmsPermanentDelete != false {
                guard DeleteConfirmation.confirm(urls: urls) else { return }
            }
            let latest = try SharedStore.load()
            guard latest.isEnabled(.deletePermanently) else { throw SuperMenuError.invalidTarget }
            try await runBatch(urls, settings: latest) { url, index in
                try ToolboxActions.permanentlyDelete(url, expected: identities[index])
            }
        case .desktopAlias:
            guard !isPrompting else { return }
            isPrompting = true
            defer { isPrompting = false }
            let desktop = try chooseDesktop(settings: settings)
            guard let desktop else { return }
            try await runBatch(urls, settings: settings) { url, _ in
                try FileActions.withAuthorizedURL(URL(fileURLWithPath: desktop.path), settings: Settings(usageScope: settings.usageScope, folders: [desktop])) { folder in
                    _ = try ToolboxActions.createAlias(for: url, in: folder)
                }
            }
        case .hideSelected, .showSelected, .toggleExtension:
            try await runBatch(urls, settings: settings) { url, _ in
                if action == .toggleExtension { try ToolboxActions.toggleExtension(at: url) }
                else { try ToolboxActions.setHidden(action == .hideSelected, at: url) }
            }
        default: throw SuperMenuError.invalidTarget
        }
    }

    private func runBatch(_ urls: [URL], settings: Settings,
                          operation: @escaping @Sendable (URL, Int) throws -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            var completed = 0
            var errors: [String] = []
            for (index, url) in urls.enumerated() {
                do {
                    try FileActions.withAuthorizedURL(url, settings: settings, rejectSymbolicLink: true) { resolved in
                        try operation(resolved, index)
                    }
                    completed += 1
                } catch { errors.append("\(url.lastPathComponent) · \(error.localizedDescription)") }
            }
            if !errors.isEmpty {
                throw TransferNotice(lines: ["已完成 \(completed) 项，\(errors.count) 项失败。"] + Array(errors.prefix(8)))
            }
        }.value
    }

    private func showInformation(_ urls: [URL], settings: Settings, checksum: FileChecksum?) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 692, height: 430))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        let status = NSTextField(labelWithString: "正在读取…")
        let cancel = NSButton(title: "取消计算", target: self, action: #selector(cancelInformation(_:)))
        let copy = NSButton(title: "拷贝结果", target: self, action: #selector(copyInformation(_:)))
        copy.isEnabled = false
        let buttons = NSStackView(views: [copy, cancel])
        buttons.spacing = 10
        let stack = NSStackView(views: [status, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = checksum?.rawValue ?? "文件信息与校验"
        window.contentView = stack
        window.minSize = NSSize(width: 520, height: 300)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let worker = Task.detached(priority: .userInitiated) { () -> String in
            var sections: [String] = []
            for url in urls {
                do {
                    try Task.checkCancellation()
                    let result = try FileActions.withAuthorizedURL(url, settings: settings, rejectSymbolicLink: true) { resolved in
                        try ToolboxActions.fileInformation(at: resolved, checksum: checksum) { done, total in
                            if done % (8 << 20) == 0 || done == total {
                                Task { @MainActor in status.stringValue = "\(url.lastPathComponent) · \(done) / \(total) 字节" }
                            }
                        }
                    }
                    sections.append(result)
                } catch is CancellationError { return (sections + ["已取消计算。"]).joined(separator: "\n\n") }
                catch { sections.append("\(url.path)\n\(error.localizedDescription)") }
            }
            return sections.joined(separator: "\n\n────────────────────\n\n")
        }
        let task = Task {
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            textView.string = result
            status.stringValue = "计算结束"
            cancel.isEnabled = false
            copy.isEnabled = true
        }
        informationWindows[window] = InformationSession(task: task, text: textView)
    }

    @objc private func cancelInformation(_ sender: NSButton) {
        if let window = sender.window { informationWindows[window]?.task.cancel() }
    }

    @objc private func copyInformation(_ sender: NSButton) {
        guard let window = sender.window, let text = informationWindows[window]?.text.string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { informationWindows.removeValue(forKey: window)?.task.cancel() }
    }

    private func chooseDesktop(settings: Settings) throws -> FolderAccess? {
        if FileAccessPolicy.usesDirectAccess,
           let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            return FolderAccess(path: desktop.path, bookmark: Data())
        }
        if let saved = settings.desktopFolder {
            do {
                try FileActions.withAuthorizedURL(URL(fileURLWithPath: saved.path), settings: Settings(folders: [saved])) { _ in }
                return saved
            } catch {
                // Expired desktop authorization is renewed through the same picker.
            }
        }
        let panel = NSOpenPanel()
        panel.title = "选择桌面目录以保存替身"
        panel.prompt = "使用这个目录"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let picked = panel.url else { return nil }
        defer { picked.stopAccessingSecurityScopedResource() }
        let bookmark = try picked.bookmarkData(options: FileAccessPolicy.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        let access = FolderAccess(path: picked.standardizedFileURL.path, bookmark: bookmark)
        var latest = try SharedStore.load()
        latest.desktopFolder = access
        try SharedStore.save(latest)
        return access
    }

    private func share(_ urls: [URL], settings: Settings) throws {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            throw ToolboxError.message("系统未提供隔空投送服务。")
        }
        var scopes: [URL] = []
        do {
            for url in urls {
                try FileActions.withAuthorizedURL(url, settings: settings, rejectSymbolicLink: true) { resolved in
                    if FileAccessPolicy.usesDirectAccess {
                        scopes.append(resolved)
                        return
                    }
                    let bookmark = try resolved.bookmarkData(options: FileAccessPolicy.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
                    var stale = false
                    let scoped = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                         relativeTo: nil, bookmarkDataIsStale: &stale)
                    guard !stale, scoped.startAccessingSecurityScopedResource() else { throw SuperMenuError.staleBookmark }
                    scopes.append(scoped)
                }
            }
            guard service.canPerform(withItems: scopes) else { throw ToolboxError.message("这些项目暂时无法通过隔空投送发送。") }
        } catch {
            scopes.forEach { $0.stopAccessingSecurityScopedResource() }
            throw error
        }
        shares[service] = scopes
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: scopes)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        releaseShare(sharingService)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        releaseShare(sharingService)
        guard (error as NSError).code != NSUserCancelledError else { return }
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private func releaseShare(_ service: NSSharingService) {
        shares.removeValue(forKey: service)?.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    private func repairNames(_ urls: [URL], settings: Settings) throws {
        let encoding = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        encoding.addItems(withTitles: ToolboxActions.repairEncodings.map(\.title))
        let labels = NSTextField(labelWithString: "选择乱码形成时使用的编码，下一步预览每个文件的新名称。")
        let alert = NSAlert()
        alert.messageText = "修复乱码文件名"
        alert.informativeText = labels.stringValue
        alert.accessoryView = encoding
        alert.addButton(withTitle: "预览")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selected = ToolboxActions.repairEncodings[encoding.indexOfSelectedItem]
        var errors: [String] = []
        for url in urls {
            do {
                let expected = try FileActions.withAuthorizedURL(url, settings: settings, rejectSymbolicLink: true) {
                    try ToolboxActions.identity($0)
                }
                let candidate = ToolboxActions.repairName(url.lastPathComponent, encoding: selected.source,
                                                          destination: selected.destination) ?? url.lastPathComponent
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
                field.stringValue = candidate
                let preview = NSAlert()
                preview.messageText = url.lastPathComponent
                preview.informativeText = "确认新名称，可直接修改。已有同名项目时会保留原文件。"
                preview.accessoryView = field
                preview.addButton(withTitle: "重命名")
                preview.addButton(withTitle: "跳过")
                preview.addButton(withTitle: "结束")
                preview.window.initialFirstResponder = field
                let choice = preview.runModal()
                if choice == .alertThirdButtonReturn { break }
                guard choice == .alertFirstButtonReturn else { continue }
                let latest = try SharedStore.load()
                guard latest.isEnabled(.repairNames) else { throw SuperMenuError.invalidTarget }
                try FileActions.withAuthorizedURL(url, settings: latest, rejectSymbolicLink: true) { resolved in
                    _ = try ToolboxActions.rename(resolved, to: field.stringValue, expected: expected)
                }
            } catch { errors.append("\(url.lastPathComponent) · \(error.localizedDescription)") }
        }
        if !errors.isEmpty { throw TransferNotice(lines: errors) }
    }

    private func setFinderHiddenVisibility(_ visible: Bool) throws {
        guard !isPrompting else { return }
        isPrompting = true
        defer { isPrompting = false }
        guard confirm(visible ? "显示隐藏项目？" : "不显示隐藏项目？",
                      detail: "此设置影响所有访达窗口，需要重新打开访达以应用。", button: "应用并重新打开访达") else { return }
        let domain = "com.apple.finder" as CFString
        CFPreferencesSetAppValue("AppleShowAllFiles" as CFString, visible ? kCFBooleanTrue : kCFBooleanFalse, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw ToolboxError.message("无法保存访达显示设置。") }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              finder.terminate() else {
            throw ToolboxError.message("设置已保存。请手动重新打开访达以应用。")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func confirm(_ title: String, detail: String, button: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        if detail.count > 800 {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
            text.string = detail
            text.isEditable = false
            text.isSelectable = true
            text.font = .systemFont(ofSize: 12)
            text.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(frame: text.frame)
            scroll.hasVerticalScroller = true
            scroll.documentView = text
            alert.accessoryView = scroll
        } else {
            alert.informativeText = detail
        }
        alert.alertStyle = destructive ? .critical : .informational
        alert.addButton(withTitle: button).hasDestructiveAction = destructive
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
