import Foundation

struct SavedFolder: Codable, Identifiable, Equatable {
    let id: Int
    let path: String

    var displayName: String?
    var name: String {
        let custom = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : custom
    }
}

struct SavedFolders: Codable {
    private(set) var entries: [SavedFolder] = []
    private var nextID = 1
    var showsMenu = true

    mutating func add(_ folder: FolderAccess) { add(path: folder.path) }

    mutating func add(path: String, name: String? = nil) {
        guard !entries.contains(where: { $0.path == path }), nextID < Int.max else { return }
        entries.append(SavedFolder(id: nextID, path: path, displayName: name))
        nextID += 1
    }

    mutating func rename(id: Int, to name: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].displayName = trimmed.isEmpty ? nil : trimmed
    }

    mutating func move(id: Int, to index: Int) {
        guard let source = entries.firstIndex(where: { $0.id == id }), (0...entries.count).contains(index) else { return }
        let value = entries.remove(at: source)
        entries.insert(value, at: min(index > source ? index - 1 : index, entries.count))
    }

    static func standardTransferDestinations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SavedFolders {
        var result = SavedFolders()
        result.resetTransferDestinations(home: home)
        return result
    }

    mutating func resetTransferDestinations(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        entries = []
        for (directory, title) in [("Downloads", "下载"), ("Pictures", "图片"), ("Music", "音乐"), ("Movies", "影片"), ("Documents", "文稿")] {
            add(path: home.appendingPathComponent(directory, isDirectory: true).path, name: title)
        }
    }

    mutating func relocate(_ favorite: SavedFolder, to path: String) {
        guard let index = entries.firstIndex(where: { $0.id == favorite.id }), nextID < Int.max else { return }
        if favorite.path == path { return }
        if entries.contains(where: { $0.path == path }) {
            entries.remove(at: index)
        } else {
            entries[index] = SavedFolder(id: nextID, path: path, displayName: favorite.displayName)
            nextID += 1
        }
    }

    mutating func removeAll() { entries.removeAll() }

    mutating func remove(path: String) {
        entries.removeAll { $0.path == path }
    }

    mutating func move(_ favorite: SavedFolder, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == favorite.id }),
              entries.indices.contains(index + offset) else { return }
        entries.swapAt(index, index + offset)
    }
}

extension Settings {
    mutating func initializeTransferDestinations() {
        guard transferDestinationsVersion == nil else { return }
        var existing = copyDestinations ?? SavedFolders()
        let defaults = SavedFolders.standardTransferDestinations()
        // Keep user-selected destinations and IDs while putting the reference defaults first.
        for (index, folder) in defaults.entries.enumerated() {
            existing.add(path: folder.path, name: folder.name)
            if let entry = existing.entries.first(where: { $0.path == folder.path }) {
                existing.move(id: entry.id, to: index)
            }
        }
        copyDestinations = existing
        transferDestinationsVersion = 1
    }

    var availableFavorites: [SavedFolder] {
        (favorites?.entries ?? []).filter { favorite in
            if FileAccessPolicy.usesDirectAccess { return FileAccessPolicy.allows(URL(fileURLWithPath: favorite.path), settings: self) }
            let path = URL(fileURLWithPath: favorite.path).standardizedFileURL.pathComponents
            return folders.contains { path.starts(with: URL(fileURLWithPath: $0.path).standardizedFileURL.pathComponents) }
        }
    }

    var availableCopyDestinations: [SavedFolder] {
        authorizedEntries(in: copyDestinations)
    }

    func favoriteFolder(id: Int) throws -> SavedFolder {
        guard isEnabled(.openFavorite), id > 0,
              let favorite = availableFavorites.first(where: { $0.id == id }) else {
            throw SuperMenuError.favoriteUnavailable
        }
        return favorite
    }

    func transferDestination(id: Int, action: FinderAction) throws -> SavedFolder {
        guard isEnabled(action), id > 0,
              let destination = availableCopyDestinations.first(where: { $0.id == id }) else {
            throw SuperMenuError.copyDestinationUnavailable
        }
        return destination
    }

    private func authorizedEntries(in collection: SavedFolders?) -> [SavedFolder] {
        let authorizedPaths = Set(folders.map(\.path))
        return (collection?.entries ?? []).filter {
            FileAccessPolicy.usesDirectAccess ? FileAccessPolicy.allows(URL(fileURLWithPath: $0.path), settings: self) : authorizedPaths.contains($0.path)
        }
    }
}

enum TransferConflictPolicy: String, Codable, CaseIterable, Identifiable {
    case keepBoth, replace, skip

    var id: Self { self }
    var title: String {
        switch self {
        case .keepBoth: return "保留两者（自动编号）"
        case .replace: return "替换"
        case .skip: return "跳过"
        }
    }
}

enum TransferTarget: String, Codable {
    case other, recent
}

struct RecentTransfers: Codable {
    struct Entry: Codable, Identifiable {
        let id: Int
        let folder: FolderAccess
    }

    private(set) var entries: [Entry] = []
    private var nextID = 1

    mutating func record(_ folder: FolderAccess) {
        if let index = entries.firstIndex(where: { $0.folder.path == folder.path }) {
            let id = entries.remove(at: index).id
            entries.insert(Entry(id: id, folder: folder), at: 0)
        } else if nextID < Int.max {
            entries.insert(Entry(id: nextID, folder: folder), at: 0)
            nextID += 1
        }
        if entries.count > 8 { entries.removeLast() }
    }

    mutating func remove(path: String) { entries.removeAll { $0.folder.path == path } }
    mutating func clear() { entries.removeAll() }
}
