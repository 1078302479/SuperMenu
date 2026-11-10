import AppKit

@MainActor
final class ImageToolsController: NSObject, NSWindowDelegate {
    private var jobs: [NSWindow: Task<Void, Never>] = [:]

    func convert(_ urls: [URL], format: ImageFormat, settings: Settings) throws {
        guard settings.enabledImageFormats?.contains(format) ?? true else { throw SuperMenuError.invalidTarget }
        let options = ImageConversion.Options(quality: min(1, max(0.1, settings.imageQuality ?? 0.9)),
                                               background: settings.imageBackground ?? .white)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 280),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "转换为 " + format.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        let status = NSTextField(labelWithString: "正在转换…")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 588, height: 180))
        text.isEditable = false
        text.isSelectable = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 10, height: 10)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelJob(_:)))
        let stack = NSStackView(views: [status, scroll, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let worker = Task.detached(priority: .userInitiated) { () -> [String] in
            var results: [String] = []
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { results.append("已取消，已导出的文件保留。"); break }
                await MainActor.run { status.stringValue = "\(index + 1) / \(urls.count) · \(url.lastPathComponent)" }
                do {
                    let output = try FileActions.withAuthorizedURL(url, settings: settings, rejectSymbolicLink: true) { source in
                        try ImageConversion.convert(source, to: format, options: options)
                    }
                    results.append("已导出  " + output.path)
                } catch is CancellationError {
                    results.append("已取消，已导出的文件保留。")
                    break
                } catch { results.append(url.lastPathComponent + " · " + error.localizedDescription) }
                let message = results.joined(separator: "\n")
                await MainActor.run { text.string = message }
            }
            return results
        }
        jobs[window] = Task {
            let results = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            text.string = results.joined(separator: "\n")
            status.stringValue = "转换结束"
            cancel.isEnabled = false
        }
    }

    func setIcons(_ urls: [URL], restore: Bool, settings: Settings, iconID: String? = nil,
                  removesCustomIcon: Bool = false) async throws {
        if let iconID, !settings.fileIconEnabled(iconID) { throw SuperMenuError.invalidTarget }
        let iconData = restore ? nil : try FileIconStore.image(iconID ?? settings.fileIconSelection ?? "blue").tiffRepresentation
        if !restore && iconData == nil { throw ToolboxError.message("无法读取所选图标。") }
        try await Task.detached(priority: .userInitiated) {
            let image = iconData.flatMap(NSImage.init(data:))
            var completed = 0
            var errors: [String] = []
            for url in urls {
                do {
                    try FileActions.withAuthorizedURL(url, settings: settings, rejectSymbolicLink: true) { target in
                        if let image { try FileIconStore.apply(image, to: target) }
                        else if removesCustomIcon { try FileIconStore.removeCustomIcon(target) }
                        else { try FileIconStore.restore(target) }
                    }
                    completed += 1
                } catch { errors.append(url.lastPathComponent + " · " + error.localizedDescription) }
            }
            if !errors.isEmpty { throw TransferNotice(lines: ["已完成 \(completed) 项，\(errors.count) 项失败。"] + Array(errors.prefix(8))) }
        }.value
    }

    @objc private func cancelJob(_ sender: NSButton) {
        if let window = sender.window { jobs[window]?.cancel() }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { jobs.removeValue(forKey: window)?.cancel() }
    }
}
