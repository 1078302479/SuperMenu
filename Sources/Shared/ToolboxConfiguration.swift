import Foundation

enum TextServiceKind: String, CaseIterable, Identifiable {
    case baidu, google, qrCode
    var id: Self { self }
    var title: String {
        switch self {
        case .baidu: return "百度翻译"
        case .google: return "谷歌翻译"
        case .qrCode: return "转换成二维码"
        }
    }
}

enum ToolboxItem: Hashable, Identifiable {
    case action(FinderAction), image(ImageFormat), application(String), text(TextServiceKind)
    var id: String {
        switch self {
        case .action(let action): return "action:" + action.rawValue
        case .image(let format): return "image:" + format.rawValue
        case .application(let id): return "application:" + id
        case .text(let service): return "text:" + service.rawValue
        }
    }
}

extension Settings {
    var toolboxItems: [ToolboxItem] {
        // Order recorded from the reference settings table, rather than the enum declaration order.
        let actions: [FinderAction] = [.fileInfo, .desktopAlias, .airDrop, .copyName, .folderFromName,
            .cut, .dissolveFolder, .setWallpaper, .iShotAnnotate, .iShotCapture, .copyPath,
            .addFavorite, .deletePermanently, .grantWrite, .showHiddenFiles, .hideHiddenFiles,
            .showSelected, .hideSelected, .toggleExtension, .repairNames]
        let formats: [ImageFormat] = [.webp, .heic, .jpg, .png, .icns, .macOS, .iOS]
        let defaults = actions.map(ToolboxItem.action) + formats.map(ToolboxItem.image)
            + (applications ?? ApplicationCatalog.entries).map { ToolboxItem.application($0.id) }
            + [FinderAction.compress7z, .compressZIP, .extractArchive, .diskMap].map(ToolboxItem.action)
            + TextServiceKind.allCases.map(ToolboxItem.text)
        let known = Dictionary(defaults.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return ((toolboxItemOrder ?? []).compactMap { known[$0] } + defaults).filter { seen.insert($0.id).inserted }
    }

    mutating func moveToolboxItem(_ source: String, to target: String) {
        var order = toolboxItems.map(\.id)
        guard let sourceIndex = order.firstIndex(of: source), let targetIndex = order.firstIndex(of: target),
              sourceIndex != targetIndex else { return }
        order.insert(order.remove(at: sourceIndex), at: targetIndex)
        toolboxItemOrder = order
        var seen: Set<FinderAction> = []
        actionOrder = toolboxItems.compactMap { item -> FinderAction? in
            let action: FinderAction?
            switch item {
            case .action(let value): action = value
            case .image: action = .convertImage
            case .application(let id):
                let entry = (applications ?? ApplicationCatalog.entries).first { $0.id == id }
                action = entry?.bundleID == "com.apple.Terminal" ? .openTerminal : .openWithApp
            case .text: action = nil
            }
            guard let action, seen.insert(action).inserted else { return nil }
            return action
        }
        let appIDs = toolboxItems.compactMap { if case .application(let id) = $0 { return id }; return nil }
        let entries = applications ?? ApplicationCatalog.entries
        applications = appIDs.compactMap { id in entries.first { $0.id == id } }
    }

    var orderedImageFormats: [ImageFormat] {
        toolboxItems.compactMap { if case .image(let format) = $0 { return format }; return nil }
    }

    func imageMenuName(_ format: ImageFormat) -> String {
        let name = toolboxDisplayNames?[ToolboxItem.image(format).id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "转为 " + format.title : name
    }

    func textServiceEnabled(_ kind: TextServiceKind) -> Bool {
        enabledTextServices?.contains(kind.rawValue) ?? true
    }
}
