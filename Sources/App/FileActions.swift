import AppKit

enum FileActions {
    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootParts = root.standardizedFileURL.pathComponents
        return candidate.standardizedFileURL.pathComponents.starts(with: rootParts)
    }

    static func withAuthorizedURL<T>(_ candidate: URL, settings: Settings, perform: (URL) throws -> T) throws -> T {
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
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard contains(resolved, in: root.resolvingSymlinksInPath()),
                  FileManager.default.fileExists(atPath: resolved.path) else { throw SuperMenuError.invalidTarget }
            return try perform(resolved)
        }
        throw SuperMenuError.staleBookmark
    }

    static func createDocument(_ template: DocumentTemplate, in folder: URL) throws -> URL {
        let contents = template.contents
        for number in 1...9999 {
            let stem = number == 1 ? template.fileStem : "\(template.fileStem) \(number)"
            let url = folder.appendingPathComponent(stem).appendingPathExtension(template.rawValue)
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
