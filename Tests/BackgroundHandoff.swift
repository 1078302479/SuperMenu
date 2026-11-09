import AppKit

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
                  request.action == .newText, request.template == .xml, request.paths.count == 1 else {
                throw SmokeError.unexpectedRequest
            }
            let fixture = try SharedStore.directory().appendingPathComponent("fixture", isDirectory: true)
            guard request.paths == [fixture.path] else { throw SmokeError.unexpectedRequest }
            let output = try FileActions.createDocument(.xml, in: fixture)
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
    @MainActor static func main() {
        if CommandLine.arguments.count == 2 {
            let app = URL(fileURLWithPath: CommandLine.arguments[1])
            do { try send(to: app) }
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

    @MainActor private static func send(to app: URL) throws {
        let fixture = try SharedStore.directory().appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        try verifyTemplates(in: fixture)
        let original = fixture.appendingPathComponent("新建 XML 文档.xml")
        let contents = Data("保留原内容".utf8)
        try contents.write(to: original)

        let request = FinderRequest(action: .newText, paths: [fixture.path], created: Date(), template: .xml)
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
                guard name == "新建 XML 文档 2.xml",
                      XMLParser(contentsOf: newFile)?.parse() == true,
                      try Data(contentsOf: original) == contents else { throw SmokeError.unexpectedResult }
                print("PASS: background template handoff, valid XML and no overwrite, stale and replay rejection")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw SmokeError.timedOut
    }

    private static func verifyTemplates(in fixture: URL) throws {
        let legacyJSON = Data(#"{"folders":[],"enabled":["newText","copyPath"]}"#.utf8)
        var settings = try JSONDecoder().decode(Settings.self, from: legacyJSON)
        guard settings.visibleTemplates == DocumentTemplate.allCases,
              settings.enabled == [.newText, .copyPath] else { throw SmokeError.unexpectedResult }
        settings.enabledTemplates = []
        let reloaded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        guard reloaded.visibleTemplates.isEmpty else { throw SmokeError.unexpectedResult }

        let txt = try FileActions.createDocument(.text, in: fixture)
        let markdown = try FileActions.createDocument(.markdown, in: fixture)
        let rtf = try FileActions.createDocument(.richText, in: fixture)
        guard txt.pathExtension == "txt", try Data(contentsOf: txt).isEmpty,
              markdown.pathExtension == "md", try Data(contentsOf: markdown).isEmpty,
              rtf.pathExtension == "rtf",
              NSAttributedString(rtf: try Data(contentsOf: rtf), documentAttributes: nil) != nil else {
            throw SmokeError.unexpectedResult
        }
        print("PASS: legacy settings, disabled templates, TXT, Markdown and readable RTF")
    }
}
