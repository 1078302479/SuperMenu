import AppKit
import Carbon

enum ApplicationLaunchError: LocalizedError {
    case unavailable(String)
    case invalidApplication
    case terminalNeedsOneFolder
    case terminalTabUnavailable
    case automation(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let name): return "没有找到 \(name)。请先安装，或在应用列表中重新添加本地应用。"
        case .invalidApplication: return "应用书签失效或目标不是应用，请重新添加。"
        case .terminalNeedsOneFolder: return "终端操作一次只能打开一个文件或目录。"
        case .terminalTabUnavailable: return "无法调用终端的新标签页服务。请在「系统设置 → 键盘 → 键盘快捷键 → 服务」中启用「新建位于文件夹位置的终端标签页」，然后重试。"
        case .automation(let detail): return "终端自动化未完成。请检查系统设置中的自动化权限。\n\(detail)"
        }
    }
}

@MainActor
enum ApplicationLauncher {
    static func installedURL(for entry: ApplicationEntry) -> URL? {
        if let bookmark = entry.bookmark {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: FileAccessPolicy.bookmarkResolutionOptions,
                                     relativeTo: nil, bookmarkDataIsStale: &stale), !stale,
                  url.pathExtension.lowercased() == "app" else { return nil }
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() } }
            guard let actualID = Bundle(url: url)?.bundleIdentifier else { return nil }
            if let expectedID = entry.bundleIdentifier, actualID != expectedID { return nil }
            return url
        }
        for id in [entry.bundleID] + (entry.alternateBundleIdentifiers ?? []) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    static func open(entry: ApplicationEntry, urls: [URL], mode: TerminalOpenMode = .systemDefault) async throws {
        guard entry.enabled else { throw ApplicationLaunchError.unavailable(entry.title) }
        guard let app = installedURL(for: entry) else { throw ApplicationLaunchError.unavailable(entry.title) }
        let scope = entry.bookmark != nil && app.startAccessingSecurityScopedResource()
        defer { if scope { app.stopAccessingSecurityScopedResource() } }

        if entry.isTerminal {
            guard urls.count == 1, let item = urls.first else { throw ApplicationLaunchError.terminalNeedsOneFolder }
            let isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let directory = isDirectory ? item : item.deletingLastPathComponent()
            guard directory.isFileURL else { throw SuperMenuError.invalidTarget }
            if entry.bundleID == "com.apple.Terminal", mode == .newTab {
                try openTerminalTab(at: directory)
                return
            }
            if mode != .systemDefault {
                try executeTerminalScript(bundleID: entry.bundleID, directory: directory, mode: mode)
                return
            }
            try await workspaceOpen([directory], with: app)
            return
        }
        try await workspaceOpen(urls, with: app)
    }

    private static func openTerminalTab(at directory: URL) throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.writeObjects([directory as NSURL]),
              pasteboard.setPropertyList([directory.path], forType: .init("NSFilenamesPboardType")),
              pasteboard.setString(directory.path, forType: .string),
              NSPerformService("New Terminal Tab at Folder", pasteboard) else {
            throw ApplicationLaunchError.terminalTabUnavailable
        }
    }

    static func installedURL(for tool: ExternalToolKind) -> URL? {
        for id in tool.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        for root in [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            for name in tool.applicationNames {
                let app = root.appendingPathComponent(name + ".app")
                if FileManager.default.fileExists(atPath: app.path), Bundle(url: app)?.bundleIdentifier != nil { return app }
            }
        }
        return nil
    }

    // No undocumented task URL is sent. The receiving application owns the next operation.
    static func openTool(_ tool: ExternalToolKind, urls: [URL] = []) async throws {
        guard let app = installedURL(for: tool) else { throw ApplicationLaunchError.unavailable(tool.title) }
        if tool == .fastZip, !urls.isEmpty {
            try await workspaceOpen(urls, with: app)
        } else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }

    private static func workspaceOpen(_ urls: [URL], with app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private static func executeTerminalScript(bundleID: String, directory: URL, mode: TerminalOpenMode) throws {
        let source = terminalScript(bundleID: bundleID, mode: mode)
        guard let script = NSAppleScript(source: source) else { throw ApplicationLaunchError.automation("无法创建脚本。") }
        // Paths travel as Apple event parameters. AppleScript's quoted form produces the shell argument.
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                           eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "openAt"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: directory.path), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        var details: NSDictionary?
        _ = script.executeAppleEvent(event, error: &details)
        if let details {
            throw ApplicationLaunchError.automation(details[NSAppleScript.errorMessage] as? String ?? details.description)
        }
    }

    // Only fixed application identifiers and fixed scripts are emitted here.
    static func terminalScript(bundleID: String, mode: TerminalOpenMode) -> String {
        if bundleID == "com.googlecode.iterm2" {
            let create = mode == .newTab
                ? """
                if (count of windows) is 0 then
                    set newWindow to (create window with default profile)
                    set targetSession to current session of newWindow
                else
                    tell current window
                        set newTab to (create tab with default profile)
                        set targetSession to current session of newTab
                    end tell
                end if
                """
                : """
                set newWindow to (create window with default profile)
                set targetSession to current session of newWindow
                """
            return """
            on openAt(thePath)
                set shellCommand to "cd -- " & quoted form of thePath
                tell application id "com.googlecode.iterm2"
                    activate
                    \(create)
                    tell targetSession to write text shellCommand
                end tell
            end openAt
            """
        }
        return """
        on openAt(thePath)
            set shellCommand to "cd -- " & quoted form of thePath
            tell application id "com.apple.Terminal"
                activate
                do script shellCommand
            end tell
        end openAt
        """
    }
}
