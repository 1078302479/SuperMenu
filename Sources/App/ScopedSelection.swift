import Foundation

final class ScopedSelection {
    let urls: [URL]
    private var scopes: [URL] = []

    init(_ inputs: [URL], settings: Settings) throws {
        if FileAccessPolicy.usesDirectAccess {
            urls = try inputs.map { input in
                try FileActions.withAuthorizedURL(input, settings: settings, rejectSymbolicLink: true) { $0 }
            }
            return
        }
        var held: [URL] = []
        do {
            for grant in settings.folders where inputs.contains(where: {
                FileActions.contains($0, in: URL(fileURLWithPath: grant.path))
            }) {
                var stale = false
                guard let scope = try? URL(resolvingBookmarkData: grant.bookmark, options: [.withSecurityScope, .withoutUI],
                                           relativeTo: nil, bookmarkDataIsStale: &stale),
                      !stale, scope.startAccessingSecurityScopedResource() else { continue }
                held.append(scope)
            }
            var resolved: [URL] = []
            for input in inputs {
                let url = input.resolvingSymlinksInPath().standardizedFileURL
                guard held.contains(where: { FileActions.contains(url, in: $0.resolvingSymlinksInPath()) }),
                      FileManager.default.fileExists(atPath: url.path),
                      try input.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw SuperMenuError.chooseFolder
                }
                resolved.append(url)
            }
            scopes = held
            urls = resolved
        } catch {
            held.forEach { $0.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    deinit { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
}
