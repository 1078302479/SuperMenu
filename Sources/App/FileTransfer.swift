import Foundation
import Darwin
import CryptoKit

enum FileTransfer {
    enum Mode {
        case copy, move

        var action: FinderAction { self == .copy ? .copyToFolder : .moveToFolder }
        var verb: String { self == .copy ? "复制" : "移动" }
    }

    struct BatchResult {
        var completed = 0
        var skipped = 0
        var failed = 0
        var details: [String] = []

        func notice(for mode: Mode) -> TransferNotice? {
            guard skipped > 0 || failed > 0 else { return nil }
            return TransferNotice(lines: ["已\(mode.verb) \(completed) 项，跳过 \(skipped) 项，\(failed) 项失败。"] + details)
        }
    }

    static func transferSelection(_ paths: [String], into target: URL, mode: Mode, settings: Settings) throws -> BatchResult {
        guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SuperMenuError.invalidTarget
        }
        var processed = Set<String>()
        var result = BatchResult()
        for path in paths where processed.insert(path).inserted {
            let source = URL(fileURLWithPath: path)
            do {
                let output = try FileActions.withAuthorizedURL(source, settings: settings, rejectSymbolicLink: true) { resolved in
                    try transferItem(resolved, into: target, mode: mode, conflict: settings.conflictPolicy ?? .keepBoth)
                }
                if output != nil { result.completed += 1 } else { result.skipped += 1 }
            } catch {
                result.failed += 1
                if result.details.count < 5 {
                    result.details.append("\(source.lastPathComponent) · \(error.localizedDescription)")
                }
            }
        }
        return result
    }

    static func transferItem(_ source: URL, into folder: URL, mode: Mode = .copy,
                             conflict: TransferConflictPolicy = .keepBoth) throws -> URL? {
        let resource = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard resource.isSymbolicLink != true, resource.isDirectory == true || resource.isRegularFile == true else {
            throw SuperMenuError.unsupportedCopySource
        }
        if resource.isDirectory == true, isInsideSource(folder, source: source) {
            throw SuperMenuError.recursiveCopy
        }

        let name = source.lastPathComponent
        if mode == .move {
            let parent = source.deletingLastPathComponent()
            guard !sameDirectory(parent, folder) else { throw SuperMenuError.alreadyInDestination }
            if try metadata(of: source).st_dev == metadata(of: folder).st_dev {
                do { return try place(source, namedLike: source, in: folder, conflict: conflict) }
                catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EXDEV) {}
            }
        } else if conflict == .replace && sameDirectory(source.deletingLastPathComponent(), folder) {
            throw SuperMenuError.alreadyInDestination
        }
        if conflict == .skip {
            var existing = stat()
            let path = folder.appendingPathComponent(name).path
            if lstat(path, &existing) == 0 { return nil }
        }

        let original = mode == .move ? try snapshot(source) : nil
        let manager = FileManager.default
        let staging = folder.appendingPathComponent(".supermenu-copy-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }

        let pending = staging.appendingPathComponent(name)
        try manager.copyItem(at: source, to: pending)
        if let original {
            guard try snapshot(pending).mapValues(\.content) == original.mapValues(\.content),
                  try snapshot(source) == original else { throw SuperMenuError.crossVolumeVerificationFailed }
        }
        guard let output = try place(pending, namedLike: source, in: folder, conflict: conflict) else { return nil }
        if let original {
            // Check the published copy and the source again before removing any source data.
            guard (try? snapshot(output).mapValues(\.content)) == original.mapValues(\.content),
                  (try? snapshot(source)) == original else {
                throw SuperMenuError.crossVolumeSourceRetained(output.path)
            }
            try removeVerifiedSource(source, original: original, published: output)
        }
        return output
    }

    private static func place(_ pending: URL, namedLike source: URL, in folder: URL,
                              conflict: TransferConflictPolicy) throws -> URL? {
        let name = source.lastPathComponent
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        for number in 1...9999 {
            let numbered = "\(stem) \(number)"
            let candidate = number == 1 ? name : (ext.isEmpty ? numbered : "\(numbered).\(ext)")
            let output = folder.appendingPathComponent(candidate)
            if renamex_np(pending.path, output.path, UInt32(RENAME_EXCL)) == 0 { return output }
            let code = errno
            guard code == EEXIST else { throw posixError(code) }
            switch conflict {
            case .keepBoth: continue
            case .skip: return nil
            case .replace:
                // Keep the previous item intact until the new item occupies the destination.
                let backupFolder = folder.appendingPathComponent("替换备份-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                let backup = backupFolder.appendingPathComponent(name)
                do { try renameExclusively(output, to: backup) }
                catch {
                    try? FileManager.default.removeItem(at: backupFolder)
                    throw error
                }
                do {
                    try renameExclusively(pending, to: output)
                } catch let publishError {
                    do { try renameExclusively(backup, to: output) }
                    catch { throw SuperMenuError.replacementBackupKept(backup.path) }
                    try? FileManager.default.removeItem(at: backupFolder)
                    throw publishError
                }
                return output
            }
        }
        throw SuperMenuError.noFileName
    }

    private struct SnapshotEntry: Equatable {
        enum Content: Equatable { case directory, file(Data, resourceFork: Data?), link(String) }
        let content: Content
        let device: Int32
        let inode: UInt64
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    private static func removeVerifiedSource(_ source: URL, original: [Data: SnapshotEntry], published: URL) throws {
        let manager = FileManager.default
        let holding = source.deletingLastPathComponent()
            .appendingPathComponent("移动源备份-\(UUID().uuidString)", isDirectory: true)
        let claimed = holding.appendingPathComponent(source.lastPathComponent)
        do {
            try manager.createDirectory(at: holding, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do { try renameExclusively(source, to: claimed) }
            catch {
                try? manager.removeItem(at: holding)
                throw error
            }
        } catch { throw SuperMenuError.crossVolumeCleanupFailed(published.path, error.localizedDescription) }

        do {
            var captured = try snapshot(claimed)
            guard let root = captured[Data()], let originalRoot = original[Data()],
                  root.device == originalRoot.device, root.inode == originalRoot.inode,
                  root.content == originalRoot.content else { throw SuperMenuError.crossVolumeVerificationFailed }
            // Renaming updates the root's change time. Descendants must still match exactly.
            captured[Data()] = originalRoot
            guard captured == original,
                  try snapshot(published).mapValues(\.content) == original.mapValues(\.content)
            else { throw SuperMenuError.crossVolumeVerificationFailed }
        } catch {
            do { try renameExclusively(claimed, to: source) }
            catch { throw SuperMenuError.crossVolumeCleanupFailed(published.path, "源项目保留在 \(claimed.path)") }
            try? manager.removeItem(at: holding)
            throw SuperMenuError.crossVolumeSourceRetained(published.path)
        }
        do {
            try manager.removeItem(at: claimed)
            _ = rmdir(holding.path)
        }
        catch {
            throw SuperMenuError.crossVolumeCleanupFailed(published.path, "剩余源项目位于 \(holding.path)")
        }
    }

    private static func snapshot(_ root: URL) throws -> [Data: SnapshotEntry] {
        let device = try metadata(of: root).st_dev
        var entries: [Data: SnapshotEntry] = [:]
        var pending = [(root, "")]
        while let (url, relative) = pending.popLast() {
            let info = try metadata(of: url)
            guard info.st_dev == device else { throw SuperMenuError.crossVolumeVerificationFailed }
            let content: SnapshotEntry.Content
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                content = .directory
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                pending.append(contentsOf: children.map {
                    ($0, relative.isEmpty ? $0.lastPathComponent : relative + "/" + $0.lastPathComponent)
                })
            case S_IFLNK:
                content = .link(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            case S_IFREG:
                let size = getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
                if size < 0, errno != ENOATTR, errno != ENOTSUP { throw posixError(errno) }
                let forkURL = URL(fileURLWithPath: url.path + "/..namedfork/rsrc")
                let fork = size > 0 ? try digest(forkURL) : nil
                content = .file(try digest(url), resourceFork: fork)
            default: throw SuperMenuError.unsupportedCopySource
            }
            entries[Data(relative.utf8)] = SnapshotEntry(content: content, device: info.st_dev, inode: info.st_ino,
                                                         changedSeconds: info.st_ctimespec.tv_sec,
                                                         changedNanoseconds: info.st_ctimespec.tv_nsec)
        }
        return entries
    }

    private static func digest(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1 << 20), !bytes.isEmpty { hash.update(data: bytes) }
        return Data(hash.finalize())
    }

    private static func metadata(of url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError(errno) }
        return info
    }

    private static func renameExclusively(_ source: URL, to target: URL) throws {
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError(errno) }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL.path == rhs.standardizedFileURL.path { return true }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        guard let a = try? lhs.resourceValues(forKeys: keys), let b = try? rhs.resourceValues(forKeys: keys),
              let id = a.fileResourceIdentifier as? NSObject, let volume = a.volumeIdentifier as? NSObject else {
            return false
        }
        return id.isEqual(b.fileResourceIdentifier) && volume.isEqual(b.volumeIdentifier)
    }

    private static func isInsideSource(_ folder: URL, source: URL) -> Bool {
        let target = folder.resolvingSymlinksInPath()
        if FileActions.contains(target, in: source.resolvingSymlinksInPath()) { return true }

        // Compare directory identity as well as spelling, including on case-insensitive volumes.
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        guard let sourceValues = try? source.resourceValues(forKeys: keys),
              let sourceID = sourceValues.fileResourceIdentifier as? NSObject,
              let sourceVolume = sourceValues.volumeIdentifier as? NSObject else { return false }
        var ancestor = target
        while true {
            if let values = try? ancestor.resourceValues(forKeys: keys),
               sourceID.isEqual(values.fileResourceIdentifier),
               sourceVolume.isEqual(values.volumeIdentifier) { return true }
            let parent = ancestor.deletingLastPathComponent()
            guard !parent.path.isEmpty, parent.path != ancestor.path else { return false }
            ancestor = parent
        }
    }
}

struct TransferNotice: LocalizedError {
    let lines: [String]
    var errorDescription: String? { lines.joined(separator: "\n") }
}
