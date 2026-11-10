# 增强右键

增强右键是一款免费、开源的 macOS 访达右键工具，无需订阅。项目以覆盖[超级右键 PRO](https://aodo365.com/irightmousepro.html)的全部功能为目标，是独立开源项目。

> **首个公开预览版 v0.3.2。** 功能对标仍在进行，当前版本的可用功能和已知差异见下文。

## 下载安装

前往 [GitHub Releases](https://github.com/1078302479/SuperMenu/releases/latest) 下载 `SuperMenu-v0.3.2-arm64.dmg`。首版支持 Apple 芯片的 Mac，要求 macOS 13 或更高版本。

打开 DMG，把「增强右键」拖到「应用程序」，再按下方步骤启用访达扩展。预览包使用临时签名，尚未经过 Apple 公证。macOS 可能会拦截首次打开，具体取决于设备的安全设置。[Apple 关于打开应用的说明](https://support.apple.com/zh-cn/102445)

## 当前功能

| 分类 | 功能 |
| --- | --- |
| 新建文件 | TXT、RTF、XML、Markdown、Word、Excel、PPT、自定义命名和导入模板。支持逐项启用、双击改名、拖动排序、在主菜单直接显示，以及创建后自动打开和提示音。 |
| 文件流转 | 剪切、粘贴、取消剪切，复制或移动到预设目录、最近目标或自定义路径，同名冲突处理和跨卷复制校验。 |
| 常用目录 | 从访达添加或打开收藏，支持改名、拖动排序和重新定位。 |
| 文件（夹）图标 | 在应用设置页导入、应用及恢复图标，支持改名和拖动排序。 |
| 文件工具 | 拷贝路径和名称、用文件名创建文件夹、校验和、隐藏或显示文件、切换扩展名、桌面替身、隔空投送、解散文件夹、彻底删除、ZIP／7z 压缩与解压。 |
| 图片与应用 | PNG、JPG、WebP、HEIC、ICNS 转换和 macOS、iPhone、iPad、Apple Watch 图标导出，设置墙纸，在 Terminal、iTerm2 或自定义应用打开。 |
| 系统服务 | 百度翻译、谷歌翻译、二维码自动复制，以及通过文件服务处理已下载的云盘文件。 |

源码版附带项目生成的 Office 模板。WPS、iWork、AI 和 PSD 格式可以通过导入相应的空白文件使用。应用提供系统图标和自定义图标入口。

云目录的修饰键、中键和三指触发仍待实现。iShot、FastZip 和 DiskMap 当前提供打开入口，任务联动仍待实现。密码归档和部分特殊归档条目也尚未支持。Finder、登录项、系统服务和第三方应用仍有待完成的实机兼容性验证。

## 从源码运行

需要 macOS 13 或更高版本及 Apple Command Line Tools。构建生成适合当前 Mac 架构的应用。

```sh
SUPERMENU_INCLUDE_REFERENCE_ASSETS=0 ./scripts/build-local.sh
open ".build/local/增强右键.app"
```

1. 打开「通用设置 → 权限设置引导 → Finder 扩展」，启用增强右键。
2. 在「使用范围」选择「系统磁盘」或「全部磁盘」。访问受 macOS 保护的文件夹时，可通过权限设置引导检查完全磁盘访问权限。
3. 在访达目录的空白处右键可新建文件，选中文件后可使用文件操作。要把新建文件按钮加入工具栏，可在访达的「显示 → 自定工具栏…」中拖入增强右键。

源码体验构建使用临时签名，并把配置保存在构建目录内的 `shared` 文件夹。下载的安装版将配置保存在当前用户的 `Library/Application Support/io.github.1078302479.SuperMenu`。在线检查更新将在后续版本提供。

## 开发与许可

```sh
SUPERMENU_INCLUDE_REFERENCE_ASSETS=0 ./scripts/test-background.sh
```

后台测试覆盖文件操作、同名冲突保护、模板和设置兼容性，以及 Finder 请求交接。它使用独立的临时应用标识和测试目录。

项目原创代码和资源采用 [MIT 许可证](LICENSE)。[libwebp](ThirdParty/README.md) 使用其自身的许可证。本机开发可读取已安装参考应用的部分图标和模板，这些素材仅用于本机调试，源码预览版使用上方命令构建。

- [开发计划](docs/开发计划.md)
- [功能调研与历史规划](docs/产品规划.md)
- [交互设计稿](design/index.html)
