import Foundation
import Darwin

enum UsageScope: String, Codable, CaseIterable, Identifiable {
    case systemDisk, allDisks
    var id: String { rawValue }
    var title: String { self == .systemDisk ? "系统磁盘" : "全部磁盘" }
}

/// Direct-distribution builds execute file operations in the host app; the Finder extension stays sandboxed.
enum FileAccessPolicy {
    static var usesDirectAccess: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SuperMenuDirectFileAccess") as? Bool == true
    }

    static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        usesDirectAccess ? [.withoutImplicitSecurityScope] : [.withSecurityScope]
    }

    static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        usesDirectAccess ? [.withoutUI] : [.withSecurityScope, .withoutUI]
    }

    static func allows(_ url: URL, settings: Settings) -> Bool {
        guard url.isFileURL else { return false }
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        let canonical = suffix.reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL
        if settings.usageScope == .allDisks { return true }
        if canonical.pathComponents.starts(with: ["/", "Volumes"]) { return false }
        // Also cover disks mounted at a custom location rather than under /Volumes.
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return !mounted.contains { volume in
            let root = volume.resolvingSymlinksInPath().standardizedFileURL
            guard root.path != "/", !root.pathComponents.starts(with: ["/", "System", "Volumes"]) else { return false }
            return canonical.pathComponents.starts(with: root.pathComponents)
        }
    }

    static func monitoredDirectories(settings: Settings) -> Set<URL> {
        guard usesDirectAccess else {
            return Set(settings.folders.filter { settings.disabledFolderPaths?.contains($0.path) != true }
                .map { URL(fileURLWithPath: $0.path, isDirectory: true) })
        }
        var roots: Set<URL> = [URL(fileURLWithPath: "/", isDirectory: true)]
        // Register the real home explicitly: the sandbox home is the extension's
        // container, and relying on / alone leaves Finder's existing windows
        // waiting for root observation to propagate on a cold launch.
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            let userHome = URL(fileURLWithPath: String(cString: home), isDirectory: true)
            roots.insert(userHome)
            for name in ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"] {
                roots.insert(userHome.appendingPathComponent(name, isDirectory: true))
            }
        }
        if settings.usageScope == .allDisks {
            roots.formUnion(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                                 options: [.skipHiddenVolumes]) ?? [])
        }
        return roots
    }
}
