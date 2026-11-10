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
                GroupBox("权限") {
                    VStack(alignment: .leading, spacing: 10) {
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
        .disabled(!model.storageAvailable)
    }
}
