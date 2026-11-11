import AppKit

struct FileIconEntry: Codable, Identifiable {
    let id: String
    let name: String
    var isImported: Bool { UUID(uuidString: id) != nil }
}

enum FileIconLibrary {
    static let presets = [
        ("App", "App"), ("Apple", "Apple"), ("Book", "书本"), ("Calendar", "日历"), ("Cloud", "云端"),
        ("Excel", "Excel"), ("File", "文件"), ("Google", "谷歌"), ("Mac_OS1", "Mac OS1"), ("Mac_OS2", "Mac OS2"),
        ("Mac", "Mac"), ("Mail", "邮件"), ("Music", "音乐"), ("Pages", "Pages"), ("Picture", "图片"),
        ("PPT", "PPT"), ("QQ", "QQ"), ("Video", "视频"), ("WeChat", "微信"), ("Word", "Word"),
    ].map { FileIconEntry(id: $0.0, name: $0.1) }

    static func directory() throws -> URL {
        try SharedStore.directory().appendingPathComponent("FileIcons", isDirectory: true)
    }

    static func imported() throws -> [FileIconEntry] {
        let url = try directory().appendingPathComponent("Library.json")
        do {
            return try JSONDecoder().decode([FileIconEntry].self, from: Data(contentsOf: url))
                .filter(\.isImported)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    static func orderedEntries(settings: Settings, imported: [FileIconEntry]) -> [FileIconEntry] {
        let entries = presets + imported
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return ((settings.fileIconOrder ?? []) + entries.map(\.id))
            .filter { seen.insert($0).inserted }
            .compactMap { byID[$0] }
    }

    static func image(_ entry: FileIconEntry) -> NSImage? {
        if entry.isImported {
            guard let url = try? directory().appendingPathComponent(entry.id + ".png") else { return nil }
            return NSImage(contentsOf: url)
        }
        guard let url = Bundle.main.url(forResource: entry.id, withExtension: "png", subdirectory: "FileIconPresets") else {
            return defaultImages[entry.id]
        }
        return NSImage(contentsOf: url)
    }

    private static let defaultImages: [String: NSImage] = {
        let symbols = ["App": "app.fill", "Apple": "desktopcomputer", "Book": "book.fill", "Calendar": "calendar",
                       "Cloud": "cloud.fill", "Excel": "tablecells.fill", "File": "doc.text.fill", "Google": "globe",
                       "Mac_OS1": "moon.stars.fill", "Mac_OS2": "moon.fill", "Mac": "laptopcomputer",
                       "Mail": "envelope.fill", "Music": "music.note", "Pages": "pencil", "Picture": "photo.fill",
                       "PPT": "chart.bar.fill", "QQ": "bubble.left.fill", "Video": "play.rectangle.fill",
                       "WeChat": "bubble.left.and.bubble.right.fill", "Word": "doc.richtext"]
        var images: [String: NSImage] = [:]
        for entry in presets {
            let pixels = entry.id == "Mac" ? 64 : 128
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap),
                  let symbol = NSImage(systemSymbolName: symbols[entry.id] ?? "folder", accessibilityDescription: nil)
            else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let extent = CGFloat(pixels)
            (NSImage(named: NSImage.folderName) ?? NSImage()).draw(in: NSRect(x: 0, y: 0, width: extent, height: extent))
            let badge = NSRect(x: extent * 0.35, y: extent * 0.21, width: extent * 0.42, height: extent * 0.42)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: badge, xRadius: extent * 0.07, yRadius: extent * 0.07).fill()
            symbol.withSymbolConfiguration(.init(paletteColors: [.systemBlue]))?.draw(in: badge.insetBy(dx: extent * 0.06, dy: extent * 0.06))
            NSGraphicsContext.restoreGraphicsState()
            if let png = bitmap.representation(using: .png, properties: [:]), let image = NSImage(data: png) {
                images[entry.id] = image
            }
        }
        return images
    }()
}

extension Settings {
    var showsFileIconPreviews: Bool { showsFileIcons ?? true }

    func fileIconEnabled(_ id: String) -> Bool { !(disabledFileIcons ?? []).contains(id) }

    func fileIconTitle(_ entry: FileIconEntry) -> String {
        fileIconNames?[entry.id] ?? entry.name
    }
}
