import Foundation
import CArchive
import Darwin

enum ArchiveActions {
    static func compress(_ sources: [URL], sevenZip: Bool, into folder: URL) throws -> URL {
        guard !sources.isEmpty else { throw SuperMenuError.invalidTarget }
        for source in sources where try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            if FileActions.contains(folder.resolvingSymlinksInPath(), in: source.resolvingSymlinksInPath()) {
                throw SuperMenuError.recursiveCopy
            }
        }
        let manager = FileManager.default
        let staging = folder.appendingPathComponent(".supermenu-archive-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let output = staging.appendingPathComponent("archive")
        guard let writer = archive_write_new() else { throw ToolboxError.message("压缩器初始化失败。") }
        defer { archive_write_free(writer) }
        try check(sevenZip ? archive_write_set_format_7zip(writer) : archive_write_set_format_zip(writer), archive: writer)
        try check(archive_write_open_filename(writer, output.path), archive: writer)
        var used: Set<String> = []
        for source in sources {
            var name = source.lastPathComponent
            var number = 1
            while !used.insert(name).inserted {
                number += 1
                name = source.deletingPathExtension().lastPathComponent + " \(number)" +
                    (source.pathExtension.isEmpty ? "" : "." + source.pathExtension)
            }
            try add(source, path: name, writer: writer, rootDevice: metadata(source).st_dev)
        }
        try check(archive_write_close(writer), archive: writer)
        let name = sources.count == 1 ? sources[0].deletingPathExtension().lastPathComponent : "归档"
        return try publish(output, name: name, ext: sevenZip ? "7z" : "zip", folder: folder)
    }

    private static func add(_ source: URL, path: String, writer: OpaquePointer, rootDevice: Int32) throws {
        try Task.checkCancellation()
        let info = try metadata(source)
        guard info.st_dev == rootDevice else { throw ToolboxError.message("目录包含挂载卷，请分别压缩。") }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else {
            throw ToolboxError.message("压缩暂不包含符号链接或特殊文件，请移除后重试。")
        }
        guard let entry = archive_entry_new() else { throw ToolboxError.message("压缩条目初始化失败。") }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname(entry, path)
        archive_entry_set_filetype(entry, UInt32(kind))
        archive_entry_set_perm(entry, info.st_mode & 0o777)
        archive_entry_set_size(entry, kind == S_IFREG ? info.st_size : 0)
        archive_entry_set_mtime(entry, info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec)
        try check(archive_write_header(writer, entry), archive: writer)
        if kind == S_IFDIR {
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try add(child, path: path + "/" + child.lastPathComponent, writer: writer, rootDevice: rootDevice)
            }
            let after = try metadata(source)
            guard info.st_dev == after.st_dev, info.st_ino == after.st_ino,
                  info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw ToolboxError.message("压缩时源目录发生变化，请重试。")
            }
        } else {
            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            while let bytes = try file.read(upToCount: 1 << 20), !bytes.isEmpty {
                try Task.checkCancellation()
                let count = bytes.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
                guard count == bytes.count else { throw archiveError(writer) }
            }
            let after = try metadata(source)
            guard info.st_ino == after.st_ino, info.st_size == after.st_size,
                  info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw ToolboxError.message("压缩时源文件发生变化，请重试。")
            }
        }
    }

    static func extract(_ source: URL, into folder: URL) throws -> URL {
        guard let reader = archive_read_new() else { throw ToolboxError.message("解压器初始化失败。") }
        defer { archive_read_free(reader) }
        try check(archive_read_support_filter_all(reader), archive: reader)
        try check(archive_read_support_format_all(reader), archive: reader)
        try check(archive_read_open_filename(reader, source.path, 1 << 20), archive: reader)
        let staging = folder.appendingPathComponent(".supermenu-extract-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let pending = staging.appendingPathComponent("result", isDirectory: true)
        try manager.createDirectory(at: pending, withIntermediateDirectories: false)
        var entry: OpaquePointer?
        var count = 0
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try Task.checkCancellation()
            let status = archive_read_next_header(reader, &entry)
            if status == 1 { break }
            try check(status, archive: reader)
            guard let entry, let raw = archive_entry_pathname(entry) else { throw archiveError(reader) }
            let path = String(cString: raw)
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(".."),
                  !path.contains("\\"), !path.contains(":"),
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil else {
                throw ToolboxError.message("归档含不安全路径或链接，已停止解压。")
            }
            let safe = parts.filter { $0 != "." }
            if safe.isEmpty { continue }
            let output = safe.reduce(pending) { $0.appendingPathComponent($1) }
            let kind = archive_entry_filetype(entry) & mode_t(S_IFMT)
            count += 1
            guard count <= 100_000 else { throw ToolboxError.message("归档条目超过十万项，已停止解压。") }
            if kind == mode_t(S_IFDIR) {
                try manager.createDirectory(at: output, withIntermediateDirectories: true)
                continue
            }
            guard kind == mode_t(S_IFREG), archive_entry_size(entry) >= 0 else {
                throw ToolboxError.message("归档包含暂不支持的特殊条目。")
            }
            try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: output, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            let file = try FileHandle(forWritingTo: output)
            do {
                while true {
                    try Task.checkCancellation()
                    let bytes = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                    if bytes == 0 { break }
                    guard bytes > 0 else { throw archiveError(reader) }
                    total += Int64(bytes)
                    guard total <= 16 * 1024 * 1024 * 1024 else { throw ToolboxError.message("解压内容超过 16 GB，已停止。") }
                    try file.write(contentsOf: Data(buffer.prefix(bytes)))
                }
                try file.close()
                try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(archive_entry_mtime(entry)))],
                                          ofItemAtPath: output.path)
            } catch {
                try? file.close()
                throw error
            }
        }
        guard count > 0 else { throw ToolboxError.message("归档中没有可解压的项目。") }
        return try publish(pending, name: source.deletingPathExtension().lastPathComponent, ext: "", folder: folder)
    }

    private static func publish(_ source: URL, name: String, ext: String, folder: URL) throws -> URL {
        for number in 1...9999 {
            let suffix = number == 1 ? "" : " \(number)"
            let filename = name + suffix + (ext.isEmpty ? "" : "." + ext)
            guard filename.utf8.count <= 255 else { throw SuperMenuError.invalidFileName }
            let output = folder.appendingPathComponent(filename)
            if renamex_np(source.path, output.path, UInt32(RENAME_EXCL)) == 0 { return output }
            guard errno == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        throw SuperMenuError.noFileName
    }

    private static func metadata(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return info
    }

    private static func check(_ status: Int32, archive: OpaquePointer) throws {
        guard status >= 0 else { throw archiveError(archive) }
    }

    private static func archiveError(_ archive: OpaquePointer) -> ToolboxError {
        let detail = archive_error_string(archive).map(String.init(cString:)) ?? "未知归档错误"
        return .message(detail)
    }
}
