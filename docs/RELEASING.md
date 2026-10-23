# 发布 FYL

日常开发使用 `main`。提交和 Pull Request 自动执行检查、测试、三平台构建与打包，产物保存在 Actions 中。普通提交和手动运行工作流不会创建 Release。

## 发布版本

修改 `pubspec.yaml` 的 `version`，提交后创建对应标签。标签必须与 `+` 前的版本完全一致；`+` 后为 1–65535 的原生构建号。例如 `0.1.0-beta.1+1` 对应 `v0.1.0-beta.1`。

```sh
git add pubspec.yaml
git commit -m "chore: prepare 0.1.0-beta.1"
git tag -a v0.1.0-beta.1 -m "FYL 0.1.0-beta.1"
git push origin main
git push origin v0.1.0-beta.1
```

带预发布后缀，或 `.github/release.json` 中 `prerelease` 为 `true` 的版本标记为 Pre-release。发布正式版时使用不带预发布后缀的版本号，并将该选项设为 `false`。正式版只在版本号高于当前 Latest 时更新 Latest。

## 自动化流程

1. 校验版本与标签，执行发布工具测试。
2. 三个平台分别执行格式检查、静态分析、Flutter 测试、编译和打包。
3. 根据实际程序架构命名压缩包：Windows ZIP、macOS ZIP、Linux TAR.GZ。macOS 若同时包含 x64 和 ARM64，标记为 `universal`。
4. 三个平台全部成功后，再次核对产物与 SHA-256。Release 仅上传三个平台的压缩包，不额外发布 `SHA256SUMS`；校验值使用 GitHub 下载页提供的 SHA-256。
5. 创建 Release 草稿、上传完整产物，再自动发布。

压缩包包含程序运行所需目录、许可证、资源来源说明和对应源码提交链接。Linux 压缩包保留执行权限；macOS 打包保留应用目录、符号链接和文件属性。

打包时排除程序旁的 `FYL-data`、`fyl-storage.json` 及其备份、迁移临时目录，以及目录配置指向的程序内自定义资料文件夹，避免把本机账号、设置和游戏存档带入安装包。

发布任务使用 GitHub 自动提供的 `GITHUB_TOKEN`，仅发布任务拥有 `contents: write` 权限，无需个人访问令牌。

构建或上传失败不会公开未完成的 Release。上传失败后可重新运行工作流以续传草稿；已发布的 Release 保持不变。修复已发布版本时创建新版本和标签。

目前发布的是便携包，未配置 Windows 发布者签名或 macOS Developer ID 签名、公证。
