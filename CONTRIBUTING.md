# 维护与贡献 / Contributing

欢迎反馈问题、完善文档或提交代码。提交前请先查看现有 Issue，说明要解决的问题与预期行为。

## 本地开发 / Development

需要 macOS 13 或更高版本及 Apple Command Line Tools。

```sh
SUPERMENU_INCLUDE_REFERENCE_ASSETS=0 ./scripts/build-local.sh
open ".build/local/增强右键.app"
```

主程序位于 `Sources/App`，访达扩展位于 `Sources/FinderExtension`，共享模型与文件操作协议位于 `Sources/Shared`。请保持主程序和扩展的请求标识、设置兼容性与资源打包一致，不要随意修改 bundle ID。

The host app, Finder extension, and shared models live in separate source directories. Preserve request identifiers, settings compatibility, bundle identities, and resource consistency across both bundles.

## 检查范围 / Validation

```sh
SUPERMENU_INCLUDE_REFERENCE_ASSETS=0 SUPERMENU_TEST_HOME_STORAGE=1 ./scripts/test-background.sh
```

- 按修改范围验证文件操作、模板、设置迁移和请求交接；避免覆盖用户文件。
- 所有内置二进制模板必须同时打包至主程序和扩展；检查创建结果的格式和结构，不能只测试勾选框。
- 菜单和图标修改需要实机检查最终显示。首次右键问题必须在旧扩展进程退出、重新启用后只点击一次验证，不能用第二次点击或仅有回调日志代替通过。
- 真实界面测试须说明操作范围，避免打断使用者；测试完成后恢复窗口、设置与扩展启用状态。

A successful build or menu callback does not establish that Finder displayed the menu. Use real UI verification for visual changes and extension startup behavior, alongside focused background regression tests.

## 问题反馈 / Bug reports

请提供 macOS 版本、芯片类型、应用版本、复现步骤、实际结果与期望结果。菜单问题请注明文件类型、是否刚启用扩展、空白区域或选中文件，以及是否同时启用其他同类扩展。

Screenshots should use sample files and redact personal filenames, account information, and other private data. Do not attach credentials, private documents, or raw user settings containing sensitive paths.

## 资源与隐私 / Resources and privacy

请仅提交有权提供的代码和素材，记录第三方资源的来源、许可与归属，不要将第三方图标、商标或种子文档视为本项目原创。相关说明见 `Resources/ReferenceIcons/来源说明.md`、`Resources/Templates/来源说明.md` 和 `ThirdParty/README.md`。

Only submit code and assets you have the right to contribute. Preserve third-party licensing and attribution. Keep private files and local settings out of the repository.

## 发布 / Release

应用版本和构建号应同步递增，主程序与扩展必须一致。更新中英文 README 和 CHANGELOG；对实际安装包校验签名、版本、模板、图标和用户配置路径，并验证 GitHub 附件下载。只在维护者明确授权后发布，不将构建缓存或个人配置打入源码包。

Releases require maintainer approval. Verify the actual packaged app and extension, preserve production settings paths, and keep compiler caches out of source archives.

## 贡献许可 / Contribution license

本项目原创代码和资源采用 [Apache License 2.0](LICENSE)。除非明确另作声明，有意提交并纳入本项目的贡献按同一协议授权，遵循协议第 5 条。第三方资源继续遵循各自许可，不因提交到本仓库而改变授权。

Unless explicitly stated otherwise, contributions intentionally submitted for inclusion in this project are licensed under Apache License 2.0, as described in section 5. Ensure you have the right to submit your contribution and preserve all applicable third-party licenses and attribution.

### 发布后的最终验证

每次 GitHub Release 发布后，必须重新从远程下载正式附件，不能使用本地构建包代替：

1. 下载发布 ZIP 与 SHA256SUMS.txt，核对哈希、版本、签名、模板及图标完整性。
2. 保留可回退备份，用下载的应用完整覆盖本地应用，核对安装内容与远程包一致，并确认用户配置和模板未改变。
3. 对远程 ZIP 执行更新包验证和后台回归；具备桌面操作能力时补做启动、权限状态及实际右键菜单验证。
4. 记录验证结果；无法进行的实机项目须明确标为未验，不能以后台测试替代。
