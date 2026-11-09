import Foundation

enum DocumentTemplate: String, Codable, CaseIterable, Identifiable {
    case text = "txt"
    case markdown = "md"
    case richText = "rtf"
    case xml

    var id: Self { self }

    var title: String {
        switch self {
        case .text: return "TXT"
        case .markdown: return "Markdown"
        case .richText: return "RTF"
        case .xml: return "XML"
        }
    }

    var fileStem: String {
        switch self {
        case .text: return "新建文本文档"
        case .markdown: return "新建 Markdown 文档"
        case .richText: return "新建富文本文档"
        case .xml: return "新建 XML 文档"
        }
    }

    var contents: Data {
        switch self {
        case .text, .markdown: return Data()
        case .richText: return Data(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs24\par}"#.utf8)
        case .xml: return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<document/>\n".utf8)
        }
    }
}
