import AppKit
import UniformTypeIdentifiers

enum MenuIcons {
    private static let actionNames: [FinderAction: String] = [
        .copyName: "copy-name",
        .copyPath: "copy-path",
        .copyToFolder: "copy-to",
        .moveToFolder: "move-to",
        .folderFromName: "folder-from-name",
        .openTerminal: "app-Terminal",
        .openFavorite: "nav-favorites",
        .cut: "cut",
        .addFavorite: "add-favorite",
        .fileInfo: "file-info",
        .deletePermanently: "delete",
        .hideSelected: "hide",
        .showSelected: "show",
        .showHiddenFiles: "show",
        .hideHiddenFiles: "hide",
        .toggleExtension: "extension",
        .repairNames: "repair-name",
        .desktopAlias: "desktop-alias",
        .airDrop: "airdrop",
        .convertImage: "convert-image",
        .setFileIcon: "file-icon",
        .restoreFileIcon: "file-icon",
        .dissolveFolder: "dissolve",
        .setWallpaper: "wallpaper",
        .grantWrite: "grant-write",
        .iShotCapture: "ishot",
        .iShotAnnotate: "ishot",
        .compressZIP: "fastzip",
        .compress7z: "fastzip",
        .extractArchive: "fastzip",
        .openFastZip: "fastzip",
        .diskMap: "diskmap",
    ]

    private static let specifications: [(String, String, NSColor)] = [
        ("new-file", "doc.badge.plus", .systemCyan), ("named-file", "doc.badge.plus", .systemCyan),
        ("copy-name", "doc.text", .systemCyan), ("copy-path", "link", .systemGreen),
        ("copy-to", "doc.on.doc.fill", .systemGreen), ("move-to", "folder.fill", .systemBlue),
        ("folder-from-name", "folder.badge.plus", .systemBlue), ("cut", "scissors", .systemCyan),
        ("add-favorite", "heart.fill", .systemPink), ("nav-favorites", "heart.fill", .systemPink),
        ("file-info", "info", .systemBlue), ("delete", "trash", .systemRed),
        ("hide", "eye.slash.fill", .darkGray), ("show", "eye.fill", .darkGray),
        ("extension", "textformat", .systemBlue), ("repair-name", "character.cursor.ibeam", .systemTeal),
        ("desktop-alias", "arrow.up.forward", .darkGray), ("airdrop", "airplayaudio", .systemBlue),
        ("convert-image", "photo", .systemGreen), ("file-icon", "folder.fill", .systemOrange),
        ("dissolve", "folder.badge.minus", .systemCyan), ("wallpaper", "display", .systemCyan),
        ("grant-write", "lock.open.fill", .systemOrange), ("ishot", "photo.fill", .systemGreen),
        ("fastzip", "archivebox.fill", .systemOrange), ("diskmap", "chart.pie.fill", .systemPurple),
        ("nav-general", "gearshape.fill", .systemCyan), ("nav-templates", "doc.badge.plus", .systemCyan),
        ("nav-send", "doc.on.doc.fill", .systemGreen), ("nav-file-icons", "folder.fill", .systemOrange),
        ("nav-toolbox", "square.grid.2x2.fill", .systemPink), ("text-baidu", "character.bubble.fill", .systemBlue),
        ("text-google", "character.bubble.fill", .systemGreen), ("text-qrCode", "qrcode", .darkGray),
    ]

    private static func coloredIcon(named name: String) -> NSImage? {
        guard let (_, symbol, color) = specifications.first(where: { $0.0 == name }) else { return nil }
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 38, weight: .medium)) else {
            return nil
        }
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { _ in
            let tile = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 60, height: 60), xRadius: 13, yRadius: 13)
            NSColor.white.setFill()
            tile.fill()
            NSColor(white: 0.86, alpha: 1).setStroke()
            tile.lineWidth = 1
            tile.stroke()
            let tinted = NSImage(size: glyph.size, flipped: false) { bounds in
                glyph.draw(in: bounds)
                color.setFill()
                bounds.fill(using: .sourceIn)
                return true
            }
            let scale = min(42 / glyph.size.width, 42 / glyph.size.height)
            let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
            tinted.draw(in: NSRect(x: (64 - size.width) / 2, y: (64 - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        return image.tiffRepresentation.flatMap(NSImage.init(data:))
    }

    // Load only the icon requested by this menu instead of decoding the whole library
    // during the first Finder callback.
    private static var originals: [String: NSImage] = [:]
    private static let iconLock = NSLock()

    static func referenceImage(named name: String, size: CGFloat) -> NSImage? {
        iconLock.lock()
        defer { iconLock.unlock() }
        if let cached = originals[name] { return sized(cached, to: size) }
        let bundled = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "TemplateIcons")
            .flatMap { NSImage(contentsOf: $0) }
        guard let icon = bundled ?? coloredIcon(named: name), icon.isValid else { return nil }
        icon.isTemplate = false
        originals[name] = icon
        return sized(icon, to: size)
    }

    static func action(_ action: FinderAction, size: CGFloat) -> NSImage? {
        if action == .openTerminal {
            return application(ApplicationEntry(id: "com.apple.Terminal", name: "终端"), size: size)
        }
        return actionNames[action].flatMap { referenceImage(named: $0, size: size) }
    }

    static func folder(at url: URL) -> NSImage {
        let standard = ["Downloads": "DownloadsFolder", "Pictures": "PicturesFolderIcon", "Music": "MusicFolderIcon", "Movies": "MovieFolderIcon", "Documents": "DocumentsFolderIcon"]
        if url.deletingLastPathComponent().standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
           let resource = standard[url.lastPathComponent],
           let coreTypes = Bundle(path: "/System/Library/CoreServices/CoreTypes.bundle"),
           let iconURL = coreTypes.url(forResource: resource, withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) { return image }
        if FileManager.default.fileExists(atPath: url.path) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(named: NSImage.folderName) ?? NSImage()
    }

    static func application(_ entry: ApplicationEntry, size: CGFloat) -> NSImage? {
        let aliases = ["终端": "Terminal", "Visual Studio Code": "VSCode", "VS Code Insiders": "VSCode", "IntelliJ IDEA": "IDEA"]
        if let icon = referenceImage(named: "app-" + (aliases[entry.name] ?? entry.name), size: size) { return icon }
        for id in [entry.bundleID] + (entry.alternateBundleIdentifiers ?? []) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            return sized(NSWorkspace.shared.icon(forFile: url.path), to: size)
        }
        if entry.bundleID == "com.apple.Terminal" {
            return sized(NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app"), to: size)
        }
        return sized(NSWorkspace.shared.icon(for: .applicationBundle), to: size)
    }

    static func document(extension ext: String, size: CGFloat) -> NSImage {
        let ext = ext.lowercased()
        if let icon = referenceImage(named: ext, size: size) { return icon }
        return sized(NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data), to: size)
    }

    static func newFile(size: CGFloat) -> NSImage? {
        referenceImage(named: "new-file", size: size)
            ?? NSImage(systemSymbolName: FinderAction.newText.symbol, accessibilityDescription: nil)
    }

    static func namedFile(size: CGFloat) -> NSImage {
        referenceImage(named: "named-file", size: size) ?? document(extension: "", size: size)
    }

    /// Keep the Finder XPC payload independent of the source icon's 512/1024px
    /// representations and lazy Icon Services providers. Logical size alone does
    /// not resize NSImage's underlying representations.
    static func prepareForFinder(_ menu: NSMenu) {
        for item in menu.items {
            if let source = item.image {
                item.image = finderImage(source)
                // macOS 27 hides action images by default, including non-symbol
                // bitmaps. Request visibility without overriding the user's
                // per-category icon settings (nil images stay nil).
                if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            }
            if let submenu = item.submenu { prepareForFinder(submenu) }
        }
    }

    static func finderImage(_ source: NSImage) -> NSImage {
        let points: CGFloat = 16
        let pixels = 32
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return sized(source, to: points)
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.scaleBy(x: 2, y: 2)
        source.draw(in: NSRect(x: 0, y: 0, width: points, height: points), from: .zero,
                    operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.current = previous
        bitmap.size = NSSize(width: points, height: points)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        image.isTemplate = source.isTemplate
        return image
    }

    private static func sized(_ source: NSImage, to size: CGFloat) -> NSImage {
        let icon = source.copy() as! NSImage
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}
