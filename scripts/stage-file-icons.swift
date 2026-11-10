import AppKit

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let bundle = Bundle(url: source) else { exit(0) }
let assets = ["App", "Apple", "Book", "Calendar", "Cloud", "Excel", "File", "Google", "Mac_OS1", "Mac_OS2",
              "Mac", "Mail", "Music", "Pages", "Picture", "PPT", "QQ", "Video", "WeChat", "Word"]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for name in assets {
    guard let image = bundle.image(forResource: NSImage.Name(name)),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Missing reference folder icon: \(name)\n", stderr)
        exit(1)
    }
    try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
}
