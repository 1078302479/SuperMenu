import AppKit
import Darwin
import ImageIO
import SwiftUI
import Vision
import CArchive

enum SmokeError: Error {
    case unexpectedRequest, unexpectedResult, timedOut
}

@MainActor
final class Receiver: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(1) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        do {
            guard let url = urls.first, let request = try SharedStore.consume(url),
                  request.action == .newText, let id = request.customTemplateID, request.paths.count == 1 else {
                throw SmokeError.unexpectedRequest
            }
            let fixture = try SharedStore.directory().appendingPathComponent("fixture", isDirectory: true)
            guard request.paths == [fixture.path] else { throw SmokeError.unexpectedRequest }
            guard let library = try SharedStore.load().customTemplates else { throw SmokeError.unexpectedRequest }
            let output = try TemplateStore.createDocument(from: library.enabledTemplate(id: id), in: fixture)
            let replay = try SharedStore.consume(url)
            guard replay == nil else { throw SmokeError.unexpectedRequest }
            try Data(output.lastPathComponent.utf8).write(to: fixture.appendingPathComponent("result"), options: .atomic)
            exit(0)
        } catch {
            if let root = try? SharedStore.directory() {
                try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("failure"))
            }
            exit(1)
        }
    }
}

@main
struct BackgroundHandoffSmoke {
    @MainActor static func main() async {
        if CommandLine.arguments.last == "--direct-access" {
            do { try await verifyDirectAccess() }
            catch {
                FileHandle.standardError.write(Data("Direct access: \(error)\n".utf8))
                exit(1)
            }
            return
        }
        if CommandLine.arguments.count == 2 {
            let app = URL(fileURLWithPath: CommandLine.arguments[1])
            do {
                try await verifyCutAndPaste()
                try await verifyToolboxCancellation()
                try verifyTextServicesAndArchives()
                try send(to: app)
            }
            catch {
                FileHandle.standardError.write(Data("Background handoff: \(error)\n".utf8))
                exit(1)
            }
            return
        }

        let app = NSApplication.shared
        let delegate = Receiver()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
    }

    @MainActor private static func verifyDirectAccess() async throws {
        guard FileAccessPolicy.usesDirectAccess else { throw ToolboxError.message("direct flag missing") }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("SuperMenu-direct-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture) }
        if let metadata = ProcessInfo.processInfo.environment["SUPERMENU_TEST_LIVE_RELEASE"] {
            let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(contentsOf: URL(fileURLWithPath: metadata)))
            let package = try UpdatePackage(release: release, architecture: UpdateChecker.architecture)
            let cancelled = Task {
                try Task.checkCancellation()
                return try await UpdateDownload().download(package.archive, to: fixture.appendingPathComponent("cancelled.zip")) { _ in }
            }
            cancelled.cancel()
            do { _ = try await cancelled.value; throw SmokeError.unexpectedResult }
            catch is CancellationError {} catch { throw error }
            let archive = try await UpdateDownload().download(package.archive, to: fixture.appendingPathComponent("live.zip")) { _ in }
            let (checksums, response) = try await URLSession.shared.data(from: package.checksums.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try UpdatePackage.hash(of: archive) == package.expectedHash(in: checksums) else { throw SmokeError.unexpectedResult }
            let prepared = try UpdateInstaller.prepare(archive: archive, version: String(release.tag_name.dropFirst()), directory: fixture)
            guard fm.fileExists(atPath: prepared.app.path) else { throw SmokeError.unexpectedResult }
            print("PASS: live GitHub release download, cancellation, SHA256 manifest and signed package extraction")
        }
        var settings = Settings()
        settings.showsCut = true
        try SharedStore.save(settings)
        // No stored directory grants, and the fixture is outside the shared-config directory.
        let created = try FileActions.withAuthorizedURL(fixture, settings: settings) {
            try FileActions.createDocument(named: "直达.txt", contents: Data("hello".utf8), in: $0)
        }
        let lease = try ScopedSelection([created], settings: settings)
        guard lease.urls == [created.resolvingSymlinksInPath()], settings.folders.isEmpty,
              try Data(contentsOf: created) == Data("hello".utf8) else { throw ToolboxError.message("direct create/read mismatch: \(lease.urls) / \(created)") }
        let bookmark = try created.bookmarkData(options: FileAccessPolicy.bookmarkCreationOptions,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        let restored = try URL(resolvingBookmarkData: bookmark, options: FileAccessPolicy.bookmarkResolutionOptions,
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        guard restored.resolvingSymlinksInPath() == created.resolvingSymlinksInPath(), !stale else { throw SmokeError.unexpectedResult }
        var favorites = SavedFolders()
        favorites.add(path: fixture.path)
        settings.favorites = favorites
        guard settings.availableFavorites.count == 1 else { throw SmokeError.unexpectedResult }
        let transfer = CutTransfer()
        try await transfer.cut([created])
        guard try CutState.load()?.items.count == 1 else { throw ToolboxError.message("direct cut mismatch") }
        // Scope checks apply to resolved targets, including symlinks into another disk.
        let external = URL(fileURLWithPath: "/Volumes/SuperMenuScopeFixture/item")
        guard !FileAccessPolicy.allows(external, settings: settings) else { throw ToolboxError.message("system scope allows external") }
        let link = fixture.appendingPathComponent("external")
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/Volumes"))
        guard !FileAccessPolicy.allows(link.appendingPathComponent("item"), settings: settings) else { throw ToolboxError.message("system scope allows external symlink") }
        let startupRoots = FileAccessPolicy.monitoredDirectories(settings: settings)
        let accountHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir), isDirectory: true)
        guard startupRoots.contains(accountHome),
              startupRoots.contains(accountHome.appendingPathComponent("Downloads", isDirectory: true))
        else { throw ToolboxError.message("cold start must monitor real home and Downloads explicitly") }
        settings.usageScope = .allDisks
        guard FileAccessPolicy.allows(external, settings: settings),
              !FileAccessPolicy.allows(URL(string: "https://example.com")!, settings: settings),
              FileAccessPolicy.monitoredDirectories(settings: settings).contains(URL(fileURLWithPath: "/"))
        else { throw ToolboxError.message("all disks scope mismatch") }
        if let path = ProcessInfo.processInfo.environment["SUPERMENU_TEST_VOLUME"] {
            let volume = URL(fileURLWithPath: path, isDirectory: true)
            guard !FileAccessPolicy.allows(volume, settings: Settings()) else { throw ToolboxError.message("system scope allows custom-mounted disk") }
            let externalFile = try FileActions.withAuthorizedURL(volume, settings: settings) {
                try FileActions.createDocument(named: "direct-access.txt", contents: Data("external".utf8), in: $0)
            }
            defer { try? fm.removeItem(at: externalFile) }
            guard try String(contentsOf: externalFile, encoding: .utf8) == "external" else { throw SmokeError.unexpectedResult }
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw SmokeError.unexpectedResult }
        let source = fixture.appendingPathComponent("silent-conversion.png")
        try png.write(to: source)
        let windowsBefore = NSApp?.windows.count ?? 0
        try await ImageToolsController().convert([source], format: .jpg, settings: settings)
        let output = fixture.appendingPathComponent("silent-conversion.jpg")
        guard FileManager.default.fileExists(atPath: output.path),
              (NSApp?.windows.count ?? 0) == windowsBefore, try Data(contentsOf: source) == png
        else { throw SmokeError.unexpectedResult }
        try await ImageToolsController().convert([source], format: .jpg, settings: settings)
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("silent-conversion 2.jpg").path)
        else { throw SmokeError.unexpectedResult }
        if let path = ProcessInfo.processInfo.environment["SUPERMENU_TEST_UPDATE_ARCHIVE"],
           let version = ProcessInfo.processInfo.environment["SUPERMENU_TEST_UPDATE_VERSION"] {
            let root = fixture.appendingPathComponent("update-test", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            let archive = URL(fileURLWithPath: path)
            let prepared = try UpdateInstaller.prepare(archive: archive, version: version, directory: root)
            guard fm.fileExists(atPath: prepared.app.appendingPathComponent("Contents/MacOS/SuperMenu").path)
            else { throw SmokeError.unexpectedResult }
            do { try UpdateInstaller.validateApp(prepared.app, expectedVersion: "99.99.99"); throw SmokeError.unexpectedResult }
            catch is SmokeError { throw SmokeError.unexpectedResult } catch {}
            print("PASS: actual distribution ZIP preflight, extraction, signature, identity, version, template and icon validation; wrong version rejected")
        }
        print("PASS: silent conversion exports beside the source, preserves source bytes and numbers collisions")
        print("PASS: direct file creation, scoped operations and cut without directory grants; disk scope and symlink filtering")
    }

    @MainActor private static func send(to app: URL) throws {
        let fixture = try SharedStore.directory().appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        try verifyLocalization()
        try verifyTemplates(in: fixture)
        try verifyUpdatePackage(in: fixture)
        let newer = GitHubRelease(tag_name: "v0.3.10", html_url: "https://github.com/1078302479/SuperMenu/releases/tag/v0.3.10", draft: false, prerelease: false)
        guard newer.isNewer(than: "0.3.9"), !newer.isNewer(than: "0.3.10"),
              GitHubRelease.version("v0.3.4-beta") == nil, newer.page != nil,
              GitHubRelease(tag_name: "v9.0.0", html_url: "https://example.com/file", draft: false, prerelease: true).page == nil,
              FileIconLibrary.presets.allSatisfy({ FileIconLibrary.image($0)?.isValid == true }),
              MenuIcons.action(.openTerminal, size: 16)?.isValid == true
        else { throw SmokeError.unexpectedResult }
        guard FinderExtensionPermission.enabledRegistration(in: "+    io.github.1078302479.SuperMenu.Finder(0.3.4) /Applications/增强右键.app"),
              !FinderExtensionPermission.enabledRegistration(in: "-    io.github.1078302479.SuperMenu.Finder(0.3.4)"),
              !FinderExtensionPermission.enabledRegistration(in: "+    io.github.other.Finder(1.0)"),
              FinderExtensionPermission.enabledRegistration(in: "-    io.github.1078302479.SuperMenu.Finder(0.3.7)\n+    io.github.1078302479.SuperMenu.Finder(0.3.4)")
        else { throw SmokeError.unexpectedResult }
        guard ProtectedDirectoryPermission.result(errors: [ENOENT, ENOENT]) == .unknown,
              ProtectedDirectoryPermission.result(errors: [EPERM, ENOENT]) == .denied,
              ProtectedDirectoryPermission.result(errors: [EACCES, EPERM]) == .denied,
              ProtectedDirectoryPermission.result(errors: [0, EPERM]) == .accessible
        else { throw SmokeError.unexpectedResult }
        print("PASS: permission probe distinguishes denied, accessible and unavailable targets")
        let transferMenu = NSMenu()
        let largeIcon = NSImage(size: NSSize(width: 1024, height: 1024))
        let largeBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
        largeIcon.addRepresentation(largeBitmap)
        let transferItem = NSMenuItem(title: "Large icon", action: nil, keyEquivalent: "")
        transferItem.image = largeIcon
        let childMenu = NSMenu()
        let child = NSMenuItem(title: "System folder", action: nil, keyEquivalent: "")
        child.image = NSWorkspace.shared.icon(forFile: fixture.path)
        child.isEnabled = false
        childMenu.addItem(child)
        transferItem.submenu = childMenu
        transferMenu.addItem(transferItem)
        MenuIcons.prepareForFinder(transferMenu)
        for item in [transferItem, child] {
            if #available(macOS 27.0, *) {
                guard item.preferredImageVisibility == .visible else { throw SmokeError.unexpectedResult }
            }
            guard let icon = item.image, icon.representations.count == 1,
                  icon.representations[0].pixelsWide == 32, icon.representations[0].pixelsHigh == 32,
                  icon.size == NSSize(width: 16, height: 16),
                  (icon.tiffRepresentation?.count ?? Int.max) < 16_384
            else { throw ToolboxError.message("Finder icon payload retains large representations") }
        }
        guard !child.isEnabled else { throw SmokeError.unexpectedResult }
        print("PASS: Finder menu icons and nested system icons have bounded 32px payloads; disabled items remain disabled")
        try verifyToolbarMenu()
        try verifyNamedCreation(in: fixture)
        try verifySavedFolders(in: fixture)
        try verifyTransferDestinationConfiguration()
        try verifyCopy(in: fixture)
        try verifyCrossVolumeMove(in: fixture)
        try verifyFileNameActions(in: fixture)
        try verifyToolbox(in: fixture)
        try verifyImagesAndIcons(in: fixture)
        if ProcessInfo.processInfo.environment["SUPERMENU_CAPTURE_UI"] == "1" { try verifySettingsRendering() }
        let original = fixture.appendingPathComponent("报价模板.dat")
        let initialBytes = Data([0x00, 0x45, 0xFF])
        try initialBytes.write(to: original)
        var settings = try TemplateStore.importFile(original, into: Settings())
        guard let entry = settings.customTemplates?.entries.first else { throw SmokeError.unexpectedResult }
        settings.customTemplates?.renameTemplate(id: entry.id, to: "  新报价单  ")
        try SharedStore.save(settings)
        guard try SharedStore.load().customTemplates?.enabledTemplate(id: entry.id).title == "新报价单"
        else { throw SmokeError.unexpectedResult }
        let contents = Data("保留原内容".utf8)
        try contents.write(to: original)

        let request = FinderRequest(action: .newText, paths: [fixture.path], created: Date(), customTemplateID: entry.id)
        let stale = try SharedStore.enqueue(FinderRequest(action: .newText, paths: [fixture.path],
                                                         created: Date().addingTimeInterval(-121)))
        guard try SharedStore.consume(stale) == nil else { throw SmokeError.unexpectedRequest }

        var finished = false
        var launchError: Error?
        try FinderHandoff.send(request, to: app) { error in
            DispatchQueue.main.async {
                launchError = error
                finished = true
            }
        }
        let result = fixture.appendingPathComponent("result")
        let failure = fixture.deletingLastPathComponent().appendingPathComponent("failure")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if finished, let launchError { throw launchError }
            if let detail = try? String(contentsOf: failure, encoding: .utf8) {
                FileHandle.standardError.write(Data(detail.utf8))
                throw SmokeError.unexpectedResult
            }
            if let name = try? String(contentsOf: result, encoding: .utf8) {
                let newFile = fixture.appendingPathComponent(name)
                guard name == "报价模板 2.dat",
                      try Data(contentsOf: newFile) == initialBytes,
                      try Data(contentsOf: original) == contents else { throw SmokeError.unexpectedResult }
                let updated = try TemplateStore.remove(entry, from: settings)
                let reimported = try TemplateStore.importFile(original, into: updated)
                guard let library = reimported.customTemplates, library.entries.count == 1,
                      library.entries.first?.id != entry.id else { throw SmokeError.unexpectedResult }
                do {
                    _ = try library.enabledTemplate(id: entry.id)
                    throw SmokeError.unexpectedResult
                } catch SuperMenuError.templateDisabled {}
                print("PASS: renamed template handoff preserves filename and bytes, no overwrite, removal and stale request rejection")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw SmokeError.timedOut
    }

    private static func verifyUpdatePackage(in fixture: URL) throws {
        guard FinderAutomation.matches(CGRect(x: 20, y: 40, width: 800, height: 600), CGRect(x: 21, y: 41, width: 800, height: 600)),
              !FinderAutomation.matches(CGRect(x: 20, y: 40, width: 800, height: 600), CGRect(x: 500, y: 40, width: 800, height: 600)) else { throw SmokeError.unexpectedResult }
        guard FinderAccessibility.fileURL("/Users/sample/中文目录" as CFString)?.path == "/Users/sample/中文目录",
              FinderAccessibility.fileURL("file:///Users/sample/Folder" as CFString)?.path == "/Users/sample/Folder",
              FinderAccessibility.fileURL("https://example.com/" as CFString) == nil,
              FinderAccessibility.fileURL("relative/folder" as CFString) == nil else { throw SmokeError.unexpectedResult }
        let base = "https://github.com/1078302479/SuperMenu/releases/download/v0.5.0/"
        let zip = ReleaseAsset(name: "SuperMenu-v0.5.0-arm64.zip", browser_download_url: base + "SuperMenu-v0.5.0-arm64.zip", size: 123, digest: nil)
        let sums = ReleaseAsset(name: "SHA256SUMS.txt", browser_download_url: base + "SHA256SUMS.txt", size: 100, digest: nil)
        let release = GitHubRelease(tag_name: "v0.5.0", html_url: "https://github.com/1078302479/SuperMenu/releases/tag/v0.5.0", draft: false, prerelease: false, assets: [zip, sums])
        let package = try UpdatePackage(release: release, architecture: "arm64")
        let payload = fixture.appendingPathComponent("hash-fixture")
        try Data("abc".utf8).write(to: payload)
        let hash = try UpdatePackage.hash(of: payload)
        guard hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
              try package.expectedHash(in: Data((hash + "  " + zip.name + "\n").utf8)) == hash else { throw SmokeError.unexpectedResult }
        do {
            _ = try UpdatePackage(release: release, architecture: "x86_64")
            throw SmokeError.unexpectedResult
        } catch is SmokeError { throw SmokeError.unexpectedResult } catch {}
        for text in ["", "invalid  " + zip.name, hash + "  other.zip", hash + "  " + zip.name + "\n" + hash + "  " + zip.name] {
            do { _ = try package.expectedHash(in: Data(text.utf8)); throw SmokeError.unexpectedResult }
            catch is SmokeError { throw SmokeError.unexpectedResult } catch {}
        }
        guard ReleaseAsset(name: "bad", browser_download_url: "https://example.com/archive.zip", size: 1, digest: nil).url == nil,
              ReleaseAsset(name: "bad", browser_download_url: base + "file.zip?token=value", size: 1, digest: nil).url == nil
        else { throw SmokeError.unexpectedResult }
        let invalid = fixture.appendingPathComponent("invalid-update.zip")
        try Data("not a zip".utf8).write(to: invalid)
        do { try UpdateInstaller.validateArchive(invalid); throw SmokeError.unexpectedResult }
        catch is SmokeError { throw SmokeError.unexpectedResult } catch {}
        let home = URL(fileURLWithPath: "/Users/sample", isDirectory: true)
        guard CloudMenuSettings.isCloudFolder(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents"), home: home),
              CloudMenuSettings.isCloudFolder(home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal/Folder"), home: home),
              !CloudMenuSettings.isCloudFolder(home.appendingPathComponent("Documents"), home: home),
              !CloudMenuSettings.isCloudFolder(home.appendingPathComponent("Library/CloudStorage/Dropbox/Folder"), home: home),
              !CloudMenuSettings.isCloudFolder(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs-other"), home: home)
        else { throw SmokeError.unexpectedResult }
        var customSettings = Settings()
        customSettings.cloudMenu = CloudMenuSettings(modifierRightClick: true, modifier: .option, middleClick: true)
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(customSettings))
        guard decoded.cloudMenu?.modifier == .option, decoded.cloudMenu?.middleClick == true else { throw SmokeError.unexpectedResult }
        let background = FinderMenuContext(folder: fixture, selection: [])
        var received: FinderRequest?
        let builder = FinderMenuController(context: { background }, onRequest: { received = $0 })
        guard let menu = builder.menu(for: .contextualMenuForContainer, settings: customSettings),
              let copy = menu.items.first(where: { $0.identifier?.rawValue == FinderAction.copyPath.rawValue }),
              let action = copy.action, let target = copy.target as? NSObject else { throw SmokeError.unexpectedResult }
        _ = target.perform(action, with: copy)
        guard received?.paths == [fixture.path], received?.action == .copyPath else { throw SmokeError.unexpectedResult }
        // Two independent cloud popups retain their own captured directory and
        // selection even when another window is queried or a second menu opens.
        let secondFolder = fixture.appendingPathComponent("second-window", isDirectory: true)
        let files = ["one.txt", "two.txt"].map { secondFolder.appendingPathComponent($0) }
        let selectedContext = FinderMenuContext(folder: secondFolder, selection: files)
        let secondBuilder = FinderMenuController(context: { selectedContext }, onRequest: { received = $0 })
        guard let secondMenu = secondBuilder.menu(for: .contextualMenuForItems, settings: customSettings),
              let secondCopy = secondMenu.items.first(where: { $0.identifier?.rawValue == FinderAction.copyPath.rawValue }),
              let secondAction = secondCopy.action, let secondTarget = secondCopy.target as? NSObject else { throw SmokeError.unexpectedResult }
        _ = secondTarget.perform(secondAction, with: secondCopy)
        guard received?.paths == files.map(\.path) else { throw SmokeError.unexpectedResult }
        _ = target.perform(action, with: copy)
        guard received?.paths == [fixture.path] else { throw SmokeError.unexpectedResult }
        print("PASS: cloud path boundaries, trigger settings roundtrip, shared background menu and action context")
        print("PASS: update architecture selection, official URLs, known SHA256 vector, missing/duplicate hashes and invalid archive rejection")
    }

    private static func verifyLocalization() throws {
        guard InterfaceText.english("发现新版本 0.5.1") == "New version available: 0.5.1",
              InterfaceText.english("当前版本 0.5.0，最新版本 0.5.1。") == "Installed version: 0.5.0. Latest version: 0.5.1.",
              InterfaceText.english("检查失败，文件/中文😀\n网络错误") == "Update check failed: 文件/中文😀\n网络错误",
              InterfaceText.english("我的中文菜单😀") == "我的中文菜单😀"
        else { throw SmokeError.unexpectedResult }
        print("PASS: dynamic localization preserves versions, Unicode filenames, multiline details and custom names")
    }

    private static func verifyTemplates(in fixture: URL) throws {
        let legacyJSON = Data(#"{"folders":[],"enabled":["newText","copyPath"]}"#.utf8)
        var settings = try JSONDecoder().decode(Settings.self, from: legacyJSON)
        guard DocumentTemplate.allCases.allSatisfy(\.isAvailable),
              DocumentTemplate.allCases.count == 15,
              Set(DocumentTemplate.allCases.map(\.menuTag)).count == 15,
              settings.visibleTemplates == DocumentTemplate.allCases.filter(\.isAvailable),
              settings.enabled == [.newText, .copyPath] else { throw SmokeError.unexpectedResult }
        settings.enabledTemplates = []
        let reloaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        guard reloaded.visibleTemplates.isEmpty else { throw SmokeError.unexpectedResult }

        settings.enabledTemplates = [.text, .xml]
        settings.moveTemplate(.xml, to: .text)
        settings.renameTemplate(.xml, to: "  XML 草稿  ")
        var edited = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        guard edited.visibleTemplates == [.xml, .text], edited.templateTitle(.xml) == "XML 草稿",
              Array(edited.orderedTemplates.prefix(3)) == [.xml, .text, .richText],
              edited.orderedTemplates.count == DocumentTemplate.allCases.count else { throw SmokeError.unexpectedResult }
        edited.renameTemplate(.xml, to: "  ")
        guard edited.templateTitle(.xml) == "XML" else { throw SmokeError.unexpectedResult }
        var custom = CustomTemplateLibrary(entries: [
            CustomTemplate(id: 1, fileName: "one.txt"),
            CustomTemplate(id: 2, fileName: "two.txt"),
            CustomTemplate(id: 3, fileName: "three.txt"),
        ], nextID: 4)
        custom.moveTemplate(id: 1, to: 3)
        custom.renameTemplate(id: 2, to: "文本模板")
        let library = try JSONDecoder().decode(CustomTemplateLibrary.self, from: JSONEncoder().encode(custom))
        guard library.entries.map(\.id) == [2, 3, 1], library.entries.first?.title == "文本模板",
              library.entries.first?.fileName == "two.txt" else { throw SmokeError.unexpectedResult }
        print("PASS: template names and order survive a settings round trip")

        for action in [FinderAction.newText, .copyPath, .copyName, .addFavorite, .showHiddenFiles, .hideHiddenFiles] {
            let icon = action == .newText ? MenuIcons.newFile(size: 16) : MenuIcons.action(action, size: 16)
            guard let icon, !icon.isTemplate, icon.size == NSSize(width: 16, height: 16) else {
                throw SmokeError.unexpectedResult
            }
        }
        for action in [FinderAction.copyToFolder, .moveToFolder] {
            guard let icon = MenuIcons.action(action, size: 16), icon.isValid, !icon.isTemplate else {
                throw SmokeError.unexpectedResult
            }
        }
        let reviewApps = ["PyCharm", "WebStorm", "Android Studio", "AppCode", "DataGrip", "GoLand", "Rider", "RubyMine"]
        for app in reviewApps {
            if Bundle.main.url(forResource: "app-" + app, withExtension: "png", subdirectory: "TemplateIcons") != nil {
                guard let icon = MenuIcons.referenceImage(named: "app-" + app, size: 20),
                      icon.isValid, !icon.isTemplate else { throw SmokeError.unexpectedResult }
            }
        }
        var stagedIcons = 0
        let pointSize = NSSize(width: 16, height: 16)
        for name in DocumentTemplate.allCases.map(\.rawValue) + ["new-file", "named-file", "copy-name", "copy-path", "folder-from-name", "cut", "add-favorite"] {
            if Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "TemplateIcons") != nil {
                guard let image = MenuIcons.referenceImage(named: name, size: 16),
                      image.size == pointSize, !image.isTemplate else { throw SmokeError.unexpectedResult }
                stagedIcons += 1
            }
        }
        for (action, asset) in [(FinderAction.openTerminal, "app-Terminal"),
                                (.openFavorite, "nav-favorites"), (.setFileIcon, "file-icon")] {
            if let expected = MenuIcons.referenceImage(named: asset, size: 16) {
                guard let actual = MenuIcons.action(action, size: 16), !actual.isTemplate,
                      actual.size == pointSize, actual.tiffRepresentation == expected.tiffRepresentation
                else { throw SmokeError.unexpectedResult }
            }
        }
        guard MenuIcons.document(extension: "supermenu-test", size: 16).size == pointSize
        else { throw SmokeError.unexpectedResult }
        print("PASS: loaded \(stagedIcons) color reference icons and verified the system icon fallback")

        let txt = try FileActions.createDocument(.text, in: fixture)
        let markdown = try FileActions.createDocument(.markdown, in: fixture)
        let rtf = try FileActions.createDocument(.richText, in: fixture)
        let xml = try FileActions.createDocument(.xml, in: fixture)
        guard txt.pathExtension == "txt", try Data(contentsOf: txt).isEmpty,
              markdown.pathExtension == "md", try Data(contentsOf: markdown).isEmpty,
              rtf.pathExtension == "rtf",
              NSAttributedString(rtf: try Data(contentsOf: rtf), documentAttributes: nil) != nil,
              xml.lastPathComponent == "新建 XML 文档.xml",
              XMLParser(contentsOf: xml)?.parse() == true else {
            throw SmokeError.unexpectedResult
        }
        let archived: Set<DocumentTemplate> = [.word, .excel, .powerpoint, .pages, .numbers, .keynote]
        let wpsFormats: Set<DocumentTemplate> = [.wps, .wpsSheet, .wpsSlides]
        for template in DocumentTemplate.allCases.filter(\.isAvailable) {
            let output = try FileActions.createDocument(template, in: fixture)
            let bytes = try Data(contentsOf: output)
            guard output.pathExtension == template.rawValue else { throw SmokeError.unexpectedResult }
            if archived.contains(template), !bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
                throw SmokeError.unexpectedResult
            }
            if wpsFormats.contains(template), !bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) {
                throw SmokeError.unexpectedResult
            }
            if template == .illustrator, !bytes.starts(with: Data("%PDF-".utf8)) {
                throw SmokeError.unexpectedResult
            }
            if template == .photoshop, !bytes.starts(with: Data("8BPS".utf8)) {
                throw SmokeError.unexpectedResult
            }
        }
        print("PASS: legacy settings, disabled templates, TXT, Markdown and readable RTF")
        print("PASS: created and checked \(DocumentTemplate.allCases.filter(\.isAvailable).count) available formats")
    }

    private static func verifyToolbarMenu() throws {
        let target = NSObject()
        var settings = Settings()
        settings.enabledTemplates = [.text, .richText]
        settings.promotedTemplates = [.text]
        settings.renameTemplate(.text, to: "工作笔记")
        settings.moveTemplate(.richText, to: .text)
        settings.customTemplates = CustomTemplateLibrary(entries: [
            CustomTemplate(id: 1, fileName: "清单.txt", showsInMainMenu: true),
            CustomTemplate(id: 2, fileName: "已隐藏.txt", enabled: false, showsInMainMenu: true),
        ], nextID: 3)
        let menu = FinderMenuController.toolbarMenu(settings: settings, target: target)
        let items = menu.items.filter { !$0.isSeparatorItem }
        guard items.map(\.title) == [NamedDocument.title, "RTF", "工作笔记", "清单.txt"],
              items.map(\.tag) == [0, DocumentTemplate.richText.menuTag, DocumentTemplate.text.menuTag, 1],
              items.allSatisfy({ $0.target === target && $0.image != nil && $0.submenu == nil }),
              items.compactMap(\.action).map(NSStringFromSelector) == [
                "createNamedFromToolbar", "createBundledFromToolbar:", "createBundledFromToolbar:", "createCustomFromToolbar:",
              ] else { throw SmokeError.unexpectedResult }

        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        let contextMenu = NSMenu()
        FinderMenuController.addTemplates(to: contextMenu, settings: restored, target: target)
        let directItems = contextMenu.items.filter { $0.submenu == nil }
        guard directItems.map(\.title) == ["工作笔记", "清单.txt"],
              directItems.last?.tag == 1,
              directItems.last?.action.map(NSStringFromSelector) == "createCustomTemplate:",
              contextMenu.items.last?.submenu?.items.map(\.title) == [NamedDocument.title, "RTF"]
        else { throw SmokeError.unexpectedResult }
        let legacy = try JSONDecoder().decode(CustomTemplate.self, from: Data(#"{"id":1,"fileName":"legacy.txt","enabled":true}"#.utf8))
        var reset = restored
        reset.resetTemplateSettings()
        guard legacy.showsInMainMenu == nil,
              reset.enabledTemplates == nil, reset.promotedTemplates == nil, reset.templateOrder == nil,
              reset.templateTitle(.text) == DocumentTemplate.text.title,
              reset.customTemplates?.entries.map(\.id) == [1, 2], reset.customTemplates?.nextID == 3,
              reset.customTemplates?.entries.allSatisfy({ $0.enabled && $0.showsInMainMenu == nil }) == true
        else { throw SmokeError.unexpectedResult }

        settings.namedCreationDisplayName = "自定义测试文档"
        settings.showsTemplateIcons = false
        let configured = FinderMenuController.toolbarMenu(settings: settings, target: target)
        guard configured.items.first?.title == "自定义测试文档",
              configured.items.allSatisfy({ $0.image == nil }) else { throw SmokeError.unexpectedResult }

        settings.enabled.remove(.newText)
        let disabled = FinderMenuController.toolbarMenu(settings: settings, target: target)
        guard disabled.items.count == 1, disabled.items.first?.action == nil,
              disabled.items.first?.isEnabled == false else { throw SmokeError.unexpectedResult }

        let request = FinderRequest(action: .newText, paths: [], created: Date(), template: .text, fromToolbar: true)
        let message = try SharedStore.enqueue(request)
        guard let received = try SharedStore.consume(message), received.fromToolbar == true,
              received.paths.isEmpty, received.template == .text else { throw SmokeError.unexpectedRequest }
        print("PASS: custom template promotion, legacy decoding and reset; toolbar names, order, icons and targetless requests")
    }

    private static func verifyNamedCreation(in fixture: URL) throws {
        let folder = fixture.appendingPathComponent("命名测试", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let request = FinderRequest(action: .newText, paths: [folder.path], created: Date(), promptsForFileName: true)
        let message = try SharedStore.enqueue(request)
        guard let received = try SharedStore.consume(message), received.promptsForFileName == true,
              received.paths == [folder.path], received.template == nil, received.customTemplateID == nil
        else { throw SmokeError.unexpectedRequest }

        let named = try NamedDocument("  工程笔记.RTF  ")
        let existing = folder.appendingPathComponent("工程笔记.RTF")
        let original = Data("已有文件".utf8)
        try original.write(to: existing)
        let output = try FileActions.createDocument(named, in: folder)
        guard output.lastPathComponent == "工程笔记 2.RTF", try Data(contentsOf: existing) == original,
              NSAttributedString(rtf: try Data(contentsOf: output), documentAttributes: nil) != nil
        else { throw SmokeError.unexpectedResult }

        for name in ["空白", "部署.config"] {
            let empty = try FileActions.createDocument(NamedDocument(name), in: folder)
            guard empty.lastPathComponent == name, try Data(contentsOf: empty).isEmpty
            else { throw SmokeError.unexpectedResult }
        }
        for badName in ["   ", ".", "..", "../逃逸.txt", "dir/file", "名称:非法", "含\n换行", String(repeating: "字", count: 86)] {
            do {
                _ = try NamedDocument(badName)
                throw SmokeError.unexpectedResult
            } catch SuperMenuError.invalidFileName {}
        }
        var settings = Settings()
        guard settings.allowsNamedCreation else { throw SmokeError.unexpectedResult }
        settings.showsNamedCreation = false
        guard !settings.allowsNamedCreation else { throw SmokeError.unexpectedResult }
        settings.showsNamedCreation = true
        settings.enabled.remove(.newText)
        guard !settings.allowsNamedCreation else { throw SmokeError.unexpectedResult }
        print("PASS: named request, extension matching, custom extensions, collision protection and invalid names")
    }

    private static func verifyCopy(in fixture: URL) throws {
        let manager = FileManager.default
        let source = fixture.appendingPathComponent("源", isDirectory: true)
        let target = fixture.appendingPathComponent("目标", isDirectory: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: false)
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        let input = source.appendingPathComponent("报告.txt")
        let original = target.appendingPathComponent("报告.txt")
        let inputData = Data("源内容".utf8)
        let originalData = Data("目标原内容".utf8)
        try inputData.write(to: input)
        try originalData.write(to: original)
        guard let file = try FileTransfer.transferItem(input, into: target),
              let directory = try FileTransfer.transferItem(source, into: target),
              file.lastPathComponent == "报告 2.txt", try Data(contentsOf: file) == inputData,
              try Data(contentsOf: input) == inputData, try Data(contentsOf: original) == originalData,
              try Data(contentsOf: directory.appendingPathComponent("报告.txt")) == inputData else {
            throw SmokeError.unexpectedResult
        }
        do {
            _ = try FileTransfer.transferItem(source, into: source)
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.recursiveCopy {}
        let leftovers = try manager.contentsOfDirectory(atPath: target.path)
        guard !leftovers.contains(where: { $0.hasPrefix(".supermenu-copy-") }) else {
            throw SmokeError.unexpectedResult
        }
        do {
            _ = try FileTransfer.transferItem(input, into: source, mode: .move)
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.alreadyInDestination {}
        guard let moved = try FileTransfer.transferItem(input, into: target, mode: .move),
              moved.lastPathComponent == "报告 3.txt", !manager.fileExists(atPath: input.path),
              try Data(contentsOf: moved) == inputData, try Data(contentsOf: original) == originalData else {
            throw SmokeError.unexpectedResult
        }
        try inputData.write(to: input)
        guard try FileTransfer.transferItem(input, into: target, mode: .move, conflict: .skip) == nil,
              try Data(contentsOf: input) == inputData, try Data(contentsOf: original) == originalData,
              try FileTransfer.transferItem(input, into: target, mode: .move, conflict: .replace)?.path == original.path,
              try Data(contentsOf: original) == inputData, !manager.fileExists(atPath: input.path)
        else { throw SmokeError.unexpectedResult }
        let backups = try manager.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("替换备份-") }
        guard backups.count == 1,
              try Data(contentsOf: backups[0].appendingPathComponent(original.lastPathComponent)) == originalData
        else { throw SmokeError.unexpectedResult }

        let authorization = FolderAccess(path: target.path, bookmark: Data())
        var settings = Settings(folders: [authorization])
        var destinations = SavedFolders()
        destinations.add(authorization)
        settings.copyDestinations = destinations
        guard let id = destinations.entries.first?.id else { throw SmokeError.unexpectedResult }
        settings.showsMoveMenu = false
        do {
            _ = try settings.transferDestination(id: id, action: .moveToFolder)
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.copyDestinationUnavailable {}
        let requestURL = try SharedStore.enqueue(FinderRequest(action: .copyToFolder, paths: [input.path],
                                                               created: Date(), copyDestinationID: id))
        guard let request = try SharedStore.consume(requestURL), request.copyDestinationID == id,
              request.paths == [input.path], try settings.transferDestination(id: id, action: .copyToFolder).path == target.path else {
            throw SmokeError.unexpectedResult
        }
        var recent = RecentTransfers()
        recent.record(authorization)
        guard let recentID = recent.entries.first?.id else { throw SmokeError.unexpectedResult }
        recent.record(FolderAccess(path: source.path, bookmark: Data()))
        recent.record(authorization)
        settings.recentTransfers = recent
        let reloaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        guard reloaded.recentTransfers?.entries.map(\.folder.path) == [target.path, source.path],
              reloaded.recentTransfers?.entries.first?.id == recentID
        else { throw SmokeError.unexpectedResult }
        let other = try SharedStore.enqueue(FinderRequest(action: .copyToFolder, paths: [input.path],
                                                          created: Date(), transferTarget: .other))
        guard try SharedStore.consume(other)?.transferTarget == .other else { throw SmokeError.unexpectedRequest }
        settings.folders.removeAll()
        do {
            _ = try settings.transferDestination(id: id, action: .copyToFolder)
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.copyDestinationUnavailable {}
        print("PASS: copy and move, keep/replace/skip, backup preservation, recent ordering and transfer request")
    }

    private static func verifyCrossVolumeMove(in fixture: URL) throws {
        guard let path = ProcessInfo.processInfo.environment["SUPERMENU_TEST_VOLUME"] else { return }
        let target = URL(fileURLWithPath: path, isDirectory: true)
        let source = fixture.appendingPathComponent("跨卷目录", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: source, withIntermediateDirectories: false)
        let data = Data(repeating: 0xab, count: 1_150_000)
        let input = source.appendingPathComponent("数据.bin")
        try data.write(to: input)
        let resourceFork = Data("resource fork".utf8)
        guard resourceFork.withUnsafeBytes({
            setxattr(input.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0)
        }) == 0 else { throw SmokeError.unexpectedResult }
        try manager.createDirectory(at: source.appendingPathComponent("空文件夹"), withIntermediateDirectories: false)
        try manager.createSymbolicLink(atPath: source.appendingPathComponent("链接").path, withDestinationPath: "数据.bin")
        var sourceInfo = stat(), targetInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0, lstat(target.path, &targetInfo) == 0,
              sourceInfo.st_dev != targetInfo.st_dev,
              let output = try FileTransfer.transferItem(source, into: target, mode: .move),
              !manager.fileExists(atPath: source.path),
              try Data(contentsOf: output.appendingPathComponent("数据.bin")) == data,
              try Data(contentsOf: URL(fileURLWithPath: output.appendingPathComponent("数据.bin").path + "/..namedfork/rsrc")) == resourceFork,
              manager.fileExists(atPath: output.appendingPathComponent("空文件夹").path),
              try manager.destinationOfSymbolicLink(atPath: output.appendingPathComponent("链接").path) == "数据.bin"
        else { throw SmokeError.unexpectedResult }
        try manager.createDirectory(at: source, withIntermediateDirectories: false)
        guard try FileTransfer.transferItem(source, into: target, mode: .move, conflict: .skip) == nil,
              manager.fileExists(atPath: source.path)
        else { throw SmokeError.unexpectedResult }
        print("PASS: cross-volume move verified data, resource fork, empty directory and symlink; skip preserved the source")
    }

    private static func verifySavedFolders(in fixture: URL) throws {
        let first = FolderAccess(path: fixture.appendingPathComponent("first").path, bookmark: Data())
        let second = FolderAccess(path: fixture.appendingPathComponent("second").path, bookmark: Data())
        var settings = Settings(folders: [first, second])
        var favorites = SavedFolders()
        favorites.add(first)
        favorites.add(second)
        favorites.add(first)
        guard favorites.entries.count == 2, let original = favorites.entries.first else {
            throw SmokeError.unexpectedResult
        }
        favorites.move(original, by: 1)
        settings.favorites = favorites
        try SharedStore.save(settings)

        let reloaded = try SharedStore.load()
        guard reloaded.availableFavorites.map(\.path) == [second.path, first.path] else {
            throw SmokeError.unexpectedResult
        }
        let nested = first.path + "/nested"
        var relocated = reloaded
        relocated.favorites?.relocate(original, to: nested)
        guard relocated.availableFavorites.map(\.path) == [second.path, nested],
              relocated.availableFavorites.last?.id != original.id
        else { throw SmokeError.unexpectedResult }
        let url = try SharedStore.enqueue(FinderRequest(action: .openFavorite, paths: [], created: Date(),
                                                        favoriteFolderID: original.id))
        guard let request = try SharedStore.consume(url), request.action == .openFavorite,
              let id = request.favoriteFolderID, try reloaded.favoriteFolder(id: id).path == first.path else {
            throw SmokeError.unexpectedResult
        }
        settings.folders.removeAll { $0.id == first.id }
        do {
            _ = try settings.favoriteFolder(id: id)
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.favoriteUnavailable {}
        favorites.remove(path: first.path)
        favorites.add(first)
        guard favorites.entries.last?.id != id else { throw SmokeError.unexpectedResult }
        print("PASS: favorite order, request ID, revoked access and removed ID not reused")
    }

    private static func verifyFileNameActions(in fixture: URL) throws {
        let source = fixture.appendingPathComponent("版本 2.1.tar.gz")
        let original = Data("原文件".utf8)
        try original.write(to: source)
        let folder = try FileActions.createFolderFromName(of: source)
        guard folder.lastPathComponent == "版本 2.1.tar",
              try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              try Data(contentsOf: source) == original else { throw SmokeError.unexpectedResult }
        do {
            _ = try FileActions.createFolderFromName(of: source)
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.folderNameConflict("版本 2.1.tar") {}
        do {
            _ = try FileActions.createFolderFromName(of: folder)
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.folderSourceMustBeFile {}

        let noExtension = fixture.appendingPathComponent("README")
        try original.write(to: noExtension)
        guard try FileActions.createFolderFromName(of: noExtension).lastPathComponent == "README 文件夹"
        else { throw SmokeError.unexpectedResult }

        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let paths = [source.path, folder.path]
        try FileActions.copyLocationText(paths, namesOnly: true, to: clipboard)
        guard clipboard.string(forType: .string) == "版本 2.1.tar.gz\n版本 2.1.tar"
        else { throw SmokeError.unexpectedResult }
        try FileActions.copyLocationText(paths, namesOnly: false, to: clipboard)
        guard clipboard.string(forType: .string) == paths.joined(separator: "\n")
        else { throw SmokeError.unexpectedResult }

        let oldSettings = Data(#"{"folders":[],"enabled":["copyPath"]}"#.utf8)
        var settings = try JSONDecoder().decode(Settings.self, from: oldSettings)
        guard settings.isEnabled(.copyName), settings.isEnabled(.folderFromName)
        else { throw SmokeError.unexpectedResult }
        settings.showsCopyName = false
        settings.showsFolderFromName = false
        let reloaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        guard !reloaded.isEnabled(.copyName), !reloaded.isEnabled(.folderFromName), reloaded.isEnabled(.copyPath)
        else { throw SmokeError.unexpectedResult }
        print("PASS: copied names and paths to a private pasteboard, created folders without moving the source, and protected conflicts")
    }

    private static func verifyCutAndPaste() async throws {
        let manager = FileManager.default
        let fixture = try SharedStore.directory().appendingPathComponent("cut-fixture", isDirectory: true)
        let source = fixture.appendingPathComponent("源", isDirectory: true)
        let target = fixture.appendingPathComponent("目标", isDirectory: true)
        for directory in [source, target] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let first = source.appendingPathComponent("报告.txt")
        let folder = source.appendingPathComponent("项目", isDirectory: true)
        let child = folder.appendingPathComponent("内容.txt")
        let savedFolder = fixture.appendingPathComponent("暂时移走")
        let existing = target.appendingPathComponent("报告.txt")
        let moved = target.appendingPathComponent("报告 2.txt")
        let bytes = Data("源内容".utf8)
        let original = Data("目标原内容".utf8)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        try bytes.write(to: first)
        try bytes.write(to: child)
        try original.write(to: existing)

        do {
            try await CutTransfer().cut([first])
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.chooseFolder {}
        let access: CutTransfer.Access = { url, _, rejectLink, operation in
            // The test fixture already has sandbox access. Simulate the user-selected scope.
            guard FileActions.contains(url, in: fixture) else { throw SuperMenuError.chooseFolder }
            guard FileManager.default.fileExists(atPath: url.path) else { throw SuperMenuError.invalidTarget }
            if rejectLink, try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw SuperMenuError.unsupportedCopySource
            }
            try operation(url)
        }
        let worker = CutTransfer(access: access)

        try await worker.cut([first, folder, child, first])
        guard let batch = try CutState.pending(), batch.items.map(\.path) == [first.path, folder.path],
              manager.fileExists(atPath: first.path), manager.fileExists(atPath: child.path),
              try CutState.pending(now: batch.created.addingTimeInterval(86_400)) == nil else {
            throw SmokeError.unexpectedResult
        }
        do {
            try await worker.paste(into: first, batchID: batch.id)
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.invalidTarget {}
        guard try CutState.pending()?.items.count == 2 else { throw SmokeError.unexpectedResult }

        try manager.moveItem(at: folder, to: savedFolder)
        let requestURL = try SharedStore.enqueue(FinderRequest(action: .pasteCut, paths: [target.path],
                                                              created: Date(), cutBatchID: batch.id))
        guard let request = try SharedStore.consume(requestURL), request.action == .pasteCut,
              request.paths == [target.path], let id = request.cutBatchID else { throw SmokeError.unexpectedRequest }
        do {
            try await worker.paste(into: target, batchID: id)
            throw SmokeError.unexpectedResult
        } catch {
            guard error.localizedDescription.contains("已粘贴 1 项，1 项失败"),
                  error.localizedDescription.contains("仍有 1 项"),
                  error.localizedDescription.contains("源项目不存在") else { throw error }
        }
        guard !manager.fileExists(atPath: first.path), try Data(contentsOf: existing) == original,
              try Data(contentsOf: moved) == bytes,
              try CutState.pending()?.items.map(\.path) == [folder.path] else { throw SmokeError.unexpectedResult }
        try manager.moveItem(at: savedFolder, to: folder)
        try await worker.paste(into: target, batchID: batch.id)
        guard try CutState.pending() == nil, !manager.fileExists(atPath: folder.path),
              try Data(contentsOf: target.appendingPathComponent("项目/内容.txt")) == bytes else {
            throw SmokeError.unexpectedResult
        }

        try bytes.write(to: first)
        try await worker.cut([first])
        guard let previous = try CutState.pending()?.id else { throw SmokeError.unexpectedResult }
        try await worker.cut([first])
        guard let current = try CutState.pending()?.id, current != previous else { throw SmokeError.unexpectedResult }
        do {
            try await worker.paste(into: target, batchID: previous)
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.cutUnavailable {}
        try manager.moveItem(at: first, to: fixture.appendingPathComponent("原报告.txt"))
        try original.write(to: first)
        do {
            try await worker.paste(into: target, batchID: current)
            throw SmokeError.unexpectedResult
        } catch {
            guard error.localizedDescription.contains("原位置已换成另一个项目") else { throw error }
        }
        guard try CutState.pending() == nil, try Data(contentsOf: first) == original
        else { throw SmokeError.unexpectedResult }
        print("PASS: cut and paste preserve collisions, retry only failures, reject stale batches and replacement files")
        try await verifyCutVisibility(in: source, target: target, access: access)
        if let path = ProcessInfo.processInfo.environment["SUPERMENU_TEST_VOLUME"] {
            let destination = URL(fileURLWithPath: path, isDirectory: true)
            let clipboardWorker = CutTransfer { url, settings, rejectLink, operation in
                if url.path == destination.path { try operation(url) }
                else { try access(url, settings, rejectLink, operation) }
            }
            let original = source.appendingPathComponent("跨卷粘贴.txt")
            try bytes.write(to: original)
            try await clipboardWorker.cut([original])
            guard let batch = try CutState.pending() else { throw SmokeError.unexpectedResult }
            try await clipboardWorker.paste(into: destination, batchID: batch.id)
            guard try CutState.pending() == nil, !manager.fileExists(atPath: original.path),
                  try Data(contentsOf: destination.appendingPathComponent(original.lastPathComponent)) == bytes
            else { throw SmokeError.unexpectedResult }
            print("PASS: cut and paste used the verified move path across mounted volumes")
        }
    }

    private static func verifyCutVisibility(in source: URL, target: URL, access: @escaping CutTransfer.Access) async throws {
        let oldSettings = try SharedStore.load()
        var settings = oldSettings
        settings.hidesCutItems = true
        try SharedStore.save(settings)
        defer { try? SharedStore.save(oldSettings) }

        let visible = source.appendingPathComponent("可见.txt")
        let relocated = source.appendingPathComponent("已重命名.txt")
        let hidden = source.appendingPathComponent("原本隐藏.txt")
        let bytes = Data("剪切测试".utf8)
        try bytes.write(to: visible)
        try bytes.write(to: hidden)
        guard chflags(hidden.path, UInt32(UF_HIDDEN)) == 0 else { throw SmokeError.unexpectedResult }

        let worker = CutTransfer(access: access)
        try await worker.cut([visible, hidden])
        guard let batch = try CutState.pending(), batch.items.filter({ $0.hiddenBookmark != nil }).map(\.path) == [visible.path],
              try hasHiddenFlag(visible) else { throw SmokeError.unexpectedResult }

        // Restore the original file by bookmark without touching a replacement at its old path.
        try FileManager.default.moveItem(at: visible, to: relocated)
        try bytes.write(to: visible)
        try await CutTransfer(access: access).cancel(batchID: batch.id)
        guard try CutState.pending() == nil, try !hasHiddenFlag(relocated),
              try !hasHiddenFlag(visible), try hasHiddenFlag(hidden)
        else { throw SmokeError.unexpectedResult }

        try await worker.cut([visible, hidden])
        guard let pasteBatch = try CutState.pending(), try hasHiddenFlag(visible)
        else { throw SmokeError.unexpectedResult }
        do {
            try await worker.paste(into: source, batchID: pasteBatch.id)
            throw SmokeError.unexpectedResult
        } catch {
            guard error.localizedDescription.contains("已粘贴 0 项，2 项失败") else { throw error }
        }
        guard try !hasHiddenFlag(visible), try hasHiddenFlag(hidden),
              try CutState.pending()?.needsVisibilityRecovery == false
        else { throw SmokeError.unexpectedResult }
        try await worker.paste(into: target, batchID: pasteBatch.id)
        guard try CutState.pending() == nil,
              try !hasHiddenFlag(target.appendingPathComponent(visible.lastPathComponent)),
              try hasHiddenFlag(target.appendingPathComponent(hidden.lastPathComponent))
        else { throw SmokeError.unexpectedResult }

        try await worker.cut([relocated])
        guard let expiring = try CutState.pending(), try hasHiddenFlag(relocated)
        else { throw SmokeError.unexpectedResult }
        try await CutTransfer(access: access).recoverExpired(now: expiring.created.addingTimeInterval(86_400))
        guard try CutState.pending() == nil, try !hasHiddenFlag(relocated),
              try CutState.load()?.needsVisibilityRecovery == false
        else { throw SmokeError.unexpectedResult }

        try await worker.cut([relocated])
        let later = target.appendingPathComponent("下一批.txt")
        try bytes.write(to: later)
        let limitedWorker = CutTransfer { url, settings, rejectLink, operation in
            guard !FileActions.contains(url, in: source) else { throw SuperMenuError.chooseFolder }
            try access(url, settings, rejectLink, operation)
        }
        do {
            try await limitedWorker.cut([later])
            throw SmokeError.unexpectedResult
        } catch {
            guard error.localizedDescription.contains("已记录新的剪切") else { throw error }
        }
        guard let next = try CutState.pending(), next.items.map(\.path) == [later.path],
              next.deferredRecovery?.map(\.path) == [relocated.path],
              try hasHiddenFlag(relocated), try hasHiddenFlag(later)
        else { throw SmokeError.unexpectedResult }
        try await worker.cancel(batchID: next.id)
        guard try CutState.load()?.needsVisibilityRecovery == false, try !hasHiddenFlag(later),
              try !hasHiddenFlag(relocated)
        else { throw SmokeError.unexpectedResult }
        print("PASS: restored renamed files, preserved preexisting hidden flags, retried after paste failure, expired state and revoked access")
    }

    private static func hasHiddenFlag(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw SmokeError.unexpectedResult }
        return info.st_flags & UInt32(UF_HIDDEN) != 0
    }

    private static func verifyTransferDestinationConfiguration() throws {
        let home = URL(fileURLWithPath: "/Users/send-test")
        var destinations = SavedFolders.standardTransferDestinations(home: home)
        guard destinations.entries.map(\.name) == ["下载", "图片", "音乐", "影片", "文稿"],
              destinations.entries.map({ URL(fileURLWithPath: $0.path).lastPathComponent }) == ["Downloads", "Pictures", "Music", "Movies", "Documents"] else { throw SmokeError.unexpectedResult }
        let documents = destinations.entries[4]
        destinations.rename(id: documents.id, to: "项目文档")
        destinations.move(id: documents.id, to: 0)
        let reloaded = try JSONDecoder().decode(SavedFolders.self, from: JSONEncoder().encode(destinations))
        guard reloaded.entries.first?.id == documents.id, reloaded.entries.first?.name == "项目文档",
              reloaded.entries.first?.path == documents.path else { throw SmokeError.unexpectedResult }
        destinations.remove(path: documents.path)
        guard !destinations.entries.contains(where: { $0.id == documents.id }) else { throw SmokeError.unexpectedResult }
        let oldIDs = Set(reloaded.entries.map(\.id))
        destinations.resetTransferDestinations(home: home)
        guard destinations.entries.count == 5, oldIDs.isDisjoint(with: Set(destinations.entries.map(\.id))) else { throw SmokeError.unexpectedResult }
        var legacy = Settings()
        var custom = SavedFolders()
        custom.add(path: "/tmp/custom-send")
        legacy.copyDestinations = custom
        legacy.initializeTransferDestinations()
        let migrated = legacy.copyDestinations!.entries
        guard migrated.count == 6, migrated.last?.path == "/tmp/custom-send" else { throw SmokeError.unexpectedResult }
        legacy.initializeTransferDestinations()
        guard legacy.copyDestinations!.entries == migrated else { throw SmokeError.unexpectedResult }
        let oldFolder = try JSONDecoder().decode(SavedFolder.self, from: Data(#"{"id":3,"path":"/tmp/legacy"}"#.utf8))
        guard oldFolder.name == "legacy" else { throw SmokeError.unexpectedResult }
        print("PASS: reference send defaults, custom names and order, deletion, reset IDs, legacy migration and idempotence")
    }

    @MainActor private static func verifySettingsRendering() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let output = try SharedStore.directory().appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = SettingsModel()
        let saved = model.settings
        defer { try? SharedStore.save(saved) }
        model.setSystemPreference { $0.interfaceLanguage = .chinese }
        let pages = SettingsPage.allCases
        guard pages.map(\.rawValue) == ["通用设置", "新建文件", "发送文件到…", "常用目录", "文件（夹）图标", "工具箱"] else { throw SmokeError.unexpectedResult }
        for merged in [false, true] {
            let menu = NSMenu()
            let parent = NSMenuItem(title: "图片转换", action: nil, keyEquivalent: "")
            parent.identifier = NSUserInterfaceItemIdentifier(FinderAction.convertImage.rawValue)
            let children = NSMenu()
            children.addItem(withTitle: "转为 PNG", action: nil, keyEquivalent: "")
            children.addItem(withTitle: "转为 JPG", action: nil, keyEquivalent: "")
            parent.submenu = children
            menu.addItem(parent)
            var preferences = Settings()
            preferences.mergedMenuGroups = merged ? [.images] : []
            FinderMenuController.customize(menu, settings: preferences, scenes: [.images], count: 1)
            if merged {
                guard menu.items.count == 1, menu.items[0].submenu?.items.map(\.title) == ["转为 PNG", "转为 JPG"] else { throw SmokeError.unexpectedResult }
            } else {
                guard menu.items.map(\.title) == ["转为 PNG", "转为 JPG"], menu.items.allSatisfy({ $0.submenu == nil }) else { throw SmokeError.unexpectedResult }
            }
        }
        var toolbox = Settings()
        guard Array(toolbox.toolboxItems.prefix(6)) == [.action(.fileInfo), .action(.desktopAlias), .action(.airDrop), .action(.copyName), .action(.folderFromName), .action(.cut)],
              !toolbox.toolboxItems.contains(.action(.newText)),
              toolbox.toolboxItems.contains(.action(.addFavorite)),
              toolbox.toolboxItems.contains(.application("com.apple.Terminal"))
        else { throw SmokeError.unexpectedResult }
        toolbox.moveToolboxItem(ToolboxItem.image(.png).id, to: ToolboxItem.image(.webp).id)
        guard toolbox.orderedImageFormats.first == .png else { throw SmokeError.unexpectedResult }
        toolbox.toolboxDisplayNames = [ToolboxItem.image(.png).id: "我的 PNG"]
        let reloaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(toolbox))
        guard reloaded.imageMenuName(.png) == "我的 PNG", reloaded.orderedImageFormats.first == .png else { throw SmokeError.unexpectedResult }
        model.setSystemPreference { $0.enabledTextServices = [] }
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("test", forType: .string)
        var serviceError: NSString?
        withUnsafeMutablePointer(to: &serviceError) { pointer in
            ServiceRouter(text: model.integrations.textServices).generateQRCode(pasteboard, userData: nil, error: AutoreleasingUnsafeMutablePointer(pointer))
        }
        guard serviceError != nil else { throw SmokeError.unexpectedResult }
        model.setSystemPreference { $0.enabledTextServices = nil }
        for (index, page) in pages.enumerated() {
            model.page = page
            if page == .send { model.setSystemPreference { $0.copyDestinations = .standardTransferDestinations() } }
            let host = NSHostingView(rootView: SettingsView(model: model))
            let size = NSSize(width: 980, height: 640)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SmokeError.unexpectedResult }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if page == .templates {
                try verifyInlineTemplateRename(in: window, model: model)
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SmokeError.unexpectedResult }
            try png.write(to: output.appendingPathComponent("\(index).png"))
        }
        model.setSystemPreference { $0.interfaceLanguage = .english }
        model.page = .overview
        guard model.settings.menuName(.copyPath) == "Copy Path" else { throw SmokeError.unexpectedResult }
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SmokeError.unexpectedResult }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SmokeError.unexpectedResult }
        try png.write(to: output.appendingPathComponent("6.png"))
        print("PASS: rendered the six reference settings pages and English General offscreen")
    }

    @MainActor private static func verifyInlineTemplateRename(in window: NSWindow, model: SettingsModel) throws {
        func findTemplateField(in view: NSView) -> MenuNameField? {
            if let field = view as? MenuNameField, field.stringValue == model.settings.templateTitle(.text) { return field }
            return view.subviews.lazy.compactMap { findTemplateField(in: $0) }.first
        }
        guard let content = window.contentView, let field = findTemplateField(in: content),
              let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 2, pressure: 1)
        else { throw ToolboxError.message("Inline rename: the TXT editor was not rendered") }
        let original = field.stringValue
        field.mouseDown(with: doubleClick)
        guard let editor = field.currentEditor() as? NSTextView, editor.isEditable, window.firstResponder === editor
        else { throw ToolboxError.message("Inline rename: double-click did not focus an editable field") }
        editor.string = "放弃修改"
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        guard !field.editingName, field.stringValue == original, model.settings.templateTitle(.text) == original
        else { throw ToolboxError.message("Inline rename: Escape did not restore the original title") }

        field.mouseDown(with: doubleClick)
        guard let savingEditor = field.currentEditor() as? NSTextView, savingEditor.isEditable
        else { throw ToolboxError.message("Inline rename: the editor could not reopen") }
        savingEditor.string = " 双击测试 TXT "
        savingEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        guard try SharedStore.load().templateTitle(.text) == "双击测试 TXT"
        else { throw ToolboxError.message("Inline rename: Return did not save the edited field (\(field.stringValue))") }
        let menu = NSMenu()
        FinderMenuController.addTemplates(to: menu, settings: model.settings, target: NSObject())
        guard menu.items.contains(where: { $0.title == "双击测试 TXT" || $0.submenu?.item(withTitle: "双击测试 TXT") != nil })
        else { throw ToolboxError.message("Inline rename: the saved title did not reach the Finder menu") }
        model.renameTemplate(.text, to: original == DocumentTemplate.text.title ? "" : original)
        print("PASS: template name double-click enters the field editor, Escape cancels, and saving updates the Finder menu title")
    }

    private static func verifyToolboxCancellation() async throws {
        let file = try SharedStore.directory().appendingPathComponent("cancel-hash.dat")
        try Data(repeating: 1, count: 2 << 20).write(to: file)
        let task = Task.detached { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ToolboxActions.fileInformation(at: file)
        }
        do {
            _ = try await task.value
            throw SmokeError.unexpectedResult
        } catch is CancellationError {}
        print("PASS: hashing responds to task cancellation")
    }

    @MainActor private static func verifyTextServicesAndArchives() throws {
        let root = try SharedStore.directory().appendingPathComponent("workflow-fixture", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("资料", isDirectory: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("中文.txt")
        let bytes = Data("文本 ' 引号 & emoji 🐱".utf8)
        try bytes.write(to: file)
        try bytes.write(to: source.appendingPathComponent(".隐藏"))
        try manager.createDirectory(at: source.appendingPathComponent("空目录"), withIntermediateDirectories: false)
        do {
            _ = try ArchiveActions.compress([source], sevenZip: false, into: source)
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.recursiveCopy {}
        for sevenZip in [false, true] {
            let archive = try ArchiveActions.compress([source], sevenZip: sevenZip, into: root)
            let extracted = try ArchiveActions.extract(archive, into: root)
            let folder = extracted.appendingPathComponent("资料")
            guard try Data(contentsOf: folder.appendingPathComponent("中文.txt")) == bytes,
                  try Data(contentsOf: folder.appendingPathComponent(".隐藏")) == bytes,
                  manager.fileExists(atPath: folder.appendingPathComponent("空目录").path)
            else { throw SmokeError.unexpectedResult }
        }
        let hostile = root.appendingPathComponent("unsafe.zip")
        guard let writer = archive_write_new(), let entry = archive_entry_new() else { throw SmokeError.unexpectedResult }
        defer { archive_write_free(writer); archive_entry_free(entry) }
        guard archive_write_set_format_zip(writer) == 0, archive_write_open_filename(writer, hostile.path) == 0
        else { throw SmokeError.unexpectedResult }
        archive_entry_set_pathname(entry, "../escaped.txt")
        archive_entry_set_filetype(entry, UInt32(S_IFREG))
        archive_entry_set_perm(entry, 0o600)
        archive_entry_set_size(entry, 1)
        guard archive_write_header(writer, entry) == 0 else { throw SmokeError.unexpectedResult }
        var payload: UInt8 = 1
        guard archive_write_data(writer, &payload, 1) == 1, archive_write_close(writer) == 0 else { throw SmokeError.unexpectedResult }
        do {
            _ = try ArchiveActions.extract(hostile, into: root)
            throw SmokeError.unexpectedResult
        } catch {
            guard error.localizedDescription.contains("不安全路径") else { throw error }
        }
        guard !manager.fileExists(atPath: root.appendingPathComponent("escaped.txt").path),
              !manager.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.txt").path)
        else { throw SmokeError.unexpectedResult }
        try manager.setAttributes([.posixPermissions: 0o450], ofItemAtPath: file.path)
        try WorkflowActions.grantOwnerWrite(at: file)
        let permissions = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        guard permissions?.intValue == 0o650 else { throw SmokeError.unexpectedResult }
        let conflict = root.appendingPathComponent("中文.txt")
        try Data("原目标".utf8).write(to: conflict)
        let preview = try WorkflowActions.dissolvePreview(source)
        guard preview.conflicts == ["中文.txt"] else { throw SmokeError.unexpectedResult }
        let result = try WorkflowActions.dissolve(preview)
        guard result.removedFolder, result.failures.isEmpty,
              try Data(contentsOf: root.appendingPathComponent("中文 2.txt")) == bytes,
              try Data(contentsOf: conflict) == Data("原目标".utf8)
        else { throw SmokeError.unexpectedResult }

        let text = "中文 & 'quotes' 🐱"
        for provider in [TextServiceTools.TranslationProvider.baidu, .google] {
            let url = try TextServiceTools.translationURL(text, provider: provider)
            guard url.scheme == "https", URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                $0.value == text
            }) == true else { throw SmokeError.unexpectedResult }
        }
        let png = try TextServiceTools.qrCodePNG(text)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        try TextServices.copyQRCode(png, to: clipboard)
        guard let copied = clipboard.data(forType: .png), copied == png,
              let source = CGImageSourceCreateWithData(copied as CFData, nil),
              let qr = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SmokeError.unexpectedResult }
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: qr).perform([request])
        guard request.results?.contains(where: { $0.payloadStringValue == text }) == true
        else { throw SmokeError.unexpectedResult }

        var settings = Settings(folders: [FolderAccess(path: root.path, bookmark: Data("private".utf8))])
        settings.interfaceLanguage = .chinese
        settings.applications = [ApplicationEntry(id: "custom", name: "private", bookmark: Data([1]))]
        settings.actionOrder = [.copyPath, .fileInfo]
        settings.menuRules = [.copyPath: MenuRule(name: "我的路径", group: .files, scenes: [.files])]
        let data = try JSONEncoder().encode(PortablePreferences(settings))
        guard !String(decoding: data, as: UTF8.self).contains(root.path) else { throw SmokeError.unexpectedResult }
        let imported = try JSONDecoder().decode(PortablePreferences.self, from: data).merging(into: settings)
        guard imported.folders.first?.bookmark == Data("private".utf8), imported.applications?.first?.id == "custom",
              imported.orderedActions.prefix(2) == [.copyPath, .fileInfo],
              !imported.allows(.copyPath, scenes: [.files, .folders], count: 2)
        else { throw SmokeError.unexpectedResult }
        let menu = NSMenu()
        for action in [FinderAction.fileInfo, .copyPath] {
            let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            menu.addItem(item)
        }
        var grouped = imported
        grouped.mergedMenuGroups = [.files]
        FinderMenuController.customize(menu, settings: grouped, scenes: [.files], count: 1)
        guard menu.items.count == 1, menu.items.first?.submenu?.items.map(\.title) == ["我的路径", "文件信息"],
              Set(ApplicationCatalog.entries.map(\.menuTag)).count == ApplicationCatalog.entries.count
        else { throw SmokeError.unexpectedResult }
        print("PASS: ZIP/7z round trips, write permissions, folder dissolution, QR pasteboard and decoding, URL escaping, portable preferences and menu grouping")
    }

    private static func verifyToolbox(in fixture: URL) throws {
        let manager = FileManager.default
        let folder = fixture.appendingPathComponent("工具箱测试", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("测试.txt")
        try Data("abc".utf8).write(to: file)
        let information = try ToolboxActions.fileInformation(at: file)
        let vectors = [
            "MD5  900150983cd24fb0d6963f7d28e17f72",
            "SHA1  a9993e364706816aba3e25717850c26c9cd0d89d",
            "SHA256  ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "SHA512  ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        ]
        guard vectors.allSatisfy(information.contains) else { throw SmokeError.unexpectedResult }
        for (algorithm, vector) in zip(FileChecksum.allCases, vectors) {
            let result = try ToolboxActions.fileInformation(at: file, checksum: algorithm)
            guard vectors.filter(result.contains) == [vector] else { throw SmokeError.unexpectedResult }
        }
        try ToolboxActions.setHidden(true, at: file)
        guard try hasHiddenFlag(file) else { throw SmokeError.unexpectedResult }
        try ToolboxActions.setHidden(false, at: file)
        guard try !hasHiddenFlag(file) else { throw SmokeError.unexpectedResult }
        try ToolboxActions.toggleExtension(at: file)
        var fresh = URL(fileURLWithPath: file.path)
        guard try fresh.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension == true
        else { throw SmokeError.unexpectedResult }
        try ToolboxActions.toggleExtension(at: file)
        fresh = URL(fileURLWithPath: file.path)
        guard try fresh.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension == false
        else { throw SmokeError.unexpectedResult }

        let alias = try ToolboxActions.createAlias(for: file, in: folder)
        let secondAlias = try ToolboxActions.createAlias(for: file, in: folder)
        let resolved = try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting])
        guard resolved.path == file.path, alias != secondAlias,
              try alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
        else { throw SmokeError.unexpectedResult }

        let intended = "中文.txt"
        guard let broken = String(data: Data(intended.utf8), encoding: .isoLatin1),
              ToolboxActions.repairName(broken, encoding: .isoLatin1) == intended
        else { throw SmokeError.unexpectedResult }
        let identity = try ToolboxActions.identity(file)
        let renamed = try ToolboxActions.rename(file, to: "修复.txt", expected: identity)
        guard !manager.fileExists(atPath: file.path), try Data(contentsOf: renamed) == Data("abc".utf8)
        else { throw SmokeError.unexpectedResult }
        try Data("已存在".utf8).write(to: file)
        do {
            _ = try ToolboxActions.rename(renamed, to: file.lastPathComponent, expected: identity)
            throw SmokeError.unexpectedResult
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {}
        do {
            try ToolboxActions.permanentlyDelete(file, expected: identity)
            throw SmokeError.unexpectedResult
        } catch SuperMenuError.invalidTarget {}
        guard try Data(contentsOf: file) == Data("已存在".utf8) else { throw SmokeError.unexpectedResult }
        try ToolboxActions.permanentlyDelete(renamed, expected: identity)
        guard !manager.fileExists(atPath: renamed.path) else { throw SmokeError.unexpectedResult }
        var settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"folders":[],"enabled":["copyPath"]}"#.utf8))
        guard settings.isEnabled(.fileInfo), !settings.isEnabled(.deletePermanently),
              settings.confirmsPermanentDelete != false else { throw SmokeError.unexpectedResult }
        settings.toolboxEnabled = [.fileInfo, .deletePermanently]
        let reloaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        guard reloaded.isEnabled(.deletePermanently), !reloaded.isEnabled(.airDrop)
        else { throw SmokeError.unexpectedResult }
        print("PASS: four standard hash vectors, hidden and extension flags, Finder aliases, rename conflicts and identity-checked deletion")
    }

    private static func verifyImagesAndIcons(in fixture: URL) throws {
        let manager = FileManager.default
        let folder = fixture.appendingPathComponent("图片测试", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        guard let context = CGContext(data: nil, width: 96, height: 48, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SmokeError.unexpectedResult
        }
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        guard let image = context.makeImage() else { throw SmokeError.unexpectedResult }
        let source = folder.appendingPathComponent("透明.png")
        try ImageConversion.encode(image, type: "public.png" as CFString, to: source)
        let original = try Data(contentsOf: source)
        for format in ImageFormat.allCases {
            let output = try ImageConversion.convert(source, to: format, options: .init())
            guard output != source, try Data(contentsOf: source) == original else { throw SmokeError.unexpectedResult }
            if format == .macOS {
                let contents = try manager.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
                guard contents.count == 10 else { throw SmokeError.unexpectedResult }
                for file in contents { _ = try ImageConversion.load(file) }
                let largest = try ImageConversion.load(output.appendingPathComponent("icon_512x512@2x.png"))
                guard largest.width == 1024, largest.height == 1024 else { throw SmokeError.unexpectedResult }
            } else if format == .iOS {
                let deviceSizes: [(String, Set<Int>)] = [
                    ("iPhone", [29, 40, 57, 58, 114, 120, 180]),
                    ("iPad", [29, 40, 50, 58, 72, 76, 80, 100, 144, 153, 160]),
                    ("Apple Watch", [48, 55, 58, 80, 87, 88, 172, 196]),
                ]
                for (device, expectedSizes) in deviceSizes {
                    let group = output.appendingPathComponent(device, isDirectory: true)
                    let icons = try manager.contentsOfDirectory(at: group, includingPropertiesForKeys: nil)
                    var actualSizes = Set<Int>()
                    for file in icons {
                        let icon = try ImageConversion.load(file)
                        guard icon.width == icon.height, file.lastPathComponent == "\(icon.width)x\(icon.height).png"
                        else { throw SmokeError.unexpectedResult }
                        actualSizes.insert(icon.width)
                    }
                    guard actualSizes == expectedSizes, icons.count == expectedSizes.count else { throw SmokeError.unexpectedResult }
                }
                let catalog = output.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
                let data = try Data(contentsOf: catalog.appendingPathComponent("Contents.json"))
                guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let images = manifest["images"] as? [[String: String]], images.count == 18
                else { throw SmokeError.unexpectedResult }
                for entry in images {
                    guard let name = entry["filename"], let points = entry["size"]?.split(separator: "x").first,
                          let scale = entry["scale"]?.first, let multiplier = Int(String(scale)), let size = Double(points)
                    else { throw SmokeError.unexpectedResult }
                    let icon = try ImageConversion.load(catalog.appendingPathComponent(name))
                    guard icon.width == Int(size * Double(multiplier)), icon.height == icon.width,
                          icon.alphaInfo == .none || icon.alphaInfo == .noneSkipFirst || icon.alphaInfo == .noneSkipLast
                    else { throw SmokeError.unexpectedResult }
                }
            } else {
                let decoded = try ImageConversion.load(output)
                if format == .icns {
                    guard decoded.width == decoded.height, NSImage(contentsOf: output) != nil else { throw SmokeError.unexpectedResult }
                } else {
                    guard decoded.width == 96, decoded.height == 48 else { throw SmokeError.unexpectedResult }
                }
                if format == .webp {
                    guard try Data(contentsOf: output).starts(with: Data("RIFF".utf8)) else { throw SmokeError.unexpectedResult }
                }
                if format == .png || format == .webp || format == .jpg || format == .heic {
                    var pixels = [UInt8](repeating: 0, count: 96 * 48 * 4)
                    try pixels.withUnsafeMutableBytes { bytes in
                        guard let bitmap = CGContext(data: bytes.baseAddress, width: 96, height: 48, bitsPerComponent: 8,
                                                      bytesPerRow: 96 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                        | CGBitmapInfo.byteOrder32Big.rawValue) else { throw SmokeError.unexpectedResult }
                        bitmap.draw(decoded, in: CGRect(x: 0, y: 0, width: 96, height: 48))
                        let rgba = bytes.bindMemory(to: UInt8.self)
                        let offset = (24 * 96 + 80) * 4
                        if format == .png || format == .webp {
                            guard rgba[offset + 3] == 0 else { throw SmokeError.unexpectedResult }
                        } else {
                            guard rgba[offset] > 230, rgba[offset + 1] > 230, rgba[offset + 2] > 230,
                                  rgba[offset + 3] == 255 else { throw SmokeError.unexpectedResult }
                        }
                    }
                }
            }
        }
        let target = folder.appendingPathComponent("图标目标", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        let blue = try FileIconStore.image("blue")
        try FileIconStore.apply(blue, to: target)
        guard try FileIconStore.hasCustomIcon(target) else { throw SmokeError.unexpectedResult }
        try FileIconStore.apply(FileIconStore.image("green"), to: target)
        let moved = folder.appendingPathComponent("图标目标改名")
        try manager.moveItem(at: target, to: moved)
        try FileIconStore.restore(moved)
        guard try !FileIconStore.hasCustomIcon(moved) else { throw SmokeError.unexpectedResult }
        guard NSWorkspace.shared.setIcon(blue, forFile: moved.path, options: []) else { throw SmokeError.unexpectedResult }
        try FileIconStore.apply(FileIconStore.image("purple"), to: moved)
        try FileIconStore.restore(moved)
        guard try FileIconStore.hasCustomIcon(moved) else { throw SmokeError.unexpectedResult }
        let imported = try FileIconStore.importImage(source)
        guard try FileIconStore.imported().contains(where: { $0.id == imported.id }),
              try FileIconStore.image(imported.id).isValid else { throw SmokeError.unexpectedResult }
        var iconSettings = Settings()
        iconSettings.fileIconOrder = [imported.id, "Mac"]
        iconSettings.fileIconNames = [imported.id: "自定义测试图标"]
        iconSettings.disabledFileIcons = ["Apple"]
        let entries = FileIconLibrary.orderedEntries(settings: iconSettings, imported: try FileIconStore.imported())
        guard entries.prefix(2).map(\.id) == [imported.id, "Mac"],
              iconSettings.fileIconTitle(imported) == "自定义测试图标",
              !iconSettings.fileIconEnabled("Apple") else { throw SmokeError.unexpectedResult }
        if Bundle.main.url(forResource: "App", withExtension: "png", subdirectory: "FileIconPresets") != nil {
            guard FileIconLibrary.presets.allSatisfy({ entry in
                let expected = entry.id == "Mac" ? 64 : 128
                let rep = FileIconLibrary.image(entry)?.representations.first
                return rep?.pixelsWide == expected && rep?.pixelsHigh == expected
            }) else { throw SmokeError.unexpectedResult }
        }
        try FileIconStore.removeCustomIcon(moved)
        guard try !FileIconStore.hasCustomIcon(moved) else { throw SmokeError.unexpectedResult }
        try FileIconStore.removeImported(imported.id)
        guard try !FileIconStore.imported().contains(where: { $0.id == imported.id }) else { throw SmokeError.unexpectedResult }
        print("PASS: file-icon library ordering, names, enable states, and custom-icon removal")

        print("PASS: PNG/JPG/WebP/HEIC/ICNS, macOS icons, exact iPhone/iPad/Watch PNG sizes, Xcode assets and custom-icon restore")
    }
}
