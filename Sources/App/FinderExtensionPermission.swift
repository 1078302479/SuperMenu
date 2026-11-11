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
        if FIFinderSyncController.isExtensionEnabled { return true }
        let registered: Bool? = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            process.arguments = ["-m", "-A", "-D", "-i", identifier]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return enabledRegistration(in: String(decoding: data, as: UTF8.self))
            } catch { return nil }
        }.value
        if FIFinderSyncController.isExtensionEnabled { return true }
        return registered
    }
}
