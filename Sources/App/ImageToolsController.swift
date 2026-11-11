import AppKit

@MainActor
final class ImageToolsController: NSObject {
    func convert(_ urls: [URL], format: ImageFormat, settings: Settings) async throws {
        guard settings.enabledImageFormats?.contains(format) ?? true else { throw SuperMenuError.invalidTarget }
        let options = ImageConversion.Options(quality: min(1, max(0.1, settings.imageQuality ?? 0.9)),
                                               background: settings.imageBackground ?? .white)
        let scope = try ScopedSelection(urls, settings: settings)
        defer { withExtendedLifetime(scope) {} }
        let worker = Task.detached(priority: .userInitiated) { () throws -> [String] in
            var failures: [String] = []
            for url in scope.urls {
                try Task.checkCancellation()
                do {
                    try FileActions.withAuthorizedURL(url, settings: settings, rejectSymbolicLink: true) { source in
                        _ = try ImageConversion.convert(source, to: format, options: options)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append(url.lastPathComponent + " · " + error.localizedDescription)
                }
            }
            return failures
        }
        let failures = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        if !failures.isEmpty { throw TransferNotice(lines: failures) }
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

}
