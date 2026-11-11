import SwiftUI
import AppKit
import ServiceManagement

struct SystemPreferencesView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("启动与显示") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("显示菜单栏图标", isOn: Binding(get: { model.settings.showsStatusItem ?? true },
                                                                                set: { value in model.setSystemPreference { $0.showsStatusItem = value } }))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("语言", selection: Binding(get: { model.settings.interfaceLanguage ?? .system },
                                                                        set: { value in model.setSystemPreference { $0.interfaceLanguage = value } })) {
                                    ForEach(InterfaceLanguage.allCases) { Text($0.title).tag($0) }
                                }
                                Picker("使用范围", selection: Binding(get: { model.settings.usageScope ?? .systemDisk },
                                                                          set: { value in model.setSystemPreference { $0.usageScope = value } })) {
                                    ForEach(UsageScope.allCases) { Text($0.title).tag($0) }
                                }
                            }.frame(width: 220)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("在 iCloud、OneDrive 文件夹中显示菜单") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("1. 按住修饰键", isOn: .constant(false))
                            Picker("修饰键", selection: .constant("Shift")) { Text("Shift").tag("Shift") }.labelsHidden().frame(width: 110)
                            Text("鼠标右键点击")
                        }.disabled(true).help("尚未实现，不能使用此触发方式")
                        Toggle("2. 鼠标中键点击", isOn: .constant(false)).disabled(true)
                        Toggle("3. 触控板上三指轻点 / 三指点按", isOn: .constant(false)).disabled(true)
                        Text("这三项触发方式尚未实现。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                UpdatePreferencesView(model: model, checker: model.updates)
                GroupBox("权限") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("权限状态").font(.headline)
                            Spacer()
                            if model.checkingPermissions { ProgressView().controlSize(.small) }
                            Button("立即检查") { Task { await model.refreshPermissions() } }
                                .disabled(model.checkingPermissions)
                        }
                        permissionRow("访达扩展", status: extensionStatus, color: extensionColor,
                                      button: "打开访达扩展设置", action: model.openFinderExtensionSettings)
                        permissionRow("受保护目录访问", status: protectedStatus, color: protectedColor,
                                      button: "打开完全磁盘访问设置", action: model.openFullDiskAccessSettings)
                        HStack {
                            Text("每 30 秒自动检查，返回应用时立即刷新。")
                            Spacer()
                            if let checked = model.permissionsCheckedAt {
                                Text("上次检查：\(checked.formatted(date: .omitted, time: .standard))")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text("受保护目录采用只读访问检测，不代表完全磁盘访问开关的精确状态；未找到检测目录时显示无法确认。")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("部分功能无法使用时，您可以授予完全磁盘访问权限来解决。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("观看权限设置教学 ≫") { model.showPermissionInstructions() }
                            Spacer()
                            Button("权限设置引导 ≫") { model.showPermissionGuide() }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }

            }
        }
        .toggleStyle(.checkbox)
        .task { await model.refreshPermissions() }
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
        HStack {
            Text(title)
            Spacer()
            Label(status, systemImage: color == .green ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(color)
            Button(button, action: action)
        }
    }

}
