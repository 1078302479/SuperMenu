import AppKit

@MainActor
final class DeleteConfirmation: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    init(count: Int) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 508, height: 254),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 508, height: 254))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView = view
        let icon = NSImageView(frame: NSRect(x: 31, y: 191, width: 26, height: 29))
        icon.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        view.addSubview(icon)
        func label(_ text: String, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
            let field = NSTextField(wrappingLabelWithString: InterfaceText.current(text))
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.frame = NSRect(x: 77, y: y, width: 399, height: 38)
            view.addSubview(field)
        }
        label("彻底删除 \(count) 个项目？", y: 183, size: 21, color: .labelColor, weight: .semibold)
        label("所选项目将永久删除，此操作无法撤销。", y: 139, size: 13, color: .secondaryLabelColor)
        label("文件不会移入废纸篓。", y: 113, size: 12, color: .tertiaryLabelColor)
        let cancel = NSButton(title: InterfaceText.current("取消"), target: self, action: #selector(cancelAction))
        cancel.frame = NSRect(x: 251, y: 32, width: 96, height: 35)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\r"
        view.addSubview(cancel)
        let delete = NSButton(title: InterfaceText.current("彻底删除"), target: self, action: #selector(deleteAction))
        delete.frame = NSRect(x: 359, y: 32, width: 117, height: 35)
        delete.bezelStyle = .rounded
        delete.bezelColor = .systemRed
        delete.contentTintColor = .white
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        view.addSubview(delete)
        panel.defaultButtonCell = cancel.cell as? NSButtonCell
    }
    @objc private func cancelAction() { NSApp.stopModal(withCode: .cancel) }
    @objc private func deleteAction() { NSApp.stopModal(withCode: .OK) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelAction(); return false }
    static func confirm(urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let dialog = DeleteConfirmation(count: urls.count)
        NSApp.activate(ignoringOtherApps: true)
        dialog.panel.center()
        dialog.panel.makeKeyAndOrderFront(nil)
        let result = NSApp.runModal(for: dialog.panel)
        dialog.panel.orderOut(nil)
        return result == .OK
    }
}
