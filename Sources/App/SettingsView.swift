import AppKit
import CoreTransferable
import FinderSync
import SwiftUI
import UniformTypeIdentifiers

private enum TemplateDrag: Codable, Equatable, Transferable {
    case builtIn(DocumentTemplate)
    case custom(Int)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "io.github.1078302479.SuperMenu.template-row"))
            .visibility(.ownProcess)
    }
}

private struct TemplateDropTarget: ViewModifier {
    let accept: (TemplateDrag) -> Bool

    func body(content: Content) -> some View {
        content.contentShape(Rectangle())
            .dropDestination(for: TemplateDrag.self) { items, _ in
                guard items.count == 1, let item = items.first else { return false }
                return accept(item)
            }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview = "通用设置"
    case templates = "新建文件"
    case send = "发送文件到…"
    case favorites = "常用目录"
    case folderIcons = "文件（夹）图标"
    case actions = "工具箱"

    var iconName: String {
        switch self {
        case .overview: return "nav-general"
        case .templates: return "nav-templates"
        case .send: return "nav-send"
        case .favorites: return "nav-favorites"
        case .folderIcons: return "nav-file-icons"
        case .actions: return "nav-toolbox"
        }
    }

    var id: Self { self }

    var style: (symbol: String, color: UInt32, detail: String) {
        switch self {
        case .overview: return ("gearshape.fill", 0x31ACDB, "管理启动、磁盘使用范围和系统权限。")
        case .templates: return ("doc.badge.plus", 0x48B7BE, "选择常用格式，把自己的模板放进右键菜单。")
        case .send: return ("paperplane.fill", 0x69BA4A, "从访达右键菜单将文件发送到常用位置。")
        case .favorites: return ("heart.fill", 0xEC6782, "收藏常用目录，从右键菜单快速进入。")
        case .folderIcons: return ("folder.fill", 0xE7A13D, "为不同项目设置容易辨认的文件夹图标。")
        case .actions: return ("square.grid.2x2.fill", 0xCC6EB1, "选择要显示在访达右键菜单中的操作。")
        }
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255,
                  blue: Double(rgb & 255) / 255)
    }

    static let settingsFog = Color(rgb: 0xF5F6F8)
    static let settingsLine = Color(rgb: 0xE6E8EE)
    static let settingsInk = Color(rgb: 0x282C37)
    static let settingsMuted = Color(rgb: 0x6F7788)
    static let settingsAccent = Color(rgb: 0x6268CE)
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private var page: SettingsPage { model.page ?? .overview }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.settingsLine).frame(width: 1)
            VStack(alignment: .leading, spacing: 18) {
                if page != .send && page != .favorites && page != .folderIcons {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pageTitle(page)).font(.system(size: 22, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(localized(page.style.detail)).font(.system(size: 12)).foregroundStyle(Color.settingsMuted)
                }
                }
                pageContent
            }
            .padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white)
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.settingsInk)
        .tint(.blue)
        .environment(\.locale, Locale(identifier: (model.settings.interfaceLanguage ?? .system).localeIdentifier))
        .alert("增强右键", isPresented: $model.showsMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text((model.settings.interfaceLanguage ?? .system).usesEnglish ? InterfaceText.english(model.message) : model.message)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("增强右键").font(.system(size: 17, weight: .semibold))
                    Text("访达右键效率工具").font(.system(size: 11)).foregroundStyle(Color.settingsMuted)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 10)

            Text("功能设置").font(.system(size: 11)).foregroundStyle(Color.settingsMuted).padding(.leading, 11)
            VStack(spacing: 4) {
                ForEach(SettingsPage.allCases) { item in
                    let selected = item == page
                    Button { model.page = item } label: {
                        HStack(spacing: 10) {
                            Group {
                                if let icon = MenuIcons.referenceImage(named: item.iconName, size: 28) {
                                    Image(nsImage: icon).resizable()
                                } else {
                                    Image(systemName: item.style.symbol)
                                        .font(.system(size: 15)).foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(Color(rgb: item.style.color), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }.frame(width: 28, height: 28)
                            Text(pageTitle(item)).fontWeight(selected ? .semibold : .regular)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(selected ? Color.settingsAccent : .settingsInk)
                        .background(selected ? Color(rgb: 0xE9E9F6) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(alignment: .leading) {
                            if selected {
                                RoundedRectangle(cornerRadius: 2).fill(Color.settingsAccent)
                                    .frame(width: 3, height: 19)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Spacer(minLength: 12)
            Divider()
            Text(version.isEmpty ? localized("增强右键") : ((model.settings.interfaceLanguage ?? .system).usesEnglish ? "Version \(version)" : "版本 \(version)"))
                .font(.system(size: 11)).foregroundStyle(Color.settingsMuted).padding(.leading, 8)
        }
        .padding(.horizontal, 13).padding(.vertical, 21)
        .frame(width: 218)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.settingsFog)
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .overview:
            SystemPreferencesView(model: model)
        case .templates: templatesPage
        case .favorites: favoritesPage
        case .actions: toolboxPage
        case .send: sendPage
        case .folderIcons:
            folderIconsPage
        }
    }

    private func pageTitle(_ page: SettingsPage) -> String {
        (model.settings.interfaceLanguage ?? .system).usesEnglish ? InterfaceText.english(page.rawValue) : page.rawValue
    }

    private func localized(_ text: String) -> String {
        (model.settings.interfaceLanguage ?? .system).usesEnglish ? InterfaceText.english(text) : text
    }

    private var templatesPage: some View {
        let builtIn = model.settings.orderedTemplates
        let custom = model.settings.customTemplates?.entries ?? []
        return VStack(spacing: 12) {
            settingsTable(["启用", "图标", "显示名称（双击编辑 / 按住拖拽）", "后缀", "主菜单", "选项"], widths: [46, 40, nil, 50, 52, 115]) {
                namedCreationRow
                ForEach(Array(builtIn.enumerated()), id: \.element.id) { index, template in
                    templateRow(name: model.settings.templateTitle(template), ext: template.rawValue,
                                drag: .builtIn(template),
                                available: template.isAvailable,
                                enabled: Binding(get: { model.settings.visibleTemplates.contains(template) },
                                                 set: { model.setTemplateEnabled(template, $0) }),
                                promoted: Binding(get: { model.settings.promotedTemplates?.contains(template) == true },
                                                  set: { model.setTemplatePromoted(template, $0) }),
                                rename: { model.renameTemplate(template, to: $0) },
                                moveUp: index > 0 ? { model.moveTemplate(template, by: -1) } : nil,
                                moveDown: index < builtIn.count - 1 ? { model.moveTemplate(template, by: 1) } : nil)
                        .modifier(TemplateDropTarget { item in
                            guard model.storageAvailable, case .builtIn(let source) = item, source != template else { return false }
                            model.reorderTemplate(source, to: template)
                            return true
                        })
                }
                ForEach(Array(custom.enumerated()), id: \.element.id) { index, entry in
                    templateRow(name: entry.title, ext: entry.fileExtension, drag: .custom(entry.id),
                                enabled: Binding(get: { entry.enabled },
                                                 set: { model.setCustomTemplateEnabled(entry, $0) }),
                                promoted: Binding(get: { entry.showsInMainMenu == true },
                                                  set: { model.setCustomTemplatePromoted(entry, $0) }),
                                rename: { model.renameTemplate(entry, to: $0) },
                                moveUp: index > 0 ? { model.moveTemplate(entry, by: -1) } : nil,
                                moveDown: index < custom.count - 1 ? { model.moveTemplate(entry, by: 1) } : nil,
                                remove: { model.removeTemplate(entry) })
                        .modifier(TemplateDropTarget { item in
                            guard model.storageAvailable, case .custom(let source) = item, source != entry.id else { return false }
                            model.reorderTemplate(id: source, to: entry.id)
                            return true
                        })
                }
            }
            HStack(spacing: 9) {
                Button("添加模版文件") { model.importTemplate() }.disabled(!model.storageAvailable)
                Spacer()
                Button("帮助") { model.showTemplateHelp() }
                Button("右键菜单失效的解决办法 >>") { model.showTemplateTroubleshooting() }
                Button("重置") { model.resetTemplateSettings() }.disabled(!model.storageAvailable)
            }
            HStack(spacing: 16) {
                Toggle("显示图标", isOn: Binding(get: { model.settings.showsTemplateIcons ?? true },
                                              set: { value in model.setSystemPreference { $0.showsTemplateIcons = value } }))
                Toggle("新建文件后自动打开", isOn: Binding(get: { model.settings.opensNewDocuments == true },
                                                set: { model.setOpensNewDocuments($0) }))
                Toggle("开启提示音", isOn: Binding(get: { model.settings.playsCreationSound == true },
                                                set: { model.setPlaysCreationSound($0) }))
                Spacer()
            }
            .toggleStyle(.checkbox)
            .disabled(!model.storageAvailable)
            Text("访达工具栏入口：在「显示 → 自定工具栏…」中将增强右键拖入工具栏。")
                .font(.system(size: 11)).foregroundStyle(Color.settingsMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var folderIconsPage: some View {
        let entries = model.fileIconEntries
        let enabled = Binding(
            get: { entries.allSatisfy { model.settings.fileIconEnabled($0.id) } },
            set: { model.setFileIconsEnabled(entries.map(\.id), enabled: $0) }
        )
        return VStack(alignment: .leading, spacing: 14) {
            settingsTable(["启用", "图标", "尺寸", "显示名称（双击编辑 / 按住拖拽）"],
                          widths: [50, 48, 128, nil], selectAll: enabled) {
                ForEach(entries) { entry in
                    fileIconRow(entry)
                }
            }
            HStack(spacing: 6) {
                Button("＋") { model.importFileIcon() }.accessibilityLabel("添加自定义图标")
                Button("−") { model.removeSelectedFileIcon() }
                    .accessibilityLabel("删除所选自定义图标")
                    .disabled(!model.importedIcons.contains { $0.id == model.selectedFileIconID })
                Text("自定义图标尺寸建议小于 128 × 128（72 dpi）")
                    .font(.system(size: 11)).foregroundStyle(Color.settingsMuted)
                    .padding(.leading, 6)
                Spacer()
                Button("重置") { model.resetFileIconLibrary() }
            }
            HStack {
                Toggle("显示图标", isOn: Binding(get: { model.settings.showsFileIconPreviews },
                                              set: { value in model.setSystemPreference { $0.showsFileIcons = value } }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("应用所选图标…") { model.changeFileIcons(restore: false) }
                    .disabled(!entries.contains { entry in
                        entry.id == model.selectedFileIconID && model.settings.fileIconEnabled(entry.id) && FileIconLibrary.image(entry) != nil
                    })
                Button("恢复原图标…") { model.changeFileIcons(restore: true) }
                Link("更多图标素材 »", destination: URL(string: "https://aodo365.com/iricon.html")!)
            }.padding(.top, 8)
        }
        .disabled(!model.storageAvailable)
    }

    private func fileIconRow(_ entry: FileIconEntry) -> some View {
        let image = FileIconLibrary.image(entry)
        let size = image?.representations.first
        let title = model.settings.fileIconTitle(entry)
        return row {
            Toggle(title, isOn: Binding(get: { model.settings.fileIconEnabled(entry.id) },
                                       set: { model.setFileIconsEnabled([entry.id], enabled: $0) }))
                .labelsHidden().toggleStyle(.checkbox)
                .frame(width: 50, alignment: .leading)
            Group {
                if model.settings.showsFileIconPreviews, let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 30, height: 30)
                }
            }.frame(width: 48, alignment: .leading)
            Text(size.map { "\($0.pixelsWide) × \($0.pixelsHigh)" } ?? "—")
                .monospacedDigit().frame(width: 128, alignment: .leading)
            EditableMenuName(name: title) { model.renameFileIcon(entry.id, to: $0) }
        }
        .background(model.selectedFileIconID == entry.id ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedFileIconID = entry.id }
        .draggable(entry.id)
        .dropDestination(for: String.self) { items, _ in
            guard let source = items.first, items.count == 1 else { return false }
            return model.moveFileIcon(source, to: entry.id)
        }
    }

    private var namedCreationRow: some View {
        row {
            Toggle(model.settings.namedCreationTitle, isOn: Binding(get: { model.settings.showsNamedCreation ?? true },
                                                      set: { model.setNamedCreation($0) }))
                .labelsHidden().toggleStyle(.checkbox).frame(width: 46, alignment: .leading)
            Image(nsImage: MenuIcons.namedFile(size: 20))
                .resizable().frame(width: 20, height: 20)
                .frame(width: 40, alignment: .trailing).accessibilityHidden(true)
            EditableMenuName(name: model.settings.namedCreationTitle) { name in
                model.setSystemPreference { $0.namedCreationDisplayName = name }
            }
            Text("自定").foregroundStyle(Color.settingsMuted).frame(width: 50, alignment: .leading)
            Toggle("自定义创建新文件显示在主菜单", isOn: Binding(
                get: { model.settings.promotesNamedCreation == true },
                set: { value in model.setSystemPreference { $0.promotesNamedCreation = value } }
            )).labelsHidden().toggleStyle(.checkbox).frame(width: 52, alignment: .leading)
            Text("输入文件名").foregroundStyle(Color.settingsMuted).frame(width: 115, alignment: .leading)
        }
        .disabled(!model.storageAvailable)
    }

    private func templateRow(name: String, ext: String, drag: TemplateDrag, available: Bool = true,
                             enabled: Binding<Bool>, promoted: Binding<Bool>? = nil,
                             rename: @escaping (String) -> Void, moveUp: (() -> Void)?, moveDown: (() -> Void)?,
                             remove: (() -> Void)? = nil) -> some View {
        row {
            Toggle(name, isOn: enabled).labelsHidden().toggleStyle(.checkbox).frame(width: 46, alignment: .leading)
                .disabled(!available)
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10)).foregroundStyle(Color.settingsMuted)
                    .frame(width: 16, height: 24).contentShape(Rectangle())
                    .draggable(drag).help("拖动排序").accessibilityHidden(true)
                Image(nsImage: MenuIcons.document(extension: ext, size: 20))
                    .resizable().frame(width: 20, height: 20).accessibilityHidden(true)
            }
            .frame(width: 40, alignment: .leading)
            EditableMenuName(name: name, save: rename)
            Text(ext.isEmpty ? "—" : ext).lineLimit(1).frame(width: 50, alignment: .leading)
                .foregroundStyle(Color.settingsMuted)
            Group {
                if let promoted {
                    Toggle("\(name)显示在主菜单", isOn: promoted).labelsHidden().toggleStyle(.checkbox)
                        .disabled(!enabled.wrappedValue)
                }
            }
            .frame(width: 52, alignment: .leading)
            HStack(spacing: 6) {
                templateButton("上移", symbol: "chevron.up", action: moveUp)
                templateButton("下移", symbol: "chevron.down", action: moveDown)
                if let remove { Button("移除", action: remove) }
                else if !available { Text("缺少模板").foregroundStyle(Color.settingsMuted) }
            }
            .buttonStyle(.borderless).frame(width: 115, alignment: .leading)
        }
        .disabled(!model.storageAvailable)
    }

    private func templateButton(_ label: String, symbol: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: symbol).frame(width: 14)
        }
        .disabled(action == nil).help(LocalizedStringKey(label)).accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    private var favoritesPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            TransferDestinationsTable(model: model, isFavorites: true)
            HStack(spacing: 6) {
                Button("＋") { model.addFolder(asFavorite: true) }.accessibilityLabel("添加常用目录")
                Button("−") {
                    guard let folder = model.settings.favorites?.entries.first(where: { $0.id == model.selectedFavoriteID }) else { return }
                    model.removeFavorite(folder)
                    model.selectedFavoriteID = nil
                }
                .accessibilityLabel("删除所选常用目录")
                .disabled(model.selectedFavoriteID == nil)
                Spacer()
                Button("重置") { model.resetFavorites() }
            }
            HStack {
                Toggle("显示图标", isOn: Binding(get: { model.settings.showsFavoriteIcons ?? true },
                                              set: { value in model.setSystemPreference { $0.showsFavoriteIcons = value } }))
                Spacer()
                Toggle("启用常用目录", isOn: Binding(get: { model.settings.isEnabled(.openFavorite) },
                                                  set: { model.setEnabled(.openFavorite, $0) }))
                    .frame(width: 265, alignment: .leading)
            }.padding(.top, 8)
        }
        .toggleStyle(.checkbox)
        .disabled(!model.storageAvailable)
    }

    private var sendPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            TransferDestinationsTable(model: model)
            HStack(spacing: 6) {
                Button("＋") { model.addTransferDestination() }.accessibilityLabel("添加发送目标目录")
                Button("−") { model.removeTransferDestination() }
                    .accessibilityLabel("删除所选发送目标")
                    .disabled(model.selectedTransferID == nil)
                Spacer()
                Button("重置") { model.resetTransferDestinations() }
            }
            HStack(alignment: .top) {
                Toggle("显示图标", isOn: Binding(get: { model.settings.showsTransferIcons ?? true },
                                              set: { value in model.setSystemPreference { $0.showsTransferIcons = value } }))
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用移动文件到…", isOn: Binding(get: { model.settings.isEnabled(.moveToFolder) }, set: { model.setEnabled(.moveToFolder, $0) }))
                    Toggle("启用复制文件到…", isOn: Binding(get: { model.settings.isEnabled(.copyToFolder) }, set: { model.setEnabled(.copyToFolder, $0) }))
                }.frame(width: 265, alignment: .leading)
            }.padding(.top, 8)
        }
        .toggleStyle(.checkbox)
        .disabled(!model.storageAvailable)
    }

    private var toolboxPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsTable(["启用", "图标", "显示名称（双击编辑 / 按住拖拽）", "选项"], widths: [40, 34, nil, 190]) {
                ForEach(model.settings.toolboxItems) { item in
                    toolboxRow(item)
                        .background(model.selectedToolboxID == item.id ? Color.settingsFog : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedToolboxID = item.id }
                        .draggable(item.id)
                        .dropDestination(for: String.self, action: { values, _ in
                            return moveToolboxRows(values, to: item.id)
                        })
                }
            }
            HStack {
                Button("新建进入 App") { model.addApplication() }
                Button("删除") {
                    if let selectedToolboxID = model.selectedToolboxID,
                       let entry = (model.settings.applications ?? ApplicationCatalog.entries).first(where: { "application:" + $0.id == selectedToolboxID }) {
                        model.removeApplication(entry)
                        model.selectedToolboxID = nil
                    }
                }.disabled(!selectedCustomApplication)
                Spacer()
                Button("申请其他功能") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/1078302479/SuperMenu/issues/new")!)
                }
                Button("重置") { model.resetToolbox() }
            }
            Toggle("显示图标", isOn: Binding(get: { model.settings.showMenuIcons ?? true },
                                                 set: { value in model.setSystemPreference { $0.showMenuIcons = value } }))
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    mergeToggle(.files, title: "合并显示文件（夹）右键菜单")
                    mergeToggle(.applications, title: "合并显示进入 App 右键菜单")
                }
                mergeToggle(.images, title: "合并显示图片转换右键菜单")
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!model.storageAvailable)
    }

    private func moveToolboxRows(_ values: [String], to target: String) -> Bool {
        guard let source = values.first else { return false }
        let knownIDs = model.settings.toolboxItems.map(\.id)
        guard knownIDs.contains(source) else { return false }
        model.setSystemPreference { $0.moveToolboxItem(source, to: target) }
        return true
    }

    private var selectedCustomApplication: Bool {
        (model.settings.applications ?? ApplicationCatalog.entries).contains { "application:" + $0.id == model.selectedToolboxID && $0.isCustom }
    }

    private func mergeToggle(_ group: MenuGroup, title: String) -> some View {
        Toggle(LocalizedStringKey(title), isOn: Binding(get: { model.settings.mergedMenuGroups?.contains(group) ?? false }, set: { enabled in
            model.setSystemPreference {
                var groups = $0.mergedMenuGroups ?? []
                if enabled { groups.insert(group) } else { groups.remove(group) }
                $0.mergedMenuGroups = groups
            }
        })).font(.system(size: 12))
    }

    @ViewBuilder private func toolboxRow(_ item: ToolboxItem) -> some View {
        switch item {
        case .action(let action):
            row {
                Toggle(LocalizedStringKey(action.title), isOn: Binding(get: { model.settings.isEnabled(action) }, set: { model.setEnabled(action, $0) }))
                    .labelsHidden().frame(width: 40, alignment: .leading)
                toolboxIcon(MenuIcons.action(action, size: 20), fallback: action.symbol)
                EditableMenuName(name: model.settings.menuName(action)) { value in model.updateMenuRule(action) { $0.name = value } }
                Group {
                    if action == .cut {
                        Picker("剪切选项", selection: Binding(get: { model.settings.hidesCutItems ?? false }, set: { model.setHidesCutItems($0) })) {
                            Text("剪切时不隐藏选中的文件").tag(false)
                            Text("剪切时隐藏选中的文件").tag(true)
                        }.labelsHidden()
                    } else if action == .deletePermanently {
                        Picker("删除确认", selection: Binding(get: { model.settings.confirmsPermanentDelete != false }, set: { model.setDeleteConfirmation($0) })) {
                            Text("需要再次确认").tag(true)
                            Text("无需再次确认").tag(false)
                        }.labelsHidden()
                    } else { Color.clear.frame(height: 1) }
                }.frame(width: 190)
            }
        case .image(let format):
            row {
                Toggle(LocalizedStringKey(format.title), isOn: Binding(get: { model.settings.enabledImageFormats?.contains(format) ?? true }, set: { model.setImageFormat(format, enabled: $0) }))
                    .labelsHidden().frame(width: 40, alignment: .leading)
                toolboxIcon(MenuIcons.action(.convertImage, size: 20), fallback: "photo")
                EditableMenuName(name: model.settings.imageMenuName(format)) { value in
                    model.setSystemPreference {
                        var names = $0.toolboxDisplayNames ?? [:]
                        names[item.id] = value
                        $0.toolboxDisplayNames = names
                    }
                }
                Color.clear.frame(width: 190, height: 1)
            }
        case .application(let id):
            if let entry = (model.settings.applications ?? ApplicationCatalog.entries).first(where: { $0.id == id }) {
                row {
                    Toggle(entry.title, isOn: Binding(get: { entry.enabled }, set: { model.setApplication(entry, enabled: $0) }))
                        .labelsHidden().frame(width: 40, alignment: .leading)
                    toolboxIcon(MenuIcons.application(entry, size: 20), fallback: "app")
                    let title = entry.bundleID == "com.apple.Terminal" ? model.settings.menuName(.openTerminal) : entry.menuTitle
                    EditableMenuName(name: title) { model.renameApplication(entry, to: $0) }
                    Group {
                        if entry.isTerminal {
                            Picker("打开方式", selection: Binding(get: { model.settings.terminalModes?[entry.bundleID] ?? model.settings.terminalMode ?? .systemDefault }, set: { value in
                                model.setSystemPreference {
                                    var modes = $0.terminalModes ?? [:]
                                    modes[entry.bundleID] = value
                                    $0.terminalModes = modes
                                }
                            })) {
                                ForEach(TerminalOpenMode.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                            }.labelsHidden()
                        } else { Color.clear.frame(height: 1) }
                    }.frame(width: 190)
                }
            }
        case .text(let service):
            row {
                Toggle(LocalizedStringKey(service.title), isOn: Binding(get: { model.settings.textServiceEnabled(service) }, set: { enabled in
                    model.setSystemPreference {
                        var services = $0.enabledTextServices ?? Set(TextServiceKind.allCases.map(\.rawValue))
                        if enabled { services.insert(service.rawValue) } else { services.remove(service.rawValue) }
                        $0.enabledTextServices = services
                    }
                })).labelsHidden().frame(width: 40, alignment: .leading)
                toolboxIcon(MenuIcons.referenceImage(named: "text-" + service.rawValue, size: 20), fallback: service == .qrCode ? "qrcode" : "character.bubble")
            Text(LocalizedStringKey(service.title)).frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 190, height: 1)
            }
        }
    }

    private func toolboxIcon(_ image: NSImage?, fallback: String) -> some View {
        Group {
            if let image { Image(nsImage: image) }
            else { Image(systemName: fallback).foregroundStyle(Color.settingsAccent) }
        }.frame(width: 34, alignment: .leading)
    }

    private func settingsTable<Content: View>(_ columns: [String], widths: [CGFloat?] = [nil], selectAll: Binding<Bool>? = nil,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, title in
                    if index == 0, let selectAll {
                        Toggle(LocalizedStringKey(title), isOn: selectAll).toggleStyle(.checkbox)
                            .frame(width: widths[index], alignment: .leading)
                    } else if let width = widths[index] {
                        Text(LocalizedStringKey(title)).frame(width: width, alignment: .leading)
                    } else {
                        Text(LocalizedStringKey(title)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.settingsMuted)
            .padding(.horizontal, 12).frame(height: 34).background(Color.settingsFog)
            Rectangle().fill(Color.settingsLine).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.settingsLine).allowsHitTesting(false) }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10, content: content)
                .padding(.horizontal, 12).frame(minHeight: 38)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.settingsLine).frame(height: 1)
        }
    }

    private func footer<Controls: View>(_ text: String, @ViewBuilder controls: () -> Controls) -> some View {
        HStack(spacing: 9) {
            Text(LocalizedStringKey(text)).font(.system(size: 11)).foregroundStyle(Color.settingsMuted)
            Spacer(minLength: 8)
            controls()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct EditableMenuName: NSViewRepresentable {
    let name: String
    let save: (String) -> Void

    func makeNSView(context: Context) -> MenuNameField {
        MenuNameField()
    }

    func updateNSView(_ field: MenuNameField, context: Context) {
        if !field.editingName { field.stringValue = name }
        field.isEnabled = context.environment.isEnabled
        field.saveName = save
    }
}

final class MenuNameField: NSTextField, NSTextFieldDelegate {
    var saveName: ((String) -> Void)?
    private(set) var editingName = false
    private var original = ""

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        usesSingleLineMode = true
        font = .systemFont(ofSize: 13)
        lineBreakMode = .byTruncatingMiddle
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = "双击编辑，回车保存，Esc 取消"
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        if editingName { super.mouseDown(with: event) }
        else if isEnabled && event.clickCount == 2 { beginEditing() }
        else { nextResponder?.mouseDown(with: event) }
    }

    func beginEditing() {
        guard isEnabled, !editingName, window != nil else { return }
        original = stringValue
        editingName = true
        isSelectable = true
        isEditable = true
        selectText(nil)
        if let editor = currentEditor() {
            editor.isSelectable = true
            editor.isEditable = true
        } else {
            finishEditing()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard editingName else { return }
        let editor = notification.userInfo?["NSFieldEditor"] as? NSText
        saveEditedName(editor?.string ?? stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard editingName, !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let name = textView.string
            abortEditing()
            saveEditedName(name)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            abortEditing()
            finishEditing()
            stringValue = original
            return true
        default:
            return false
        }
    }

    private func saveEditedName(_ value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        finishEditing()
        stringValue = name
        if name != original { saveName?(name) }
    }

    private func finishEditing() {
        editingName = false
        isEditable = false
        isSelectable = false
    }
}
