import Foundation
import Darwin

actor CutTransfer {
    typealias Access = @Sendable (URL, Settings, Bool, (URL) throws -> Void) throws -> Void
    private let access: Access

    init(access: @escaping Access = { url, settings, rejectLink, operation in
        try FileActions.withAuthorizedURL(url, settings: settings, rejectSymbolicLink: rejectLink, perform: operation)
    }) {
        self.access = access
    }

    func cut(_ selection: [URL]) throws {
        let settings = try SharedStore.load()
        guard settings.isEnabled(.cut) else { throw SuperMenuError.cutUnavailable }
        var seen: Set<String> = []
        var items: [CutItem] = []
        for url in selection {
            let source = url.standardizedFileURL
            guard source.path != "/" else { throw SuperMenuError.invalidTarget }
            guard seen.insert(source.path).inserted else { continue }
            try access(source, settings, true) { resolved in
                items.append(CutItem(path: source.path, identity: try Self.identity(of: resolved)))
            }
        }
        guard !items.isEmpty else { throw SuperMenuError.invalidTarget }
        // Cut only the parent if both it and a descendant are selected in Finder search.
        var roots = items.filter { item in
            var parent = URL(fileURLWithPath: item.path).deletingLastPathComponent()
            while !parent.path.isEmpty && parent.path != "/" {
                if seen.contains(parent.path) { return false }
                parent.deleteLastPathComponent()
            }
            return true
        }
        let previous = try CutState.load()
        var deferred: [CutItem]?
        var recoveryFailure: CutVisibilityFailures?
        if let previous, previous.needsVisibilityRecovery {
            (deferred, recoveryFailure) = try restore(previous, settings: settings)
        }
        if settings.hidesCutItems == true {
            for index in roots.indices {
                let item = roots[index]
                try access(URL(fileURLWithPath: item.path), settings, true) { resolved in
                    let info = try Self.metadata(of: resolved)
                    guard try Self.identity(of: info) == item.identity else { throw SuperMenuError.cutSourceChanged }
                    let isHidden = try resolved.resourceValues(forKeys: [.isHiddenKey]).isHidden == true
                    if info.st_flags & UInt32(UF_HIDDEN) == 0, !isHidden, !resolved.lastPathComponent.hasPrefix(".") {
                        roots[index].hiddenBookmark = try resolved.bookmarkData(options: [.withoutImplicitSecurityScope])
                    }
                }
            }
        }
        var id: Int
        repeat { id = Int.random(in: 1...Int(Int32.max)) } while id == previous?.id
        var batch = CutBatch(id: id, created: Date(), items: roots, deferredRecovery: deferred)
        // Save recovery information before changing any filesystem flags.
        try CutState.save(batch)
        var failed = 0
        var details: [String] = []
        for index in batch.items.indices where batch.items[index].hiddenBookmark != nil {
            let item = batch.items[index]
            let source = URL(fileURLWithPath: item.path)
            do {
                try access(source, settings, true) { try Self.setHidden(true, for: item, at: $0) }
            } catch {
                failed += 1
                if details.count < 5 { details.append("\(source.lastPathComponent) · \(error.localizedDescription)") }
                batch.items[index].hiddenBookmark = nil
            }
        }
        if failed > 0 {
            try CutState.save(batch)
            throw CutVisibilityFailures(message: "已记录剪切，\(failed) 项无法隐藏。仍可粘贴这些项目。", details: details)
        }
        if let recoveryFailure {
            throw CutVisibilityFailures(message: "已记录新的剪切。\(recoveryFailure.message)", details: recoveryFailure.details)
        }
    }

    func paste(into destination: URL, batchID: Int) throws {
        let settings = try SharedStore.load()
        guard settings.isEnabled(.pasteCut), var batch = try CutState.pending(), batch.id == batchID else {
            throw SuperMenuError.cutUnavailable
        }
        var pending: [CutItem] = []
        var completed = 0
        var failed = 0
        var skipped = 0
        var details: [String] = []
        var changed = false
        try access(destination, settings, false) { target in
            guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw SuperMenuError.invalidTarget
            }
            for var item in batch.items {
                let source = URL(fileURLWithPath: item.path)
                do {
                    var moved = false
                    try access(source, settings, true) { resolved in
                        guard try Self.identity(of: resolved) == item.identity else {
                            throw SuperMenuError.cutSourceChanged
                        }
                        if item.hiddenBookmark != nil {
                            try Self.setHidden(false, for: item, at: resolved)
                            item.hiddenBookmark = nil
                            changed = true
                        }
                        moved = try FileTransfer.transferItem(resolved, into: target, mode: .move,
                                                              conflict: settings.conflictPolicy ?? .keepBoth) != nil
                    }
                    if moved {
                        completed += 1
                    } else {
                        skipped += 1
                        pending.append(item)
                    }
                } catch {
                    failed += 1
                    if details.count < 5 {
                        let reason: String
                        if case SuperMenuError.invalidTarget = error {
                            reason = "源项目不存在或已移出授权目录。"
                        } else {
                            reason = error.localizedDescription
                        }
                        details.append("\(source.lastPathComponent) · \(reason)")
                    }
                    if case SuperMenuError.cutSourceChanged = error, item.hiddenBookmark == nil { continue }
                    if case SuperMenuError.crossVolumeSourceRetained = error { continue }
                    if case SuperMenuError.crossVolumeCleanupFailed = error { continue }
                    pending.append(item)
                }
            }
        }
        if changed || pending.count != batch.items.count {
            batch.items = pending
            do { try CutState.save(batch) }
            catch { throw SuperMenuError.cutStateUpdateFailed(completed) }
        }
        if failed > 0 || skipped > 0 {
            var lines = ["已粘贴 \(completed) 项，\(failed) 项失败。"]
            if skipped > 0 { lines.append("同名跳过 \(skipped) 项。") }
            if !pending.isEmpty { lines.append("仍有 \(pending.count) 项可在修正问题后重试。") }
            throw TransferNotice(lines: lines + details)
        }
    }

    func cancel(batchID: Int) throws {
        guard let batch = try CutState.load(), batch.id == batchID,
              batch.isPending() || batch.needsVisibilityRecovery else { throw SuperMenuError.cutUnavailable }
        if let failure = try restore(batch, settings: SharedStore.load()).failure { throw failure }
    }

    func recoverExpired(now: Date = Date()) throws {
        guard let batch = try CutState.load(), !batch.isPending(now: now), batch.needsVisibilityRecovery else { return }
        if let failure = try restore(batch, settings: SharedStore.load()).failure { throw failure }
    }

    private func restore(_ original: CutBatch, settings: Settings) throws -> (pending: [CutItem]?, failure: CutVisibilityFailures?) {
        let toRestore = original.items.filter { $0.hiddenBookmark != nil } + (original.deferredRecovery ?? [])
        var batch = original
        batch.cancelled = true
        batch.items = []
        batch.deferredRecovery = toRestore.isEmpty ? nil : toRestore
        try CutState.save(batch)
        var remaining: [CutItem] = []
        var details: [String] = []
        for item in toRestore {
            do {
                try restoreVisibility(item, settings: settings)
            } catch {
                remaining.append(item)
                if details.count < 5 {
                    details.append("\(URL(fileURLWithPath: item.path).lastPathComponent) · \(error.localizedDescription)")
                }
            }
        }
        let pending = remaining.isEmpty ? nil : remaining
        if remaining.count != toRestore.count {
            batch.deferredRecovery = pending
            try CutState.save(batch)
        }
        guard !remaining.isEmpty else { return (nil, nil) }
        return (pending, CutVisibilityFailures(message: "\(remaining.count) 项尚未恢复。请确认原项目及目录授权，再试一次。", details: details))
    }

    private func restoreVisibility(_ item: CutItem, settings: Settings) throws {
        let source = URL(fileURLWithPath: item.path)
        do {
            try access(source, settings, true) { try Self.setHidden(false, for: item, at: $0) }
        } catch let originalError {
            // If Finder moved or renamed the item, try its bookmark and verify the identity again.
            var stale = false
            if let bookmark = item.hiddenBookmark,
               let relocated = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                        relativeTo: nil, bookmarkDataIsStale: &stale),
               relocated.standardizedFileURL.path != source.standardizedFileURL.path {
                do {
                    try access(relocated, settings, true) { try Self.setHidden(false, for: item, at: $0) }
                    return
                } catch SuperMenuError.cutSourceChanged {
                    // A bookmark can resolve to a replacement. Search only the original parent.
                }
            }
            try access(source.deletingLastPathComponent(), settings, false) { parent in
                let siblings = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                guard let match = siblings.first(where: { (try? Self.identity(of: $0)) == item.identity }) else {
                    throw originalError
                }
                try Self.setHidden(false, for: item, at: match)
            }
        }
    }

    private static func setHidden(_ hidden: Bool, for item: CutItem, at url: URL) throws {
        // Use the same descriptor to check identity and update the flag.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard try identity(of: info) == item.identity else { throw SuperMenuError.cutSourceChanged }
        let mask = UInt32(UF_HIDDEN)
        let flags = hidden ? (info.st_flags | mask) : (info.st_flags & ~mask)
        guard flags != info.st_flags else { return }
        guard fchflags(descriptor, flags) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private static func metadata(of url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return info
    }

    private static func identity(of url: URL) throws -> CutItem.Identity {
        try identity(of: metadata(of: url))
    }

    private static func identity(of info: stat) throws -> CutItem.Identity {
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else { throw SuperMenuError.unsupportedCopySource }
        return CutItem.Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                                birthSeconds: Int64(info.st_birthtimespec.tv_sec),
                                birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }
}

private struct CutVisibilityFailures: LocalizedError {
    let message: String
    let details: [String]

    var errorDescription: String? { ([message] + details).joined(separator: "\n") }
}
