import AppKit
import CoreImage
import ImageIO

enum TextServiceTools {
    enum TranslationProvider { case baidu, google }

    static func translationURL(_ text: String, provider: TranslationProvider) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 20_000 else {
            throw ToolboxError.message("请输入要翻译的文字，长度不超过 20000 字节。")
        }
        var components = URLComponents()
        components.scheme = "https"
        switch provider {
        case .baidu:
            components.host = "fanyi.baidu.com"
            components.path = "/mtpe-individual/multimodal"
            components.queryItems = [URLQueryItem(name: "query", value: text),
                                     URLQueryItem(name: "lang", value: "auto2zh")]
        case .google:
            components.host = "translate.google.com"
            components.path = "/"
            components.queryItems = [URLQueryItem(name: "sl", value: "auto"),
                                     URLQueryItem(name: "tl", value: "zh-CN"),
                                     URLQueryItem(name: "text", value: text),
                                     URLQueryItem(name: "op", value: "translate")]
        }
        guard let url = components.url else { throw SuperMenuError.invalidTarget }
        return url
    }

    static func qrCodePNG(_ text: String) throws -> Data {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= 2_000 else {
            throw ToolboxError.message("请输入要生成二维码的文字，长度不超过 2000 字节。")
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw ToolboxError.message("系统未提供二维码生成器。")
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { throw ToolboxError.message("二维码生成失败。") }
        let scale = max(1, floor(768 / (output.extent.width + 8)))
        let code = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let border = 4 * scale
        let rect = CGRect(x: -border, y: -border, width: code.extent.width + border * 2,
                          height: code.extent.height + border * 2)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect)
        let image = code.composited(over: white)
        guard let raster = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: rect) else {
            throw ToolboxError.message("二维码图片生成失败。")
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
            throw ToolboxError.message("无法导出二维码。")
        }
        CGImageDestinationAddImage(destination, raster, nil)
        guard CGImageDestinationFinalize(destination) else { throw ToolboxError.message("二维码编码失败。") }
        return encoded as Data
    }
}

@MainActor
final class TextServices: NSObject, NSWindowDelegate {
    private var qrWindows: [NSWindow: Data] = [:]

    @objc func translateWithBaidu(_ pasteboard: NSPasteboard, userData: String?,
                                  error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(pasteboard, error: error) { try translate($0, provider: .baidu) }
    }

    @objc func translateWithGoogle(_ pasteboard: NSPasteboard, userData: String?,
                                   error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(pasteboard, error: error) { try translate($0, provider: .google) }
    }

    @objc func generateQRCode(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(pasteboard, error: error) { text in
            let data = try TextServiceTools.qrCodePNG(text)
            try Self.copyQRCode(data, to: .general)
            try showQRCode(data)
        }
    }

    private func showQRCode(_ data: Data) throws {
        guard let image = NSImage(data: data) else { throw ToolboxError.message("二维码图片无法读取。") }
        let preview = NSImageView(image: image)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.widthAnchor.constraint(equalToConstant: 400).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 400).isActive = true
        let copy = NSButton(title: "拷贝 PNG", target: self, action: #selector(copyQRCode(_:)))
        let save = NSButton(title: "保存 PNG…", target: self, action: #selector(saveQRCode(_:)))
        let buttons = NSStackView(views: [copy, save])
        buttons.spacing = 12
        let content = NSStackView(views: [preview, buttons])
        content.orientation = .vertical
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 436, height: 478),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "文字二维码"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.delegate = self
        qrWindows[window] = data
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func translate(_ text: String, provider: TextServiceTools.TranslationProvider) throws {
        guard NSWorkspace.shared.open(try TextServiceTools.translationURL(text, provider: provider)) else {
            throw ToolboxError.message("无法打开翻译网站。")
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { qrWindows.removeValue(forKey: window) }
    }

    private func receive(_ pasteboard: NSPasteboard, error: AutoreleasingUnsafeMutablePointer<NSString?>,
                         operation: (String) throws -> Void) {
        do {
            guard let text = pasteboard.string(forType: .string) else {
                throw ToolboxError.message("系统服务没有收到文字。")
            }
            try operation(text)
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
        }
    }

    @objc private func copyQRCode(_ sender: NSButton) {
        guard let window = sender.window, let data = qrWindows[window] else { return }
        do { try Self.copyQRCode(data, to: .general) }
        catch { showError(error) }
    }

    static func copyQRCode(_ data: Data, to pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            throw ToolboxError.message("无法将二维码写入剪贴板。")
        }
    }

    @objc private func saveQRCode(_ sender: NSButton) {
        guard let window = sender.window, let data = qrWindows[window] else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "二维码.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do { try data.write(to: url, options: .atomic) }
        catch { showError(error) }
    }

    private func showError(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}
