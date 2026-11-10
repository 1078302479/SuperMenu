import Foundation

enum TemplateImportError: LocalizedError {
    case regularFileRequired, tooLarge, duplicate, capacity

    var errorDescription: String? {
        switch self {
        case .regularFileRequired: return "请选择一个普通文件作为模板。"
        case .tooLarge: return "单个模板不能超过 10 MB。"
        case .duplicate: return "已有同名模板，请移除旧模板或更换文件名。"
        case .capacity: return "最多可以保存 50 个自定义模板。"
        }
    }
}

enum TemplateStore {
    private static let maximumBytes = 10_000_000

    static func importFile(_ source: URL, into settings: Settings) throws -> Settings {
        var library = settings.customTemplates ?? CustomTemplateLibrary()
        guard library.entries.count < 50, library.nextID > 0, library.nextID < Int.max else {
            throw TemplateImportError.capacity
        }
        let name = source.lastPathComponent
        guard !library.entries.contains(where: { $0.fileName.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw TemplateImportError.duplicate
        }
        let metadata = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true else { throw TemplateImportError.regularFileRequired }
        guard (metadata.fileSize ?? 0) <= maximumBytes else { throw TemplateImportError.tooLarge }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var data = Data()
        while let chunk = try input.read(upToCount: min(262_144, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw TemplateImportError.tooLarge }
        }

        let entry = CustomTemplate(id: library.nextID, fileName: name)
        let destination = try templateURL(for: entry)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // This ID is unused in the current index. Replace an orphan from an interrupted import.
        try data.write(to: destination, options: .atomic)
        library.entries.append(entry)
        library.nextID += 1
        var updated = settings
        updated.customTemplates = library
        do {
            try SharedStore.save(updated)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return updated
    }

    static func remove(_ entry: CustomTemplate, from settings: Settings) throws -> Settings {
        var updated = settings
        updated.customTemplates?.entries.removeAll { $0.id == entry.id }
        let contents = try templateURL(for: entry)
        try SharedStore.save(updated)
        try? FileManager.default.removeItem(at: contents)
        return updated
    }

    static func createDocument(from entry: CustomTemplate, in folder: URL) throws -> URL {
        let contents = try Data(contentsOf: templateURL(for: entry))
        return try FileActions.createDocument(named: entry.fileName, contents: contents, in: folder)
    }

    private static func templateURL(for entry: CustomTemplate) throws -> URL {
        try SharedStore.directory()
            .appendingPathComponent("Templates", isDirectory: true)
            .appendingPathComponent(String(entry.id))
    }
}
