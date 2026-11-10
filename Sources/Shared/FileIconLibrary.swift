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
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

extension Settings {
    var showsFileIconPreviews: Bool { showsFileIcons ?? true }

    func fileIconEnabled(_ id: String) -> Bool { !(disabledFileIcons ?? []).contains(id) }

    func fileIconTitle(_ entry: FileIconEntry) -> String {
        fileIconNames?[entry.id] ?? entry.name
    }
}
