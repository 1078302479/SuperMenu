import AppKit

extension NSAlert {
    @discardableResult
    func runLocalizedModal() -> NSApplication.ModalResponse {
        messageText = InterfaceText.current(messageText)
        informativeText = InterfaceText.current(informativeText)
        for button in buttons { button.title = InterfaceText.current(button.title) }
        return runModal()
    }
}
