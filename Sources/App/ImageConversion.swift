import AppKit
import ImageIO
import UniformTypeIdentifiers
import CWebP
import Darwin

enum ImageConversion {
    struct Options: Codable {
        var quality = 0.9
        var background: ImageBackground = .white
    }

    static let maxPixels = 40_000_000

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maxPixels / height else {
            throw ToolboxError.message("图片无法读取，或像素总数超过 4000 万。")
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw ToolboxError.message("图片解码失败。") }
        return image
    }

    static func convert(_ source: URL, to format: ImageFormat, options: Options, outputFolder: URL? = nil) throws -> URL {
        try Task.checkCancellation()
        let image = try load(source)
        let folder = outputFolder ?? source.deletingLastPathComponent()
        let manager = FileManager.default
        let staging = folder.appendingPathComponent(".supermenu-image-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let stem = source.deletingPathExtension().lastPathComponent
        let pending = staging.appendingPathComponent("output." + format.outputExtension)
        switch format {
        case .macOS, .iOS:
            try exportIconSet(image, format: format, into: pending, background: options.background)
        case .icns:
            try encodeICNS(image, to: pending)
        case .webp:
            try encodeWebP(image, to: pending, quality: options.quality)
        case .png, .jpg, .heic:
            let output = format == .png ? image : try canvas(image, width: image.width, height: image.height,
                                                            opaque: true, background: options.background)
            let type: CFString = format == .png ? UTType.png.identifier as CFString
                : (format == .jpg ? UTType.jpeg.identifier : UTType.heic.identifier) as CFString
            try encode(output, type: type, to: pending, quality: options.quality)
        }
        try Task.checkCancellation()
        for index in 1...9999 {
            let suffix = index == 1 ? "" : " \(index)"
            let name = "\(stem)\(suffix).\(format.outputExtension)"
            guard name.utf8.count <= 255 else { throw SuperMenuError.invalidFileName }
            let target = folder.appendingPathComponent(name)
            if renamex_np(pending.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            guard errno == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        throw SuperMenuError.noFileName
    }

    static func canvas(_ source: CGImage, width: Int, height: Int, opaque: Bool = false,
                       background: ImageBackground = .white) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
                                        | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ToolboxError.message("无法分配图片缓冲区。")
        }
        if opaque {
            context.setFillColor(gray: background == .white ? 1 : 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let scale = min(Double(width) / Double(source.width), Double(height) / Double(source.height))
        let size = CGSize(width: Double(source.width) * scale, height: Double(source.height) * scale)
        let rect = CGRect(x: (Double(width) - size.width) / 2, y: (Double(height) - size.height) / 2,
                          width: size.width, height: size.height)
        context.interpolationQuality = .high
        context.draw(source, in: rect)
        guard let image = context.makeImage() else { throw ToolboxError.message("图片绘制失败。") }
        return image
    }

    static func encode(_ image: CGImage, type: CFString, to url: URL, quality: Double = 0.9) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw ToolboxError.message("此系统未提供所选格式的编码器。")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ToolboxError.message("图片编码失败，原图片仍在原处。") }
    }

    private static func encodeWebP(_ image: CGImage, to url: URL, quality: Double) throws {
        // Draw into an explicit RGBA buffer so channel ordering is independent of AppKit.
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let encoded: Data = try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw ToolboxError.message("无法分配 WebP 缓冲区。")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let rgba = buffer.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: rgba.count, by: 4) {
                let alpha = Int(rgba[offset + 3])
                if alpha > 0 && alpha < 255 {
                    for channel in 0..<3 { rgba[offset + channel] = UInt8(min(255, Int(rgba[offset + channel]) * 255 / alpha)) }
                }
            }
            var output: UnsafeMutablePointer<UInt8>?
            let count = WebPEncodeRGBA(rgba.baseAddress, Int32(image.width), Int32(image.height),
                                       Int32(image.width * 4), Float(quality * 100), &output)
            guard count > 0, let output else { throw ToolboxError.message("WebP 编码失败。") }
            defer { WebPFree(output) }
            return Data(bytes: output, count: count)
        }
        try encoded.write(to: url, options: .withoutOverwriting)
    }

    private static let macSizes: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
    private static let deviceIconSizes: [(String, [Int])] = [
        ("iPhone", [29, 40, 58, 57, 114, 120, 180]),
        ("iPad", [29, 40, 50, 58, 80, 100, 72, 76, 144, 153, 160]),
        ("Apple Watch", [48, 55, 58, 87, 80, 88, 172, 196]),
    ]

    private static func exportIconSet(_ image: CGImage, format: ImageFormat, into folder: URL,
                                      background: ImageBackground) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        if format == .macOS {
            for (points, scale) in macSizes {
                try Task.checkCancellation()
                let size = points * scale
                let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
                try encode(canvas(image, width: size, height: size), type: UTType.png.identifier as CFString,
                           to: folder.appendingPathComponent(name))
            }
        } else {
            for (device, sizes) in deviceIconSizes {
                let group = folder.appendingPathComponent(device, isDirectory: true)
                try FileManager.default.createDirectory(at: group, withIntermediateDirectories: false)
                for size in sizes {
                    try Task.checkCancellation()
                    try encode(canvas(image, width: size, height: size, opaque: true, background: background),
                               type: UTType.png.identifier as CFString,
                               to: group.appendingPathComponent("\(size)x\(size).png"))
                }
            }
            try exportXcodeIconSet(image, into: folder.appendingPathComponent("AppIcon.appiconset", isDirectory: true),
                                   background: background)
        }
    }

    private static func exportXcodeIconSet(_ image: CGImage, into folder: URL, background: ImageBackground) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let specifications: [(String, String, [Int])] = [
            ("iphone", "20", [2,3]), ("iphone", "29", [2,3]), ("iphone", "40", [2,3]), ("iphone", "60", [2,3]),
            ("ipad", "20", [1,2]), ("ipad", "29", [1,2]), ("ipad", "40", [1,2]), ("ipad", "76", [1,2]),
            ("ipad", "83.5", [2]), ("ios-marketing", "1024", [1]),
        ]
        var manifest: [[String: String]] = []
        for (idiom, points, scales) in specifications {
            for scale in scales {
                try Task.checkCancellation()
                let size = Int(Double(points)! * Double(scale))
                let name = "\(idiom)_\(points)_\(scale)x.png"
                try encode(canvas(image, width: size, height: size, opaque: true, background: background),
                           type: UTType.png.identifier as CFString, to: folder.appendingPathComponent(name))
                manifest.append(["idiom": idiom, "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
            }
        }
        let contents: [String: Any] = ["images": manifest, "info": ["version": 1, "author": "增强右键"]]
        try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("Contents.json"))
    }

    private static func encodeICNS(_ image: CGImage, to url: URL) throws {
        var body = Data()
        let representations = [(16,"icp4"),(32,"ic11"),(32,"icp5"),(64,"ic12"),(128,"ic07"),
                               (256,"ic13"),(256,"ic08"),(512,"ic14"),(512,"ic09"),(1024,"ic10")]
        for (size, tag) in representations {
            try Task.checkCancellation()
            let square = try canvas(image, width: size, height: size)
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
                throw ToolboxError.message("ICNS 图片编码失败。")
            }
            CGImageDestinationAddImage(destination, square, nil)
            guard CGImageDestinationFinalize(destination) else { throw ToolboxError.message("ICNS 图片编码失败。") }
            body.append(Data(tag.utf8))
            var length = UInt32(bytes.length + 8).bigEndian
            body.append(Data(bytes: &length, count: 4))
            body.append(bytes as Data)
        }
        var output = Data("icns".utf8)
        var length = UInt32(body.count + 8).bigEndian
        output.append(Data(bytes: &length, count: 4))
        output.append(body)
        try output.write(to: url, options: .withoutOverwriting)
    }
}
