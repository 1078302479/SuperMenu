import SwiftUI
import AppKit
import ServiceManagement

struct SystemPreferencesView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                permissionStrip
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("选择你的触发方式").font(.system(size: 15, weight: .semibold))
                        Text("用于 iCloud、OneDrive 文件夹中的独立右键菜单。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if cloudEnabled { Text(LocalizedStringKey(cloudStatus)).font(.caption).foregroundStyle(model.cloudTriggerAvailable && model.finderAutomationEnabled ? .green : .orange) }
                }
                HStack(alignment: .top, spacing: 12) { triggerCards }
                HStack(alignment: .top, spacing: 24) {
                    basicPreferences.frame(minWidth: 220, maxWidth: .infinity)
                    Divider()
                    UpdatePreferencesView(model: model, checker: model.updates).frame(minWidth: 220, maxWidth: .infinity)
                }
                Divider()
                HStack {
                    Text("更改自动保存").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("权限设置教学") { model.showPermissionInstructions() }
                    Button("显示当前应用") { model.revealInstalledApplication() }
                }.buttonStyle(.plain).foregroundStyle(.blue).font(.caption)
            }.padding(.trailing, 10).padding(.bottom, 20)
        }
        .toggleStyle(.switch).controlSize(.small)
        .task { await model.refreshPermissions() }
    }

    private var permissionStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("权限与访问").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.checkingPermissions { ProgressView().controlSize(.small) }
                Button("立即检查") { Task { await model.refreshPermissions() } }.disabled(model.checkingPermissions)
            }
            HStack(spacing: 14) { permissionTiles }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("每 30 秒检查，返回应用时刷新")
                    if let checked = model.permissionsCheckedAt {
                        HStack(spacing: 4) {
                            Text("检查完成")
                            Text(checked, style: .time)
                        }
                    }
                }.font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("更新后菜单不出现？") { model.showsAuthorizationHelp.toggle() }
                    .font(.caption).foregroundStyle(cloudEnabled && !model.accessibilityEnabled ? .orange : .blue)
            }
            if cloudEnabled && !model.accessibilityEnabled {
                Label("请移除旧授权记录，重新添加当前应用。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.showsAuthorizationHelp {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 打开辅助功能设置，选中「增强右键」，点击减号移除旧记录。")
                    Text("2. 点击加号，重新添加「应用程序」中的「增强右键.app」，并开启开关。")
                    Text("3. 返回软件点击「立即检查」；仍未就绪时，退出并重新打开软件。")
                    HStack {
                        Button("打开辅助功能设置") { model.openAccessibilitySettings() }
                        Button("显示当前应用") { model.revealInstalledApplication() }
                        Button("权限设置引导") { model.showPermissionGuide() }
                    }
                    Text("目录访问检测不代表完全磁盘访问开关状态。").foregroundStyle(.secondary)
                }.font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.07)))
    }

    @ViewBuilder private var permissionTiles: some View {
        permissionTile("访达扩展", status: extensionStatus, color: extensionColor, action: model.openFinderExtensionSettings)
        permissionTile("辅助功能", status: !model.permissionProbeAvailable ? "无法确认" : model.accessibilityEnabled ? "已授权" : "需要授权", color: !model.permissionProbeAvailable ? .secondary : model.accessibilityEnabled ? .green : .orange, action: model.openAccessibilitySettings)
        permissionTile("访达访问", status: !model.permissionProbeAvailable ? "无法确认" : model.finderAutomationEnabled ? "已授权" : "需要授权", color: !model.permissionProbeAvailable ? .secondary : model.finderAutomationEnabled ? .green : .orange, action: model.finderAutomationEnabled ? model.openFinderAutomationSettings : model.requestFinderAutomation)
        permissionTile("受保护目录", status: protectedStatus, color: protectedColor, action: model.openFullDiskAccessSettings)
    }

    private func permissionTile(_ title: String, status: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey(title)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).foregroundStyle(.primary)
                    Text(LocalizedStringKey(status)).font(.caption).foregroundStyle(color)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }.frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(title)))
    }

    @ViewBuilder private var triggerCards: some View {
        triggerCard("修饰键 + 右键", detail: "按住修饰键时调出增强菜单。", symbol: "keyboard", enabled: model.settings.cloudMenu?.modifierRightClick ?? false) {
            Toggle("修饰键右键", isOn: Binding(get: { model.settings.cloudMenu?.modifierRightClick ?? false }, set: { value in model.setCloudMenu { $0.modifierRightClick = value } })).labelsHidden()
        } footer: {
            Picker("修饰键", selection: Binding(get: { model.settings.cloudMenu?.modifier ?? .shift }, set: { value in model.setCloudMenu { $0.modifier = value } })) {
                ForEach(CloudMenuModifier.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 110)
        }
        triggerCard("鼠标中键", detail: "按下鼠标滚轮，直接打开增强菜单。", symbol: "computermouse", enabled: model.settings.cloudMenu?.middleClick ?? false) {
            Toggle("鼠标中键点击", isOn: Binding(get: { model.settings.cloudMenu?.middleClick ?? false }, set: { value in model.setCloudMenu { $0.middleClick = value } })).labelsHidden()
        } footer: { Text("无需组合按键").font(.caption).foregroundStyle(.secondary) }
        triggerCard("三指轻点 / 点按", detail: "触控板手势入口暂不开放。", symbol: "hand.draw", enabled: false) {
            Text("暂不开放").font(.caption).foregroundStyle(.secondary)
        } footer: { EmptyView() }
    }

    private func triggerCard<T: View, F: View>(_ title: String, detail: String, symbol: String, enabled: Bool,
                                             @ViewBuilder control: () -> T, @ViewBuilder footer: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(enabled ? .blue : .secondary); Spacer(); control() }
            Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold))
            Text(LocalizedStringKey(detail)).fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary).frame(minHeight: 32, alignment: .topLeading)
            Spacer(minLength: 0)
            footer().frame(height: 24)
        }.padding(15).frame(minWidth: 172, maxWidth: .infinity, minHeight: 180, maxHeight: 180, alignment: .topLeading)
            .background(enabled ? Color.blue.opacity(0.025) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(enabled ? Color.blue.opacity(0.3) : Color.primary.opacity(0.08)))
    }

    private var basicPreferences: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("应用偏好").font(.system(size: 14, weight: .semibold)).padding(.bottom, 8)
            row("显示菜单栏图标") {
                Toggle("显示菜单栏图标", isOn: Binding(get: { model.settings.showsStatusItem ?? true }, set: { value in model.setSystemPreference { $0.showsStatusItem = value } })).labelsHidden()
            }
            Divider()
            row("语言") {
                Picker("语言", selection: Binding(get: { model.settings.interfaceLanguage ?? .system }, set: { value in model.setSystemPreference { $0.interfaceLanguage = value } })) {
                    ForEach(InterfaceLanguage.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }.labelsHidden().frame(width: 140)
            }
            Divider()
            row("使用范围") {
                Picker("使用范围", selection: Binding(get: { model.settings.usageScope ?? .systemDisk }, set: { value in model.setSystemPreference { $0.usageScope = value } })) {
                    ForEach(UsageScope.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }.labelsHidden().frame(width: 140)
            }
        }
    }

    private var cloudEnabled: Bool {
        model.settings.cloudMenu?.modifierRightClick == true || model.settings.cloudMenu?.middleClick == true
    }
    private var cloudStatus: String {
        if !model.permissionProbeAvailable { return "无法确认权限状态，请点击立即检查" }
        if !model.accessibilityEnabled { return "需要辅助功能授权，请在下方权限区设置" }
        if !model.finderAutomationEnabled { return "需要访达访问授权，请在下方权限区设置" }
        return model.cloudTriggerAvailable ? "云盘菜单已就绪" : "鼠标监听未启动，请重新打开应用"
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(LocalizedStringKey(title), systemImage: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        }
    }
    private func row<Content: View>(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .medium))
                if let detail { Text(LocalizedStringKey(detail)).fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            content()
        }.padding(.vertical, 12)
    }
    private var extensionStatus: String {
        guard let enabled = model.extensionPermission else {
            return model.permissionsCheckedAt == nil ? "等待检测" : "无法确认"
        }
        return enabled ? "已启用" : "未启用"
    }

    private var extensionColor: Color {
        model.extensionPermission == true ? .green : (model.extensionPermission == false ? .orange : .secondary)
    }

    private var protectedStatus: String {
        guard model.permissionsCheckedAt != nil else { return "等待检测" }
        switch model.protectedDirectoryPermission {
        case .accessible: return "可访问检测目录"
        case .denied: return "访问受限"
        case .unknown: return "无法确认"
        }
    }

    private var protectedColor: Color {
        switch model.protectedDirectoryPermission {
        case .accessible: return .green
        case .denied: return .orange
        case .unknown: return .secondary
        }
    }

    private func permissionRow(_ title: String, status: String, color: Color,
                               button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .medium))
            Spacer()
            Label(LocalizedStringKey(status), systemImage: color == .green ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.callout).foregroundStyle(color).frame(minWidth: 100, alignment: .leading)
            Button(LocalizedStringKey(button), action: action).frame(width: 82)
        }.padding(.vertical, 11)
    }
}
