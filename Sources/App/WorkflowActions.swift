import Foundation
import Darwin

enum WorkflowActions {
    struct DissolveEntry {
        let source: URL
        let identity: ToolboxActions.Identity
        let hasConflict: Bool
    }

    struct DissolvePreview {
        let folder: URL
        let parent: URL
        let folderIdentity: ToolboxActions.Identity
        let parentIdentity: ToolboxActions.Identity
        let entries: [DissolveEntry]

        var conflicts: [String] { entries.filter(\.hasConflict).map { $0.source.lastPathComponent } }
    }

    struct DissolveResult {
        let moved: [URL]
        let failures: [String]
        let removedFolder: Bool

        var summary: String {
            let state = removedFolder ? "原文件夹已移除。" : "原文件夹已保留。"
            return (["已移出 \(moved.count) 项，\(failures.count) 项失败。\(state)"] + failures).joined(separator: "\n")
        }
    }

    static func grantOwnerWrite(at url: URL) throws {
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR, info.st_uid == getuid() else {
            throw ToolboxError.message("仅能授予当前用户拥有的普通文件或文件夹写入权限。")
        }
        let permissions = (info.st_mode & 0o7777) | S_IWUSR
        guard permissions != info.st_mode & 0o7777 else { return }
        guard fchmod(descriptor, permissions) == 0 else { throw posixError() }
    }

    static func dissolvePreview(_ folder: URL) throws -> DissolvePreview {
        let folder = folder.standardizedFileURL
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isVolumeKey])
        guard folder.path != "/", values.isDirectory == true, values.isSymbolicLink != true,
              values.isPackage != true, values.isVolume != true else {
            throw ToolboxError.message("请选择普通文件夹。应用包、磁盘卷和替身不能解散。")
        }
        let parent = folder.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        let entries = try contents.map { child in
            let target = parent.appendingPathComponent(child.lastPathComponent)
            var metadata = stat()
            let conflict = lstat(target.path, &metadata) == 0
            return DissolveEntry(source: child, identity: try ToolboxActions.identity(child), hasConflict: conflict)
        }
        return DissolvePreview(folder: folder, parent: parent,
                               folderIdentity: try ToolboxActions.identity(folder),
                               parentIdentity: try ToolboxActions.identity(parent), entries: entries)
    }

    static func dissolve(_ preview: DissolvePreview) throws -> DissolveResult {
        guard try ToolboxActions.identity(preview.folder) == preview.folderIdentity,
              try ToolboxActions.identity(preview.parent) == preview.parentIdentity else {
            throw ToolboxError.message("文件夹位置在预览后发生变化，请重新预览。")
        }
        var moved: [URL] = []
        var failures: [String] = []
        for entry in preview.entries {
            if Task.isCancelled {
                failures.append("已取消，已移出的 \(moved.count) 项保留，剩余项目仍在原文件夹。")
                return DissolveResult(moved: moved, failures: failures, removedFolder: false)
            }
            do {
                guard try ToolboxActions.identity(entry.source) == entry.identity else {
                    throw ToolboxError.message("项目在预览后发生变化，已保留。")
                }
                guard let output = try FileTransfer.transferItem(entry.source, into: preview.parent,
                                                                 mode: .move, conflict: .keepBoth) else {
                    throw ToolboxError.message("项目未移出，已保留。")
                }
                moved.append(output)
            } catch {
                failures.append("\(entry.source.lastPathComponent) · \(error.localizedDescription)")
            }
        }
        var removed = false
        if failures.isEmpty {
            guard try ToolboxActions.identity(preview.folder) == preview.folderIdentity else {
                throw ToolboxError.message("已移出 \(moved.count) 项。原文件夹位置发生变化，请检查。")
            }
            removed = rmdir(preview.folder.path) == 0
            if !removed {
                failures.append("原文件夹仍包含新加入的项目，或暂时无法移除。")
            }
        }
        return DissolveResult(moved: moved, failures: failures, removedFolder: removed)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
