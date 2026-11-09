# SuperMenu

macOS 访达右键工具。0.1.1 开发预览包含通用设置、新建文件模板、目录授权与右键动作开关。支持 TXT、Markdown、RTF、XML 四种内置模板。

## 本机体验

需要 macOS 和 Apple Command Line Tools。下列命令生成当前架构的本地测试包。

```sh
./scripts/build-local.sh
open .build/local/SuperMenu.app
```

1. 在 SuperMenu 的「通用设置」点击「管理 Finder 扩展」，启用 SuperMenu。
2. 在「目录授权」添加一个测试文件夹，然后在访达里打开它。添加或移除目录后，回到该目录再打开菜单。
3. 在空白处打开「新建文件」子菜单，选择 TXT、Markdown、RTF 或 XML。连续创建同一格式时会自动编号。可在应用的「新建文件」页面关闭不常用的格式。选中一个或多个文件可拷贝路径，选中单个文件时终端应打开其所在目录。
4. 在「右键菜单」关闭一个动作，再打开访达菜单确认该项已隐藏。退出并重开应用，检查目录和开关是否保留。

本地包采用临时签名，供本机验证。若「共享配置」显示不可访问，或系统未加载扩展，请记录显示状态和系统提示。本地构建将设置保存在 `.build/local/shared`，沙盒访问范围仅限该目录。正式签名版的 App Group 仍待验证。已在 Finder 中看到三个动作，更新后的新建文件子菜单与动作执行仍待复测。

## 进度与参考

- [开发计划](docs/开发计划.md)
- [功能调研与历史规划](docs/产品规划.md)
- [交互设计稿](design/index.html)
- [Apple Finder Sync 指南](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)

后台构建可用 `SUPERMENU_BUILD_DIR=.build/background ./scripts/build-local.sh`，生成独立测试包，适合在用户使用电脑时验证编译与签名。

运行 `./scripts/test-background.sh` 可验证模板格式、旧设置兼容、沙盒进程间的后台投递、过期与重复请求拦截，以及同名文件保护。脚本使用临时应用标识、URL 协议和测试目录，无需操作访达。

每轮验证通过后，运行 `./scripts/build-local.sh` 更新固定的本机体验包 `.build/local/SuperMenu.app`。构建目录下的 `shared` 配置与应用包分开保存，更新时会保留。应用运行期间如需切换到新版本，只需退出并重新打开 SuperMenu。
