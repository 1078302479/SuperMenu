import AppKit

@MainActor
final class ServiceRouter: NSObject {
    let text: TextServices
    private var busy = false

    init(text: TextServices) { self.text = text }

    @objc func translateWithBaidu(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard permits(.baidu, error: error) else { return }
        text.translateWithBaidu(pasteboard, userData: userData, error: error)
    }
    @objc func translateWithGoogle(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard permits(.google, error: error) else { return }
        text.translateWithGoogle(pasteboard, userData: userData, error: error)
    }
    @objc func generateQRCode(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard permits(.qrCode, error: error) else { return }
        text.generateQRCode(pasteboard, userData: userData, error: error)
    }

    private func permits(_ kind: TextServiceKind, error: AutoreleasingUnsafeMutablePointer<NSString?>) -> Bool {
        do {
            guard try SharedStore.load().textServiceEnabled(kind) else {
                error.pointee = "此功能已在 增强右键工具箱中关闭。"
                return false
            }
            return true
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
            return false
        }
    }

    @objc func processFiles(_ pasteboard: NSPasteboard, userData: String?, error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard !busy else { return }
        let values = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !values.isEmpty else { errorPointer.pointee = "请选择本地文件或已下载的云盘文件。" as NSString; return }
        busy = true
        do {
            var grants: [FolderAccess] = []
            for url in values {
                if try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus == .notDownloaded {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    throw ToolboxError.message("已请求下载云盘文件，请下载完成后重试。")
                }
                grants.append(FolderAccess(path: url.standardizedFileURL.path,
                                          bookmark: try url.bookmarkData(options: FileAccessPolicy.bookmarkCreationOptions,
                                                                        includingResourceValuesForKeys: nil, relativeTo: nil)))
            }
            let choice = NSAlert()
            choice.messageText = "增强右键文件服务"
            choice.informativeText = "已选择 \(values.count) 个项目。文件必须已下载到本地。"
            choice.addButton(withTitle: "解压")
            choice.addButton(withTitle: "压缩 ZIP")
            choice.addButton(withTitle: "转 PNG")
            choice.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            NSApp.activate(ignoringOtherApps: true)
            let operation = choice.runModal()
            guard [.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn].contains(operation)
            else { busy = false; return }
            let picker = NSOpenPanel()
            picker.title = "选择输出目录"
            picker.canChooseFiles = false
            picker.canChooseDirectories = true
            guard picker.runModal() == .OK, let output = picker.url else { busy = false; return }
            grants.append(FolderAccess(path: output.standardizedFileURL.path,
                                      bookmark: try output.bookmarkData(options: FileAccessPolicy.bookmarkCreationOptions,
                                                                       includingResourceValuesForKeys: nil, relativeTo: nil)))
            output.stopAccessingSecurityScopedResource()
            let settings = Settings(usageScope: try SharedStore.load().usageScope, folders: grants)
            Task {
                defer { busy = false }
                do {
                    let result = try await Task.detached(priority: .userInitiated) { () -> [String] in
                        let lease = try ScopedSelection(values + [output], settings: settings)
                        defer { withExtendedLifetime(lease) {} }
                        let sources = Array(lease.urls.dropLast())
                        guard let destination = lease.urls.last else { throw SuperMenuError.invalidTarget }
                        if operation == .alertSecondButtonReturn {
                            return [try ArchiveActions.compress(sources, sevenZip: false, into: destination).path]
                        }
                        var results: [String] = []
                        for source in sources {
                            do {
                                try Task.checkCancellation()
                                let result: URL
                                if operation == .alertFirstButtonReturn {
                                    result = try ArchiveActions.extract(source, into: destination)
                                } else {
                                    result = try ImageConversion.convert(source, to: .png, options: .init(), outputFolder: destination)
                                }
                                results.append("已导出 " + result.path)
                            } catch is CancellationError {
                                results.append("已取消，已完成的输出保留。")
                                break
                            } catch { results.append(source.lastPathComponent + " · " + error.localizedDescription) }
                        }
                        return results
                    }.value
                    let done = NSAlert()
                    done.messageText = "文件服务完成"
                    done.informativeText = result.prefix(10).joined(separator: "\n")
                    done.runModal()
                } catch { NSAlert(error: error).runModal() }
            }
        } catch {
            busy = false
            errorPointer.pointee = error.localizedDescription as NSString
        }
    }
}
