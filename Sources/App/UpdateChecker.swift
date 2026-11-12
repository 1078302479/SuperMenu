import AppKit
import SwiftUI

struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let draft: Bool
    let prerelease: Bool
    var assets: [ReleaseAsset]? = nil

    static func version(_ value: String) -> [Int]? {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        return numbers + Array(repeating: 0, count: 4 - numbers.count)
    }

    func isNewer(than current: String) -> Bool {
        guard !draft, !prerelease, let available = Self.version(tag_name), let installed = Self.version(current) else { return false }
        return installed.lexicographicallyPrecedes(available)
    }

    var page: URL? {
        guard let url = URL(string: html_url), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/1078302479/SuperMenu/releases/tag/") else { return nil }
        return url
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var status = ""
    @Published private(set) var downloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var availableRelease: GitHubRelease?
    @Published private(set) var preparedUpdate: PreparedUpdate?
    private var downloadTask: Task<Void, Never>?
    private var downloadDirectory: URL?
    private let defaults = UserDefaults.standard
    private var notifiedTag: String?
    private let lastCheckKey = "lastSuccessfulUpdateCheck"

    func check(automatically: Bool = false, enabled: Bool = true) {
        guard !checking, !downloading, preparedUpdate == nil, !automatically || enabled else { return }
        if automatically, let last = defaults.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        checking = true
        if !automatically { status = "正在检查更新…" }
        Task {
            defer { checking = false }
            do {
                let release = try await Self.fetchLatestRelease()
                guard let page = release.page, GitHubRelease.version(release.tag_name) != nil else {
                    throw ToolboxError.message("更新信息格式不正确。")
                }
                defaults.set(Date(), forKey: lastCheckKey)
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                guard release.isNewer(than: current) else {
                    availableRelease = nil
                    status = "当前已是最新版本（\(current)）"
                    return
                }
                availableRelease = release
                status = "发现新版本 \(release.tag_name)"
                if automatically && notifiedTag == release.tag_name { return }
                notifiedTag = release.tag_name
                let alert = NSAlert()
                alert.messageText = "增强右键有新版本"
                alert.informativeText = "当前版本 \(current)，最新版本 \(release.tag_name)。"
                if (try? UpdatePackage(release: release, architecture: Self.architecture)) != nil {
                    alert.addButton(withTitle: "下载更新")
                    alert.addButton(withTitle: "稍后")
                    if alert.runLocalizedModal() == .alertFirstButtonReturn { downloadAvailableUpdate() }
                } else {
                    alert.addButton(withTitle: "前往下载")
                    alert.addButton(withTitle: "稍后")
                    if alert.runLocalizedModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
                }
            } catch {
                if !automatically { status = "检查失败，\(error.localizedDescription)" }
            }
        }
    }
    /// The public release page remains usable when shared-IP API quotas are exhausted.
    static func releaseFromPage(_ url: URL?) -> GitHubRelease? {
        guard let url, url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let prefix = "/1078302479/SuperMenu/releases/tag/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let tag = String(url.path.dropFirst(prefix.count))
        guard GitHubRelease.version(tag) != nil else { return nil }
        return GitHubRelease(tag_name: tag, html_url: url.absoluteString, draft: false, prerelease: false)
    }

    static func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/1078302479/SuperMenu/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("EnhancedRightClick", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1_000_000 {
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                if release.page != nil, GitHubRelease.version(release.tag_name) != nil { return release }
            }
        } catch { /* Try the official website before reporting a network failure. */ }
        request.url = URL(string: "https://github.com/1078302479/SuperMenu/releases/latest")!
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let release = releaseFromPage(http.url) else {
            throw ToolboxError.message("更新检查暂时不可用，请前往 GitHub 发布页查看。")
        }
        return release
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    #if SUPERMENU_TEST
    func offerForTesting(_ release: GitHubRelease) {
        availableRelease = release
    }
    #endif

    func downloadAvailableUpdate() {
        guard !downloading, preparedUpdate == nil, let release = availableRelease else { return }
        if (try? UpdatePackage(release: release, architecture: Self.architecture)) == nil {
            if let page = release.page { NSWorkspace.shared.open(page) }
            return
        }
        downloading = true
        downloadProgress = 0
        status = "正在下载安装包…"
        downloadTask = Task { [self] in
            var directory: URL?
            defer { downloading = false; downloadTask = nil }
            do {
                let package = try UpdatePackage(release: release, architecture: Self.architecture)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("EnhancedRightClick-update-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                directory = root
                let downloader = UpdateDownload()
                let zip = try await downloader.download(package.archive, to: root.appendingPathComponent(package.archive.name)) { [weak self] value in
                    Task { @MainActor in self?.downloadProgress = value }
                }
                try Task.checkCancellation()
                status = "正在校验安装包…"
                var request = URLRequest(url: package.checksums.url!)
                request.timeoutInterval = 20
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (checksums, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      checksums.count == Int(package.checksums.size) else { throw ToolboxError.message("下载校验文件失败。") }
                let expected = try package.expectedHash(in: checksums)
                let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
                let prepared = try await Task.detached(priority: .utility) {
                    guard try UpdatePackage.hash(of: zip) == expected else { throw ToolboxError.message("安装包校验失败，请重新下载。") }
                    return try UpdateInstaller.prepare(archive: zip, version: version, directory: root)
                }.value
                try Task.checkCancellation()
                if let old = downloadDirectory { try? FileManager.default.removeItem(at: old) }
                downloadDirectory = root
                preparedUpdate = prepared
                status = "更新已下载并通过校验，点击「安装并重启」完成升级。"
            } catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                status = Task.isCancelled ? "已取消下载" : "下载更新失败，\(error.localizedDescription)"
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    func revealUpdate() {
        guard let preparedUpdate else { return }
        NSWorkspace.shared.activateFileViewerSelecting([preparedUpdate.app])
    }

    func installAndRelaunch() {
        guard let preparedUpdate else { return }
        let alert = NSAlert()
        alert.messageText = "安装更新并重新启动？"
        alert.informativeText = "将更新到 \(preparedUpdate.version)，保留菜单设置、自定义模板及图标。请先等待当前文件操作完成。旧应用将保留为同目录下的备份。"
        alert.addButton(withTitle: "安装并重启")
        alert.addButton(withTitle: "取消")
        guard alert.runLocalizedModal() == .alertFirstButtonReturn else { return }
        do {
            try UpdateInstaller.install(preparedUpdate)
            NSApp.terminate(nil)
        } catch {
            status = "自动替换失败，\(error.localizedDescription) 可点击「查看安装文件」手动替换。"
        }
    }

}

struct UpdatePreferencesView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var checker: UpdateChecker

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var busy: Bool { checker.checking || checker.downloading }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("软件更新", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold)).padding(.bottom, 8)
            HStack {
                Text("当前安装版本").font(.system(size: 12))
                Spacer(minLength: 8)
                Text("v" + version).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }.frame(minHeight: 43, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动检查更新").font(.system(size: 12))
                    Text("有新版本时提醒你。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("自动检查更新", isOn: Binding(
                    get: { model.settings.automaticallyChecksForUpdates ?? true },
                    set: { enabled in
                        model.setSystemPreference { $0.automaticallyChecksForUpdates = enabled }
                        checker.check(automatically: true, enabled: enabled)
                    })).labelsHidden().toggleStyle(.switch)
            }.frame(minHeight: 48, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Label("安装前会请你确认", systemImage: "checkmark.shield")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if checker.preparedUpdate != nil {
                    Button("安装并重启") { checker.installAndRelaunch() }.buttonStyle(.borderedProminent)
                } else if checker.availableRelease != nil && !busy {
                    Button("下载更新") { checker.downloadAvailableUpdate() }.buttonStyle(.borderedProminent)
                } else {
                    Button { checker.check() } label: {
                        Label {
                            Text(LocalizedStringKey(checker.checking ? "正在检查…" : "检查更新"))
                        } icon: { Image(systemName: "arrow.clockwise") }
                    }.buttonStyle(.borderedProminent).disabled(busy)
                }
            }.frame(minHeight: 47, maxHeight: .infinity).controlSize(.small)
            if checker.downloading {
                VStack(spacing: 5) {
                    ProgressView(value: checker.downloadProgress)
                    HStack {
                        Text("\(Int(checker.downloadProgress * 100))%").monospacedDigit()
                        Spacer()
                        Button("取消下载") { checker.cancelDownload() }.buttonStyle(.plain).foregroundStyle(.blue)
                    }.font(.caption)
                }.padding(.top, 6)
            }
            if !checker.status.isEmpty {
                Text(InterfaceText.current(checker.status)).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 5)
            }
            if checker.preparedUpdate != nil {
                Button("查看安装文件") { checker.revealUpdate() }.buttonStyle(.link).font(.caption).padding(.top, 4)
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}
