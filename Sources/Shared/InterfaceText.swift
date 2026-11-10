import Foundation

enum InterfaceText {
    private static let english: [String: String] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("en.lproj/Localizable.strings"),
              let strings = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return strings
    }()
    static func english(_ text: String) -> String { english[text] ?? text }
}

extension FinderAction {
    var englishTitle: String { InterfaceText.english(title) }
}
