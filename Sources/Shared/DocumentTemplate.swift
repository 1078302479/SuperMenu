import Foundation

struct CustomTemplate: Codable, Identifiable {
    let id: Int
    let fileName: String
    var enabled = true
    var displayName: String?
    var showsInMainMenu: Bool?

    var title: String { displayName ?? fileName }
    var fileExtension: String { (fileName as NSString).pathExtension }
}

struct CustomTemplateLibrary: Codable {
    var entries: [CustomTemplate] = []
    // Menu items can outlive an edit to the library. Never reuse their identifiers.
    var nextID = 1

    func enabledTemplate(id: Int) throws -> CustomTemplate {
        guard id > 0, let template = entries.first(where: { $0.id == id && $0.enabled }) else {
            throw SuperMenuError.templateDisabled
        }
        return template
    }

    mutating func renameTemplate(id: Int, to title: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].displayName = name.isEmpty || name == entries[index].fileName ? nil : name
    }

    mutating func moveTemplate(id: Int, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index + offset) else { return }
        entries.insert(entries.remove(at: index), at: index + offset)
    }

    mutating func moveTemplate(id: Int, to target: Int) {
        guard let source = entries.firstIndex(where: { $0.id == id }),
              let destination = entries.firstIndex(where: { $0.id == target }), source != destination else { return }
        moveTemplate(id: id, by: destination - source)
    }
}

struct NamedDocument {
    static let title = "自定义创建新文件"
    let fileName: String
    let template: DocumentTemplate?

    init(_ input: String) throws {
        let name = input.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw SuperMenuError.invalidFileName }
        let template = DocumentTemplate(rawValue: (name as NSString).pathExtension.lowercased())
        if template?.isAvailable == false { throw SuperMenuError.templateResourceMissing }
        fileName = name
        self.template = template
    }
}

enum DocumentTemplate: String, Codable, CaseIterable, Identifiable {
    case text = "txt"
    case richText = "rtf"
    case xml
    case word = "docx"
    case excel = "xlsx"
    case powerpoint = "pptx"
    case wps
    case wpsSheet = "et"
    case wpsSlides = "dps"
    case pages, numbers
    case keynote = "key"
    case illustrator = "ai"
    case photoshop = "psd"
    case markdown = "md"

    var id: Self { self }

    var title: String {
        switch self {
        case .text: return "TXT"
        case .markdown: return "Markdown"
        case .richText: return "RTF"
        case .xml: return "XML"
        case .word: return "Word"
        case .excel: return "Excel"
        case .powerpoint: return "PPT"
        case .wps: return "WPS 文字"
        case .wpsSheet: return "WPS 表格"
        case .wpsSlides: return "WPS 演示"
        case .pages: return "Pages"
        case .numbers: return "Numbers"
        case .keynote: return "Keynote"
        case .illustrator: return "AI"
        case .photoshop: return "PSD"
        }
    }

    var fileStem: String {
        switch self {
        case .text: return "新建文本文档"
        case .markdown: return "新建 Markdown 文档"
        case .richText: return "新建富文本文档"
        case .xml: return "新建 XML 文档"
        default: return "新建 \(title) 文档"
        }
    }

    private static let bundledFormats = Set(Bundle.main.object(forInfoDictionaryKey: "SuperMenuBundledTemplates") as? [String] ?? [])

    var isAvailable: Bool {
        switch self {
        case .text, .markdown, .richText, .xml: return true
        default: return Self.bundledFormats.contains(rawValue)
        }
    }

    // Existing Finder menu requests keep the same identifiers if the list is reordered.
    var menuTag: Int {
        switch self {
        case .text: return 1
        case .richText: return 2
        case .xml: return 3
        case .word: return 4
        case .excel: return 5
        case .powerpoint: return 6
        case .wps: return 7
        case .wpsSheet: return 8
        case .wpsSlides: return 9
        case .pages: return 10
        case .numbers: return 11
        case .keynote: return 12
        case .illustrator: return 13
        case .photoshop: return 14
        case .markdown: return 15
        }
    }

    func contents() throws -> Data {
        switch self {
        case .text, .markdown: return Data()
        case .richText: return Data(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs24\par}"#.utf8)
        case .xml: return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<document/>\n".utf8)
        default:
            guard let url = Bundle.main.url(forResource: "blank", withExtension: rawValue, subdirectory: "Templates") else {
                throw SuperMenuError.templateResourceMissing
            }
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { throw SuperMenuError.templateResourceMissing }
            return data
        }
    }
}
