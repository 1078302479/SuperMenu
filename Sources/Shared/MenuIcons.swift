import AppKit
import UniformTypeIdentifiers

enum MenuIcons {
    private static let actionNames: [FinderAction: String] = [
        .copyName: "copy-name",
        .copyPath: "copy-path",
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

    private static let originals: [String: NSImage] = {
        var icons: [String: NSImage] = [:]
        let additional = ["nav-general", "nav-templates", "nav-send", "nav-favorites", "nav-file-icons", "nav-toolbox", "text-baidu", "text-google", "text-qrCode"]
        let apps = ["Android Studio", "AppCode", "CLion", "CotEditor", "DataGrip", "Emacs", "GoLand", "HBuilderX", "Hyper", "IDEA", "iTerm2", "MarkText", "Obsidian", "PhpStorm", "PyCharm", "Rider", "RubyMine", "Sublime Merge", "Sublime Text", "Tabby", "Terminal", "Typora", "Visual Studio", "VSCode", "Warp", "WebStorm"].map { "app-" + $0 }
        for name in DocumentTemplate.allCases.map(\.rawValue) + ["new-file", "named-file"] + Array(actionNames.values) + additional + apps {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "TemplateIcons"),
                  let icon = NSImage(contentsOf: url), icon.isValid else { continue }
            icon.isTemplate = false
            icons[name] = icon
        }
        return icons
    }()

    static func referenceImage(named name: String, size: CGFloat) -> NSImage? {
        originals[name].map { sized($0, to: size) }
    }

    static func action(_ action: FinderAction, size: CGFloat) -> NSImage? {
        actionNames[action].flatMap { referenceImage(named: $0, size: size) }
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
        if let id = entry.bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return sized(NSWorkspace.shared.icon(forFile: url.path), to: size)
        }
        return nil
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

    private static func sized(_ source: NSImage, to size: CGFloat) -> NSImage {
        let icon = source.copy() as! NSImage
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}
