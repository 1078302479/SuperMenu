import AppKit
import CArchive
import Darwin

struct PreparedUpdate {
    let app: URL
    let version: String
    let directory: URL
}

enum UpdateInstaller {
    static let appID = "io.github.1078302479.SuperMenu"

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolboxError.message("更新文件验证或准备失败（\(process.terminationStatus)）。") }
    }

    static func validateArchive(_ url: URL) throws {
        guard let reader = archive_read_new() else { throw SuperMenuError.invalidTarget }
        defer { archive_read_free(reader) }
        archive_read_support_format_zip(reader)
        guard archive_read_open_filename(reader, url.path, 65536) == 0 else { throw SuperMenuError.invalidTarget }
        var entry: OpaquePointer?
        var count = 0
        var bytes: Int64 = 0
        while true {
            let result = archive_read_next_header(reader, &entry)
            if result == 1 { break }
            guard result == 0, let entry, let raw = archive_entry_pathname(entry) else { throw SuperMenuError.invalidTarget }
            let name = String(cString: raw)
            let parts = name.split(separator: "/", omittingEmptySubsequences: true)
            let kind = archive_entry_filetype(entry) & mode_t(S_IFMT)
            let size = archive_entry_size(entry)
            guard !name.hasPrefix("/"), !name.contains("\\"), !parts.contains(".."), !parts.contains("."),
                  parts.first == "增强右键.app" || parts.first == "__MACOSX",
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
                  kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR), size >= 0, size <= 250_000_000 else {
                throw ToolboxError.message("更新压缩包包含不允许的路径或文件类型。")
            }
            count += 1
            bytes += size
            guard count <= 10_000, bytes <= 500_000_000 else { throw ToolboxError.message("更新压缩包超出大小限制。") }
            guard archive_read_data_skip(reader) == 0 else { throw SuperMenuError.invalidTarget }
        }
        guard count > 0 else { throw SuperMenuError.invalidTarget }
    }

    static func validateApp(_ app: URL, expectedVersion: String) throws {
        let manager = FileManager.default
        let resources: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = manager.enumerator(at: app, includingPropertiesForKeys: resources) else { throw SuperMenuError.invalidTarget }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(resources))
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw ToolboxError.message("更新应用中包含不支持的链接或特殊文件。")
            }
        }
        for (bundle, identifier) in [(app, appID), (app.appendingPathComponent("Contents/PlugIns/SuperMenuFinder.appex"), appID + ".Finder")] {
            let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
            guard info?["CFBundleIdentifier"] as? String == identifier,
                  info?["CFBundleShortVersionString"] as? String == expectedVersion,
                  info?["SuperMenuLocalStorage"] == nil,
                  info?["SuperMenuHomeRelativeStorage"] as? String == "/Library/Application Support/" + appID,
                  let formats = info?["SuperMenuBundledTemplates"] as? [String],
                  Set(formats) == Set(["docx", "xlsx", "pptx", "wps", "et", "dps", "pages", "numbers", "key", "ai", "psd"]) else {
                throw ToolboxError.message("更新应用的标识、版本、配置目录或模板清单不正确。")
            }
            for format in formats {
                let seed = bundle.appendingPathComponent("Contents/Resources/Templates/blank.\(format)")
                guard (try seed.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 0 else { throw SuperMenuError.templateResourceMissing }
            }
            for name in ["new-file", "copy-path", "copy-to", "move-to", "app-Terminal", "convert-image"] {
                guard manager.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/TemplateIcons/\(name).png").path) else {
                    throw ToolboxError.message("更新应用缺少菜单图标。")
                }
            }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    static func prepare(archive: URL, version: String, directory: URL) throws -> PreparedUpdate {
        try validateArchive(archive)
        let expanded = directory.appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: false)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
        let app = expanded.appendingPathComponent("增强右键.app", isDirectory: true)
        try validateApp(app, expectedVersion: version)
        return PreparedUpdate(app: app, version: version, directory: directory)
    }

    /// Returns a detached helper; the caller quits only after successfully launching it.
    /// All paths are arguments, never interpolated shell code. The user's settings live outside the app.
    static func install(_ update: PreparedUpdate, replacing current: URL = Bundle.main.bundleURL) throws {
        let manager = FileManager.default
        let parent = current.deletingLastPathComponent()
        guard current.pathExtension == "app", manager.isWritableFile(atPath: parent.path),
              (try current.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw ToolboxError.message("应用所在目录不可写，请使用「查看安装文件」手动替换。")
        }
        guard Bundle(url: current)?.bundleIdentifier == appID else { throw SuperMenuError.invalidTarget }
        try validateApp(update.app, expectedVersion: update.version)
        let staged = parent.appendingPathComponent(".EnhancedRightClick-update-\(UUID().uuidString).bundle")
        let backup = parent.appendingPathComponent(".EnhancedRightClick-backup-\(UUID().uuidString).bundle")
        do {
            try run("/usr/bin/ditto", [update.app.path, staged.path])
            try validateApp(staged, expectedVersion: update.version)
            let script = update.directory.appendingPathComponent("install.sh")
            let text = """
            #!/bin/sh
            set -eu
            host_pid="$1"
            current_app="$2"
            staged_app="$3"
            backup_app="$4"
            counter=0
            while kill -0 "$host_pid" 2>/dev/null; do
                counter=$((counter + 1))
                if [ "$counter" -gt 60 ]; then exit 1; fi
                sleep 1
            done
            /usr/bin/codesign --verify --deep --strict "$staged_app"
            /bin/mv "$current_app" "$backup_app"
            if ! /bin/mv "$staged_app" "$current_app"; then
                /bin/mv "$backup_app" "$current_app"
                /usr/bin/open -g "$current_app"
                exit 1
            fi
            /usr/bin/pluginkit -a "$current_app/Contents/PlugIns/SuperMenuFinder.appex" || true
            if ! /usr/bin/open "$current_app"; then
                /bin/mv "$current_app" "$staged_app"
                /bin/mv "$backup_app" "$current_app"
                /usr/bin/open "$current_app"
                exit 1
            fi
            """
            try text.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, String(getpid()), current.path, staged.path, backup.path]
            let log = update.directory.appendingPathComponent("install.log")
            manager.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            process.standardOutput = handle
            process.standardError = handle
            process.standardInput = FileHandle.nullDevice
            try process.run()
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }
}
