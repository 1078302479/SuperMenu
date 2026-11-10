import AppKit
import CryptoKit
import Darwin

enum ToolboxActions {
    struct Identity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let birth: Int
        let birthNanos: Int
    }

    static func identity(_ url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Identity(device: info.st_dev, inode: info.st_ino,
                        birth: info.st_birthtimespec.tv_sec, birthNanos: info.st_birthtimespec.tv_nsec)
    }

    static func setHidden(_ hidden: Bool, at url: URL) throws {
        if !hidden, url.lastPathComponent.hasPrefix(".") {
            throw ToolboxError.message("名称以点开头的项目仍会隐藏。可用「显示隐藏项目」查看。")
        }
        var mutable = url
        var values = URLResourceValues()
        values.isHidden = hidden
        try mutable.setResourceValues(values)
        mutable.removeAllCachedResourceValues()
        guard try mutable.resourceValues(forKeys: [.isHiddenKey]).isHidden == hidden else {
            throw ToolboxError.message("文件系统未应用隐藏设置。")
        }
    }

    static func toggleExtension(at url: URL) throws {
        guard !url.pathExtension.isEmpty else { return }
        var mutable = url
        let hidden = try url.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension ?? false
        var values = URLResourceValues()
        values.hasHiddenExtension = !hidden
        try mutable.setResourceValues(values)
        mutable.removeAllCachedResourceValues()
        guard try mutable.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension == !hidden else {
            throw ToolboxError.message("文件系统未应用扩展名显示设置。")
        }
    }

    static func createAlias(for source: URL, in desktop: URL) throws -> URL {
        let data = try source.bookmarkData(options: [.suitableForBookmarkFile, .withoutImplicitSecurityScope])
        let manager = FileManager.default
        let staging = desktop.appendingPathComponent(".supermenu-alias-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let pending = staging.appendingPathComponent("alias")
        try NSURL.writeBookmarkData(data, to: pending, options: 0)
        for index in 1...9999 {
            let suffix = index == 1 ? "" : " \(index)"
            let name = "\(source.lastPathComponent) 替身\(suffix)"
            let output = desktop.appendingPathComponent(name)
            if renamex_np(pending.path, output.path, UInt32(RENAME_EXCL)) == 0 { return output }
            guard errno == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        throw SuperMenuError.noFileName
    }

    static func rename(_ source: URL, to name: String, expected: Identity) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains(":"), name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw SuperMenuError.invalidFileName
        }
        guard try identity(source) == expected else { throw ToolboxError.message("项目已变化，请重新预览名称。") }
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        guard target.path != source.path else { return source }
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return target
    }

    static func permanentlyDelete(_ source: URL, expected: Identity) throws {
        guard source.path != "/", try identity(source) == expected else { throw SuperMenuError.invalidTarget }
        let resource = try source.resourceValues(forKeys: [.isVolumeKey, .isDirectoryKey])
        guard resource.isVolume != true else { throw ToolboxError.message("不能彻底删除磁盘卷根目录。") }
        if resource.isDirectory == true {
            var rootInfo = stat()
            guard lstat(source.path, &rootInfo) == 0 else { throw SuperMenuError.invalidTarget }
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil,
                                                                  errorHandler: { _, _ in false }) else {
                throw SuperMenuError.invalidTarget
            }
            for case let child as URL in enumerator {
                try Task.checkCancellation()
                var info = stat()
                guard lstat(child.path, &info) == 0, info.st_dev == rootInfo.st_dev else {
                    throw ToolboxError.message("目录中存在不可读取的项目或挂载卷，请先检查。")
                }
            }
        }
        // Claim the confirmed item before removal, so a same-path replacement is retained.
        let manager = FileManager.default
        let staging = source.deletingLastPathComponent().appendingPathComponent(".supermenu-delete-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let claimed = staging.appendingPathComponent(source.lastPathComponent)
        guard renamex_np(source.path, claimed.path, UInt32(RENAME_EXCL)) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            try? manager.removeItem(at: staging)
            throw error
        }
        guard try identity(claimed) == expected else {
            if renamex_np(claimed.path, source.path, UInt32(RENAME_EXCL)) == 0 {
                try? manager.removeItem(at: staging)
            }
            throw ToolboxError.message("项目在确认后发生变化，请检查 \(claimed.path)。")
        }
        do {
            try manager.removeItem(at: claimed)
            _ = rmdir(staging.path)
        } catch {
            _ = renamex_np(claimed.path, source.path, UInt32(RENAME_EXCL))
            _ = rmdir(staging.path)
            throw ToolboxError.message("删除未完成，部分内容可能已删除。请检查 \(source.path) 和 \(staging.path)。\n\(error.localizedDescription)")
        }
    }

    private static let gb18030 = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    private static let dos437 = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
    static let repairEncodings: [(title: String, source: String.Encoding, destination: String.Encoding)] = [
        ("Latin-1 → UTF-8", .isoLatin1, .utf8),
        ("Windows-1252 → UTF-8", .windowsCP1252, .utf8),
        ("Mac Roman → UTF-8", .macOSRoman, .utf8),
        ("GB18030 → UTF-8", gb18030, .utf8),
        ("Latin-1 → GB18030", .isoLatin1, gb18030),
        ("DOS CP437 → GB18030", dos437, gb18030),
    ]

    static func repairName(_ name: String, encoding: String.Encoding, destination: String.Encoding = .utf8) -> String? {
        guard let bytes = name.data(using: encoding, allowLossyConversion: false),
              let decoded = String(data: bytes, encoding: destination), !decoded.isEmpty else { return nil }
        return decoded
    }

    static func fileInformation(at url: URL, checksum: FileChecksum? = nil, progress: @Sendable (Int64, Int64) -> Void = { _, _ in }) throws -> String {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .creationDateKey,
                                        .contentModificationDateKey, .typeIdentifierKey, .isHiddenKey]
        let values = try url.resourceValues(forKeys: keys)
        let sizeDescription = values.isDirectory == true ? "目录，未递归统计" : "\(values.fileSize ?? 0) 字节"
        var lines = ["名称  \(url.lastPathComponent)", "路径  \(url.path)",
                     "类型  \(values.typeIdentifier ?? "未知")",
                     "大小  \(sizeDescription)",
                     "隐藏  \(values.isHidden == true ? "是" : "否")"]
        let formatter = ISO8601DateFormatter()
        if let date = values.creationDate { lines.append("创建  \(formatter.string(from: date))") }
        if let date = values.contentModificationDate { lines.append("修改  \(formatter.string(from: date))") }
        guard values.isRegularFile == true else {
            if checksum != nil { throw SuperMenuError.invalidTarget }
            return lines.joined(separator: "\n")
        }
        let original = try identity(url)
        var beforeStat = stat()
        guard lstat(url.path, &beforeStat) == 0 else { throw SuperMenuError.invalidTarget }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256(), sha512 = SHA512()
        let algorithms = Set(checksum.map { [$0] } ?? FileChecksum.allCases)
        var read: Int64 = 0
        let size = Int64(values.fileSize ?? 0)
        while true {
            try Task.checkCancellation()
            guard let data = try file.read(upToCount: 1 << 20), !data.isEmpty else { break }
            if algorithms.contains(.md5) { md5.update(data: data) }
            if algorithms.contains(.sha1) { sha1.update(data: data) }
            if algorithms.contains(.sha256) { sha256.update(data: data) }
            if algorithms.contains(.sha512) { sha512.update(data: data) }
            read += Int64(data.count)
            progress(read, size)
        }
        let after = try url.resourceValues(forKeys: keys)
        var afterStat = stat()
        guard try identity(url) == original, after.fileSize == values.fileSize,
              after.contentModificationDate == values.contentModificationDate,
              lstat(url.path, &afterStat) == 0,
              beforeStat.st_ctimespec.tv_sec == afterStat.st_ctimespec.tv_sec,
              beforeStat.st_ctimespec.tv_nsec == afterStat.st_ctimespec.tv_nsec else {
            throw ToolboxError.message("读取期间文件发生变化，请重新计算校验值。")
        }
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
            digest.map { String(format: "%02x", $0) }.joined()
        }
        lines.append("")
        if algorithms.contains(.md5) { lines.append("MD5  \(hex(md5.finalize()))") }
        if algorithms.contains(.sha1) { lines.append("SHA1  \(hex(sha1.finalize()))") }
        if algorithms.contains(.sha256) { lines.append("SHA256  \(hex(sha256.finalize()))") }
        if algorithms.contains(.sha512) { lines.append("SHA512  \(hex(sha512.finalize()))") }
        return lines.joined(separator: "\n")
    }
}

enum ToolboxError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
