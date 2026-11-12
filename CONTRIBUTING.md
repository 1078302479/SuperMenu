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

### 一键发布前检查

```sh
python3 scripts/release-preflight.py --live
```

需在 macOS 图形登录会话执行，允许创建/挂载测试磁盘及启动隔离测试应用。每次从当前源码生成独立发行候选，依次执行安装失败回退测试、发行构建、主程序/扩展及全部资源检查、DMG/ZIP 打包和校验、完整文件回归、临时 APFS 跨卷、主目录存储、真实候选 ZIP 更新预检和中英文离屏渲染。`--live` 增加 GitHub 版本检查；网络异常同样失败。不传该选项可执行离线检查，但不代表远程发布验证通过。

任一步失败返回非零退出码；超时会停止该步骤。并发执行会拒绝，运行中源码变更也使报告失败。报告、各阶段日志、截图和安装包位于 `.build/release-preflight/<本次运行>/`。只发布**本次成功报告目录中的包**，不得复用旧包。脚本不会覆盖 /Applications、修改真实用户配置、重启 Finder、登出或上传发布。

检查成功代表报告覆盖的自动检查通过，不能保证全部功能没有缺陷。实际 Finder 点击、权限重新授权、云盘/多窗口交互、重新登录及完整更新确认重启，仍须按报告的 manual_checks 完成实机验收；离屏截图也需要目视检查。尚未通过或明确跳过的范围应写入发布说明。

发布前检查是强制步骤，规则见 `AGENTS.md`。统一发布入口：

```sh
python3 scripts/publish-release.py --notes-file /绝对路径/发布说明.md
```

该入口每次强制重新执行 `release-preflight.py --live`；检查失败、源码或附件变化、版本标签不指向受测提交时拒绝上传。它只上传本轮生成的三个附件，没有跳过检查或传入旧报告的选项。执行前需提交受跟踪修改，并准备好指向该提交的远程版本标签。发布仍需维护者明确授权。

只验证、不上传：`python3 scripts/publish-release.py --check-only`。这是本地发布入口约束；GitHub 网页或持有仓库权限的外部工具仍可绕过本地脚本，仓库规则禁止这样操作。
