import AppKit
import FinderSync
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings = Settings()
    @Published private(set) var storageAvailable = false
    @Published private(set) var extensionEnabled = false
    @Published var message = ""
    @Published var showsMessage = false
    @Published var page: SettingsPage? = .overview

    init() { refresh() }

    func refresh() {
        extensionEnabled = FIFinderSyncController.isExtensionEnabled
        do {
            settings = try SharedStore.load()
            storageAvailable = true
        } catch {
            storageAvailable = false
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "添加要使用 SuperMenu 的目录"
        panel.prompt = "添加目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        do {
            // Keep the picker URL and its sandbox grant when creating the bookmark.
            let bookmark = try picked.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
            let path = picked.standardizedFileURL.path
            var next = settings
            next.folders.removeAll { $0.path == path }
            next.folders.append(FolderAccess(path: path, bookmark: bookmark))
            save(next)
        } catch {
            report(error, context: "无法保存目录授权")
        }
    }

    func remove(_ folder: FolderAccess) {
        var next = settings
        next.folders.removeAll { $0.id == folder.id }
        save(next)
    }

    func setEnabled(_ action: FinderAction, _ enabled: Bool) {
        var next = settings
        if enabled { next.enabled.insert(action) } else { next.enabled.remove(action) }
        save(next)
    }

    func setTemplateEnabled(_ template: DocumentTemplate, _ enabled: Bool) {
        var next = settings
        var templates = Set(next.visibleTemplates)
        if enabled { templates.insert(template) } else { templates.remove(template) }
        next.enabledTemplates = templates
        save(next)
    }

    func perform(_ request: FinderRequest) throws {
        let current = try SharedStore.load()
        guard current.enabled.contains(request.action), !request.paths.isEmpty,
              request.action == .copyPath || request.paths.count == 1,
              request.paths.allSatisfy({ $0.hasPrefix("/") }) else { throw SuperMenuError.invalidTarget }
        let urls = request.paths.map { URL(fileURLWithPath: $0) }

        switch request.action {
        case .copyPath:
            for url in urls {
                try FileActions.withAuthorizedURL(url, settings: current) { _ in }
            }
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            guard clipboard.setString(request.paths.joined(separator: "\n"), forType: .string) else {
                throw SuperMenuError.clipboard
            }
        case .newText:
            let template = request.template ?? .text
            guard current.visibleTemplates.contains(template) else { throw SuperMenuError.templateDisabled }
            try FileActions.withAuthorizedURL(urls[0], settings: current) { url in
                guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw SuperMenuError.invalidTarget
                }
                _ = try FileActions.createDocument(template, in: url)
            }
        case .openTerminal:
            try FileActions.withAuthorizedURL(urls[0], settings: current) { url in
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                let folder = isDirectory ? url : url.deletingLastPathComponent()
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                    throw SuperMenuError.terminalUnavailable
                }
                NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: .init()) { [weak self] _, error in
                    if let error { Task { @MainActor in self?.report(error) } }
                }
            }
        }
    }

    func report(_ error: Error, context: String? = nil) {
        let detail = error as NSError
        if let context {
            message = "\(context)：\(detail.localizedDescription)（\(detail.domain) \(detail.code)）"
        } else {
            message = detail.localizedDescription
        }
        showsMessage = true
    }

    private func save(_ next: Settings) {
        do {
            try SharedStore.save(next)
            settings = next
            storageAvailable = true
        } catch { report(error, context: "无法写入共享配置") }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview = "通用设置"
    case templates = "新建文件"
    case folders = "目录授权"
    case actions = "右键菜单"

    var id: Self { self }
    var icon: String {
        switch self {
        case .overview: return "gearshape"
        case .templates: return "doc.badge.plus"
        case .folders: return "folder"
        case .actions: return "cursorarrow.click"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 38, height: 38)
                    VStack(alignment: .leading) {
                        Text("SuperMenu").font(.headline)
                        Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") 开发预览").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 14)
                List(SettingsPage.allCases, selection: $model.page) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 155, ideal: 175)
        } detail: {
            Form {
                switch model.page ?? .overview {
                case .overview:
                    Section("首次使用") {
                        LabeledContent("共享配置", value: model.storageAvailable ? "可访问" : "不可访问")
                        LabeledContent("Finder 扩展", value: model.extensionEnabled ? "已启用" : "未启用")
                        Button("管理 Finder 扩展…") { FIFinderSyncController.showExtensionManagementInterface() }
                        Button("刷新状态") { model.refresh() }
                        Text("启用 SuperMenu 的 Finder 扩展，在「目录授权」添加一个测试文件夹，再在访达中打开该文件夹并右键。")
                            .foregroundStyle(.secondary)
                    }
                case .templates:
                    Section("内置模板") {
                        ForEach(DocumentTemplate.allCases) { template in
                            Toggle(isOn: Binding(get: { model.settings.visibleTemplates.contains(template) },
                                                 set: { model.setTemplateEnabled(template, $0) })) {
                                Label(template.title, systemImage: "doc")
                            }
                            .disabled(!model.storageAvailable)
                        }
                        Text("启用的格式会出现在「新建文件」子菜单中。同名文件会自动编号。")
                            .foregroundStyle(.secondary)
                    }
                case .folders:
                    Section("已授权目录") {
                        if model.settings.folders.isEmpty {
                            Text("添加目录后，该目录内可使用 SuperMenu 右键菜单。").foregroundStyle(.secondary)
                        }
                        ForEach(model.settings.folders) { folder in
                            HStack {
                                Label(folder.path, systemImage: "folder")
                                    .lineLimit(1).truncationMode(.middle).help(folder.path)
                                Spacer()
                                Button("移除") { model.remove(folder) }
                            }
                        }
                        Button("添加目录…") { model.addFolder() }.disabled(!model.storageAvailable)
                    }
                case .actions:
                    Section("显示的操作") {
                        ForEach(FinderAction.allCases) { action in
                            Toggle(isOn: Binding(get: { model.settings.enabled.contains(action) },
                                                 set: { model.setEnabled(action, $0) })) {
                                Label(action.title, systemImage: action.symbol)
                            }
                            .disabled(!model.storageAvailable)
                        }
                    }
                    Section("显示规则") {
                        Text("在目录空白处可以新建文件。选中文件时，终端打开其所在目录。多选时可一次拷贝所有路径。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle((model.page ?? .overview).rawValue)
        }
        .alert("SuperMenu", isPresented: $model.showsMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.message)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = SettingsModel()
    private var window: NSWindow?
    private var receivedRequest = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.receivedRequest else { return }
            self.showSettings()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.refresh() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedRequest = true
        for url in urls {
            do {
                if let request = try SharedStore.consume(url) { try model.perform(request) }
            } catch {
                showSettings()
                model.report(error)
            }
        }
    }

    private func showSettings() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: controller)
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.title = "SuperMenu"
            created.minSize = NSSize(width: 540, height: 340)
            created.setContentSize(NSSize(width: 700, height: 460))
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct SuperMenuApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .aqua)
        app.run()
    }
}
