import SwiftUI
import AppKit

struct SystemPreferencesView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ViewThatFits(in: .vertical) {
                    expandedContent(height: geometry.size.height)
                    ScrollView { content }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer.padding(.top, 12)
        }.padding(.trailing, 4).padding(.bottom, 5)
        .toggleStyle(.switch).controlSize(.small)
        .task { await model.refreshPermissions() }
        .sheet(isPresented: $model.showsAuthorizationHelp) { authorizationHelp }
    }

    private func expandedContent(height: CGFloat) -> some View {
        let extra = max(0, height - 510)
        return VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                basicPreferences
                UpdatePreferencesView(model: model, checker: model.updates)
            }.frame(height: 194 + extra * 0.35)
            cloudPreferences.frame(height: 158 + extra * 0.30)
            permissions.frame(height: 130 + extra * 0.35)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                basicPreferences.frame(maxWidth: .infinity)
                UpdatePreferencesView(model: model, checker: model.updates).frame(maxWidth: .infinity)
            }
            cloudPreferences
            permissions
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
    private func heading(_ text: String, _ icon: String) -> some View {
        Label(LocalizedStringKey(text), systemImage: icon).font(.system(size: 13, weight: .semibold))
    }
    private var basicPreferences: some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                heading("基础偏好", "slider.horizontal.3").padding(.bottom, 8)
                preferenceRow("显示菜单栏图标") {
                    Toggle("显示菜单栏图标", isOn: Binding(get: { model.settings.showsStatusItem ?? true }, set: { value in model.setSystemPreference { $0.showsStatusItem = value } })).labelsHidden()
                }
                Divider()
                preferenceRow("语言") {
                    Picker("语言", selection: Binding(get: { model.settings.interfaceLanguage ?? .system }, set: { value in model.setSystemPreference { $0.interfaceLanguage = value } })) {
                        ForEach(InterfaceLanguage.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }.labelsHidden().frame(width: 125)
                }
                Divider()
                preferenceRow("使用范围") {
                    Picker("使用范围", selection: Binding(get: { model.settings.usageScope ?? .systemDisk }, set: { value in model.setSystemPreference { $0.usageScope = value } })) {
                        ForEach(UsageScope.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }.labelsHidden().frame(width: 125)
                }
            }
        }
    }
    private func preferenceRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.system(size: 12))
            Spacer(minLength: 6)
            control()
        }.padding(.vertical, 12).frame(maxHeight: .infinity)
    }
    private var cloudPreferences: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    heading("云盘右键菜单", "cloud")
                    Text("iCloud · OneDrive").font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle(isOn: Binding(get: { model.settings.cloudMenu?.modifierRightClick ?? false }, set: { value in model.setCloudMenu { $0.modifierRightClick = value } })) {
                            Label("修饰键 + 右键", systemImage: "keyboard").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("按住修饰键时调出增强菜单。").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary)
                        Picker("修饰键", selection: Binding(get: { model.settings.cloudMenu?.modifier ?? .shift }, set: { value in model.setCloudMenu { $0.modifier = value } })) {
                            ForEach(CloudMenuModifier.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 100)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle(isOn: Binding(get: { model.settings.cloudMenu?.middleClick ?? false }, set: { value in model.setCloudMenu { $0.middleClick = value } })) {
                            Label("鼠标中键", systemImage: "computermouse").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("按下鼠标滚轮，直接打开增强菜单。").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 12)).frame(maxHeight: .infinity, alignment: .center)
                Divider()
                HStack {
                    Label("三指触发暂不开放。", systemImage: "lock").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if cloudEnabled {
                        Text(LocalizedStringKey(cloudStatus)).font(.caption2)
                            .foregroundStyle(model.cloudTriggerAvailable ? Color.secondary : .orange)
                    }
                }
            }
        }
    }
    private var permissions: some View {
        card {
            VStack(alignment: .leading, spacing: 9) {
                heading("权限与访问", "checkmark.shield")
                HStack(spacing: 20) {
                    permission("访达扩展", detail: "提供访达右键菜单。", icon: "face.smiling", status: extensionStatus, color: extensionColor, action: model.openFinderExtensionSettings)
                    permission("辅助功能", detail: "用于云盘菜单的鼠标触发。", icon: "accessibility", status: !model.permissionProbeAvailable ? "无法确认" : model.accessibilityEnabled ? "已授权" : "需要授权", color: !model.permissionProbeAvailable ? .secondary : model.accessibilityEnabled ? .green : .orange, action: model.openAccessibilitySettings)
                }
                Divider()
                HStack(spacing: 20) {
                    permission("访达访问", detail: "读取当前目录与所选文件。", icon: "folder", status: !model.permissionProbeAvailable ? "无法确认" : model.finderAutomationEnabled ? "已授权" : "需要授权", color: !model.permissionProbeAvailable ? .secondary : model.finderAutomationEnabled ? .green : .orange, action: model.finderAutomationEnabled ? model.openFinderAutomationSettings : model.requestFinderAutomation)
                    permission("受保护目录", detail: "可选，部分文件操作需要。", icon: "lock", status: protectedStatus, color: model.permissionsCheckedAt == nil ? .secondary : protectedColor, action: model.openFullDiskAccessSettings)
                }
            }
        }
    }
    private func permission(_ title: String, detail: String, icon: String, status: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 17, weight: .light)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                    Text(LocalizedStringKey(detail)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 4, height: 4)
                    Text(LocalizedStringKey(status))
                    Image(systemName: "chevron.right").font(.system(size: 8))
                }.font(.system(size: 10)).foregroundStyle(color)
                    .padding(.horizontal, 7).padding(.vertical, 6)
                    .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(title)))
    }
    private var footer: some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 10) {
                Button { Task { await model.refreshPermissions() } } label: {
                    Label("重新检查", systemImage: "arrow.clockwise")
                }.disabled(model.checkingPermissions)
                if model.checkingPermissions { ProgressView().controlSize(.mini) }
                Divider().frame(height: 12)
                if let checked = model.permissionsCheckedAt {
                    HStack(spacing: 4) { Text("上次检查"); Text(checked, style: .time) }
                } else { Text("等待检测") }
                Spacer(minLength: 4)
                Button { model.showsAuthorizationHelp = true } label: {
                    HStack(spacing: 8) { Text("授权遇到问题？"); Image(systemName: "chevron.right") }
                }
            }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
    private var authorizationHelp: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("授权遇到问题？", "checkmark.shield")
            Text("1. 打开辅助功能设置，选中「增强右键」，点击减号移除旧记录。")
            Text("2. 点击加号，重新添加「应用程序」中的「增强右键.app」，并开启开关。")
            Text("3. 返回软件点击「立即检查」；仍未就绪时，退出并重新打开软件。")
            Text("目录访问检测不代表完全磁盘访问开关状态。").foregroundStyle(.secondary)
            HStack {
                Button("打开辅助功能设置") { model.openAccessibilitySettings() }
                Button("显示当前应用") { model.revealInstalledApplication() }
                Button("权限设置教学") { model.showPermissionInstructions() }
            }
            HStack { Spacer(); Button("完成") { model.showsAuthorizationHelp = false }.keyboardShortcut(.defaultAction) }
        }.font(.callout).padding(24).frame(width: 570)
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

}
