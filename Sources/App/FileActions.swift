import AppKit

enum FileActions {
    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootParts = root.standardizedFileURL.pathComponents
        return candidate.standardizedFileURL.pathComponents.starts(with: rootParts)
    }

    static func withAuthorizedURL<T>(_ candidate: URL, settings: Settings, rejectSymbolicLink: Bool = false,
                                     perform: (URL) throws -> T) throws -> T {
        if FileAccessPolicy.usesDirectAccess {
            guard FileAccessPolicy.allows(candidate, settings: settings) else {
                throw ToolboxError.message("此位置不在当前使用范围内，请在通用设置中选择「全部磁盘」。")
            }
            if rejectSymbolicLink, try candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw SuperMenuError.unsupportedCopySource
            }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard FileManager.default.fileExists(atPath: resolved.path) else { throw SuperMenuError.invalidTarget }
            return try perform(resolved)
        }
        let roots = settings.folders
            .filter { contains(candidate, in: URL(fileURLWithPath: $0.path)) }
            .sorted { $0.path.count > $1.path.count }
        guard !roots.isEmpty else { throw SuperMenuError.chooseFolder }
        for access in roots {
            var stale = false
            guard let root = try? URL(resolvingBookmarkData: access.bookmark, options: [.withSecurityScope, .withoutUI],
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
                  !stale, root.startAccessingSecurityScopedResource() else { continue }
            defer { root.stopAccessingSecurityScopedResource() }
            if rejectSymbolicLink, try candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw SuperMenuError.unsupportedCopySource
            }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard contains(resolved, in: root.resolvingSymlinksInPath()),
                  FileManager.default.fileExists(atPath: resolved.path) else { throw SuperMenuError.invalidTarget }
            return try perform(resolved)
        }
        throw SuperMenuError.staleBookmark
    }

    static func createDocument(_ template: DocumentTemplate, in folder: URL) throws -> URL {
        try createDocument(named: "\(template.fileStem).\(template.rawValue)", contents: template.contents(), in: folder)
    }

    static func copyLocationText(_ paths: [String], namesOnly: Bool, to clipboard: NSPasteboard) throws {
        let values = namesOnly ? paths.map { URL(fileURLWithPath: $0).lastPathComponent } : paths
        clipboard.clearContents()
        guard clipboard.setString(values.joined(separator: "\n"), forType: .string) else {
            throw SuperMenuError.clipboard
        }
    }

    static func createFolderFromName(of file: URL) throws -> URL {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw SuperMenuError.folderSourceMustBeFile
        }
        let filename = file.lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let name = stem == filename ? "\(stem) 文件夹" : stem
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255 else {
            throw SuperMenuError.invalidFileName
        }
        let target = file.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw SuperMenuError.folderNameConflict(name)
        }
        return target
    }

    static func createDocument(_ document: NamedDocument, in folder: URL) throws -> URL {
        let contents = try document.template?.contents() ?? Data()
        return try createDocument(named: document.fileName, contents: contents, in: folder)
    }

    static func createDocument(named name: String, contents: Data, in folder: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw SuperMenuError.invalidTarget
        }
        let fileName = name as NSString
        let fileExtension = fileName.pathExtension
        let stem = fileName.deletingPathExtension
        for number in 1...9999 {
            let numberedStem = "\(stem) \(number)"
            let candidate = number == 1 ? name : (fileExtension.isEmpty ? numberedStem : "\(numberedStem).\(fileExtension)")
            let url = folder.appendingPathComponent(candidate)
            do {
                // Exclusive creation prevents overwriting even if Finder triggers concurrent requests.
                try contents.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw SuperMenuError.noFileName
    }
}
