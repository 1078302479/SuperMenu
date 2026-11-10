import AppKit

@MainActor
final class IntegrationController {
    private var busy = false
    let textServices = TextServices()

    func openApplication(_ entry: ApplicationEntry, urls: [URL], settings: Settings) async throws {
        let scope = try ScopedSelection(urls, settings: settings)
        defer { withExtendedLifetime(scope) {} }
        try await ApplicationLauncher.open(entry: entry, urls: scope.urls,
                                            mode: settings.terminalModes?[entry.bundleID] ?? settings.terminalMode ?? .systemDefault)
    }

    func perform(_ action: FinderAction, urls: [URL], settings: Settings) async throws {
        guard !busy else { throw ToolboxError.message("上一项操作仍在处理中，请稍后重试。") }
        busy = true
        defer { busy = false }
        let scope = try ScopedSelection(urls, settings: settings)
        defer { withExtendedLifetime(scope) {} }
        switch action {
        case .setWallpaper:
            guard let image = scope.urls.first, scope.urls.count == 1 else { throw SuperMenuError.invalidTarget }
            _ = try ImageConversion.load(image)
            for screen in NSScreen.screens { try NSWorkspace.shared.setDesktopImageURL(image, for: screen, options: [:]) }
        case .grantWrite:
            try await Task.detached(priority: .userInitiated) {
                var errors: [String] = []
                for url in scope.urls {
                    do { try WorkflowActions.grantOwnerWrite(at: url) }
                    catch { errors.append(url.lastPathComponent + " · " + error.localizedDescription) }
                }
                if !errors.isEmpty { throw TransferNotice(lines: errors) }
            }.value
        case .dissolveFolder:
            guard scope.urls.count == 1, let folder = scope.urls.first else { throw SuperMenuError.invalidTarget }
            let parentScope = try ScopedSelection([folder.deletingLastPathComponent()], settings: settings)
            defer { withExtendedLifetime(parentScope) {} }
            let preview = try await Task.detached(priority: .userInitiated) { try WorkflowActions.dissolvePreview(folder) }.value
            let alert = NSAlert()
            alert.messageText = "解散「\(folder.lastPathComponent)」？"
            let conflicts = preview.conflicts.isEmpty ? "没有同名冲突。" : "以下同名项目将自动编号：\n" + preview.conflicts.prefix(10).joined(separator: "\n")
            alert.informativeText = "将 \(preview.entries.count) 个项目移到\n\(preview.parent.path)\n\n\(conflicts)\n完成后移除空文件夹，失败项目保留。"
            alert.addButton(withTitle: "解散文件夹")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let result = try await OperationProgress.run(title: "解散文件夹") { try WorkflowActions.dissolve(preview) }
            if !result.failures.isEmpty || !result.removedFolder { throw ToolboxError.message(result.summary) }
        case .compressZIP, .compress7z, .extractArchive:
            let inputs = scope.urls
            let parents = inputs.map { $0.deletingLastPathComponent() }
            let outputScope = try ScopedSelection(parents, settings: settings)
            defer { withExtendedLifetime(outputScope) {} }
            let result = try await OperationProgress.run(title: action.title) { () -> [String] in
                do {
                    if action != .extractArchive {
                        let output = try ArchiveActions.compress(inputs, sevenZip: action == .compress7z, into: parents[0])
                        return ["已导出 " + output.path]
                    }
                    var results: [String] = []
                    for input in inputs {
                        if Task.isCancelled { results.append("已取消，已完成的输出保留。"); break }
                        do {
                            let output = try ArchiveActions.extract(input, into: input.deletingLastPathComponent())
                            results.append("已解压 " + output.path)
                        } catch is CancellationError {
                            results.append("已取消，已完成的输出保留。")
                            break
                        } catch { results.append(input.lastPathComponent + " · " + error.localizedDescription) }
                    }
                    return results
                } catch is CancellationError { return ["已取消，已完成的输出保留。"] }
                catch { return [error.localizedDescription] }
            }
            let alert = NSAlert()
            alert.messageText = action.title
            alert.informativeText = result.prefix(12).joined(separator: "\n")
            alert.runModal()
        case .iShotCapture, .iShotAnnotate, .diskMap, .openFastZip:
            let kind: ExternalToolKind = action == .diskMap ? .diskMap : (action == .openFastZip ? .fastZip : .iShot)
            guard ApplicationLauncher.installedURL(for: kind) != nil else {
                throw ToolboxError.message("尚未安装 \(kind.title)。可在「应用与联动」查看安装入口。")
            }
            let alert = NSAlert()
            alert.messageText = "在 \(kind.title) 中继续"
            alert.informativeText = kind.capabilityDescription
            alert.addButton(withTitle: "打开应用")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try await ApplicationLauncher.openTool(kind, urls: scope.urls)
        default: throw SuperMenuError.invalidTarget
        }
    }
}
