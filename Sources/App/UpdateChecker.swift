import AppKit
import SwiftUI

struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let draft: Bool
    let prerelease: Bool

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
    private let defaults = UserDefaults.standard
    private var notifiedTag: String?
    private let lastCheckKey = "lastSuccessfulUpdateCheck"

    func check(automatically: Bool = false, enabled: Bool = true) {
        guard !checking, !automatically || enabled else { return }
        if automatically, let last = defaults.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        checking = true
        if !automatically { status = "正在检查更新…" }
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/1078302479/SuperMenu/releases/latest")!)
                request.timeoutInterval = 20
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("EnhancedRightClick", forHTTPHeaderField: "User-Agent")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 1_000_000 else {
                    throw ToolboxError.message("更新服务暂时不可用，请稍后重试。")
                }
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                guard let page = release.page, GitHubRelease.version(release.tag_name) != nil else {
                    throw ToolboxError.message("更新信息格式不正确。")
                }
                defaults.set(Date(), forKey: lastCheckKey)
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                guard release.isNewer(than: current) else {
                    status = "当前已是最新版本（\(current)）"
                    return
                }
                status = "发现新版本 \(release.tag_name)"
                if automatically && notifiedTag == release.tag_name { return }
                notifiedTag = release.tag_name
                let alert = NSAlert()
                alert.messageText = "增强右键有新版本"
                alert.informativeText = "当前版本 \(current)，最新版本 \(release.tag_name)。"
                alert.addButton(withTitle: "前往下载")
                alert.addButton(withTitle: "稍后")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
            } catch {
                if !automatically { status = "检查失败，\(error.localizedDescription)" }
            }
        }
    }
}

struct UpdatePreferencesView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        GroupBox("软件更新") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("自动检查更新", isOn: Binding(
                        get: { model.settings.automaticallyChecksForUpdates ?? true },
                        set: { enabled in
                            model.setSystemPreference { $0.automaticallyChecksForUpdates = enabled }
                            checker.check(automatically: true, enabled: enabled)
                        }))
                    Spacer()
                    Button(checker.checking ? "正在检查…" : "检查更新") { checker.check() }
                        .disabled(checker.checking)
                }
                if !checker.status.isEmpty {
                    Text(checker.status).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
