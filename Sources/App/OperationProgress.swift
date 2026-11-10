import AppKit

@MainActor
final class OperationProgress: NSObject, NSWindowDelegate {
    private var cancelOperation: (() -> Void)?
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)

    static func run<T>(title: String, operation: @escaping @Sendable () throws -> T) async throws -> T {
        let panel = OperationProgress()
        panel.window.title = title
        panel.window.isReleasedWhenClosed = false
        panel.window.delegate = panel
        let label = NSTextField(labelWithString: title)
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        let cancel = NSButton(title: "取消", target: panel, action: #selector(cancelClicked))
        let stack = NSStackView(views: [label, indicator, cancel])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        indicator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.window.contentView = stack
        panel.window.center()
        panel.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        panel.cancelOperation = { worker.cancel() }
        defer {
            panel.cancelOperation = nil
            panel.window.delegate = nil
            panel.window.orderOut(nil)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    @objc private func cancelClicked() { cancelOperation?() }
    func windowWillClose(_ notification: Notification) { cancelOperation?() }
}
