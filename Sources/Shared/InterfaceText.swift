import Foundation

enum InterfaceText {
    private static let english: [String: String] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("en.lproj/Localizable.strings"),
              let strings = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return strings
    }()
    /// Whole-message templates preserve filenames, paths and nested error text.
    /// Never translate fragments inside user data or rewrite custom menu names.
    static func english(_ text: String) -> String {
        if let value = english[text] { return value }
        for key in english.keys.filter({ $0.contains("%@") }).sorted() {
            let parts = key.components(separatedBy: "%@")
            let pattern = "\\A" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "([\\s\\S]*?)") + "\\z"
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let translation = english[key] else { continue }
            let output = translation.components(separatedBy: "%@")
            guard output.count == parts.count else { continue }
            var result = output[0]
            for index in 1..<output.count {
                guard let range = Range(match.range(at: index), in: text) else { return text }
                result += String(text[range]) + output[index]
            }
            return result
        }
        return text
    }
}

extension FinderAction {
    var englishTitle: String { InterfaceText.english(title) }
}

extension InterfaceText {
    static func current(_ text: String) -> String {
        let language = (try? SharedStore.load().interfaceLanguage) ?? .system
        guard language.usesEnglish else { return text }
        return english(text)
    }
}
