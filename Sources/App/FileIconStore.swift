import AppKit
import CryptoKit
import Darwin

enum FileIconStore {
    private static let lock = NSLock()
    static let presets = ["blue", "green", "orange", "purple", "pink", "gray"]

    typealias Imported = FileIconEntry

    private struct Backup: Codable {
        let identity: ToolboxActions.Identity
        let image: Data?
    }

    static func imported() throws -> [Imported] { try FileIconLibrary.imported() }

    static func removeImported(_ id: String) throws {
        let entries = try imported()
        guard UUID(uuidString: id) != nil, entries.contains(where: { $0.id == id }) else { return }
        let root = try directory()
        try JSONEncoder().encode(entries.filter { $0.id != id })
            .write(to: root.appendingPathComponent("Library.json"), options: .atomic)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id + ".png"))
    }

    static func importImage(_ source: URL) throws -> Imported {
        let image = try ImageConversion.load(source)
        let entry = Imported(id: UUID().uuidString, name: source.deletingPathExtension().lastPathComponent)
        let url = try directory().appendingPathComponent(entry.id + ".png")
        try ImageConversion.encode(image, type: "public.png" as CFString, to: url)
        var entries = try imported()
        entries.append(entry)
        do {
            try JSONEncoder().encode(entries).write(to: directory().appendingPathComponent("Library.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return entry
    }

    static func image(_ id: String) throws -> NSImage {
        if presets.contains(id) { return preset(id) }
        let entries = FileIconLibrary.presets + (try imported())
        guard let entry = entries.first(where: { $0.id == id }), let image = FileIconLibrary.image(entry) else {
            throw ToolboxError.message("图标资源缺失，请重新导入。")
        }
        return image
    }

    static func apply(_ icon: NSImage, to target: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = try backupURL(target)
        let identity = try ToolboxActions.identity(target)
        let previous: Backup?
        do { previous = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: key)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { previous = nil }
        if previous?.identity != identity {
            let custom = try hasCustomIcon(target)
            let original = custom ? NSWorkspace.shared.icon(forFile: target.path).tiffRepresentation : nil
            if custom && original == nil { throw ToolboxError.message("原图标备份失败，无法应用新图标。") }
            try JSONEncoder().encode(Backup(identity: identity, image: original)).write(to: key, options: .atomic)
        }
        guard NSWorkspace.shared.setIcon(icon, forFile: target.path, options: []) else {
            throw ToolboxError.message("无法设置图标，请检查文件写入权限。")
        }
    }

    static func restore(_ target: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = try backupURL(target)
        let data: Data
        do { data = try Data(contentsOf: key) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw ToolboxError.message("没有找到 增强右键的原图标备份。")
        }
        let backup = try JSONDecoder().decode(Backup.self, from: data)
        guard try ToolboxActions.identity(target) == backup.identity else {
            throw ToolboxError.message("原位置已换成其他项目，请重新设置图标。")
        }
        let image = backup.image.flatMap(NSImage.init(data:))
        if backup.image != nil && image == nil { throw ToolboxError.message("原图标备份无法读取。") }
        guard NSWorkspace.shared.setIcon(image, forFile: target.path, options: []) else {
            throw ToolboxError.message("恢复图标失败，请检查文件写入权限。")
        }
        try FileManager.default.removeItem(at: key)
    }

    static func removeCustomIcon(_ target: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard try hasCustomIcon(target) else { return }
        let key = try backupURL(target)
        guard NSWorkspace.shared.setIcon(nil, forFile: target.path, options: []) else {
            throw ToolboxError.message("无法删除自定义图标，请检查文件写入权限。")
        }
        try? FileManager.default.removeItem(at: key)
    }

    private static func backupURL(_ target: URL) throws -> URL {
        // Identity survives rename and same-volume moves.
        let identity = try ToolboxActions.identity(target)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(identity)
        let key = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return try directory().appendingPathComponent("backup-" + key + ".json")
    }

    static func hasCustomIcon(_ target: URL) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = bytes.withUnsafeMutableBytes {
            getxattr(target.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        if count < 0 {
            if errno == ENOATTR { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return count >= 10 && bytes[8] & 0x04 != 0
    }

    private static func directory() throws -> URL {
        let url = try FileIconLibrary.directory()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func preset(_ name: String) -> NSImage {
        let colors: [String: NSColor] = [
            "blue": .systemBlue, "green": .systemGreen, "orange": .systemOrange,
            "purple": .systemPurple, "pink": .systemPink, "gray": .systemGray,
        ]
        let color = colors[name] ?? .systemBlue
        let image = NSImage(size: NSSize(width: 512, height: 512))
        image.lockFocus()
        color.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 142, width: 416, height: 260), xRadius: 32, yRadius: 32).fill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 352, width: 174, height: 70), xRadius: 22, yRadius: 22).fill()
        let path = NSBezierPath(roundedRect: NSRect(x: 38, y: 90, width: 436, height: 270), xRadius: 34, yRadius: 34)
        NSGradient(starting: color.blended(withFraction: 0.2, of: .white) ?? color, ending: color)?.draw(in: path, angle: -90)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 3
        path.stroke()
        image.unlockFocus()
        return image
    }
}
