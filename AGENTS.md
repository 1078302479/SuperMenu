# SuperMenu 发布规则

任何代理或维护流程准备发布新版本、上传或替换 GitHub Release 附件前，必须运行：

```sh
python3 scripts/release-preflight.py --live
```

- 退出码为 0 且本次 report.json 状态为 passed 才能继续。失败必须修复并重新完整运行，禁止跳过阶段或复用旧报告。
- 只使用本次成功报告目录生成的 DMG、ZIP 和 SHA256SUMS.txt；源码或附件变化后必须重新检查。
- 自动通过不代替实机验收。报告中的人工项目必须提供结果，未验/跳过项必须在发布说明中明确披露。
- 发布统一使用 `python3 scripts/publish-release.py --notes-file <发布说明文件>`；禁止直接运行 gh release create/upload 绕过检查。仅做本地检查用 `--check-only`。
- 发布仍须用户明确授权。普通开发、测试及此规则本身不授权上传或发布。
