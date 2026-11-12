import AppKit
import FinderSync

enum FinderExtensionPermission {
    static let identifier = "io.github.1078302479.SuperMenu.Finder"

    static func enabledRegistration(in output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2, columns[0] == "+" else { return false }
            return columns[1].split(separator: "(").first.map(String.init) == identifier
        }
    }

    @MainActor static func isEnabled() async -> Bool? {
        let registered: Bool? = await Task.detached(priority: .userInitiated) {
            guard let data = PermissionProcess.output(executable: URL(fileURLWithPath: "/usr/bin/pluginkit"),
                                                      arguments: ["-m", "-i", identifier]) else { return nil }
            return enabledRegistration(in: String(decoding: data, as: UTF8.self))
        }.value
        return registered
    }
}
