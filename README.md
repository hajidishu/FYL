<div align="center">
  <img src="assets/brand/icon.png" alt="FYL 图标" width="96" height="96" />

  <h1>FYL</h1>

  <p>
    <img src="https://img.shields.io/badge/Flutter-3.41.6-02569B?style=flat-square&amp;logo=flutter&amp;logoColor=white" alt="Flutter 3.41.6" />
    <img src="https://img.shields.io/badge/Forui-0.21.3-18181B?style=flat-square" alt="Forui 0.21.3" />
    <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-4B5563?style=flat-square" alt="Windows、macOS 和 Linux" />
  </p>

  <p>
    <strong>简体中文</strong> ·
    <a href="README.zh-Hant.md">繁體中文</a> ·
    <a href="README.en.md">English</a> ·
    <a href="README.ru.md">Русский</a>
  </p>

  <p>
    <a href="#简介">简介</a> ·
    <a href="#编译与运行">编译与运行</a>
  </p>
</div>

---

## 简介

FYL（free_your_launcher）是一款基于Flutter + Forui开发的跨平台minecraft启动器，并支持modrinth和curseforge来源的mod与整合包安装，作为一个你能够完全掌握的minecraft启动器，FYL不包含任何的遥测和付费赞助功能且代码完全开源，当然如果你愿意支持我们的开发，也欢迎通过USDT（TRON或evm兼容链）为我们捐款

之所以要开发FYL是因为近期来自中国大陆的minecraft启动器普遍出现了[故意关闭中国大陆用户游戏下载功能](https://github.com/HMCL-dev/HMCL/commit/583e004d718102ae4489aa3f64bcde0c0161d000)，当然我知道这并非hmcl开发者所愿意的，我不会去强迫hmcl或者其他启动器的开发者恢复游戏下载功能，我选择开发FYL就是希望建立一个自由的启动器，至少不会连下载游戏的自由都被干涉

>FYL仍处于早期开发阶段，可能会出现大量bug，如果你遇到了问题请点击你屏幕上方的“issue”按钮

## 编译与运行

```sh
javac --release 8 -encoding UTF-8 -g:none -d assets/java tool/java/FylOptiFineBridge.java
flutter pub get
```

| 平台 | 开发运行 | Release 构建 |
| --- | --- | --- |
| Windows | `flutter run -d windows` | `flutter build windows --release` |
| macOS | `flutter run -d macos` | `flutter build macos --release` |
| Linux | `flutter run -d linux` | `flutter build linux --release` |

产物位置：

- Windows：`build/windows/x64/runner/Release/`
- macOS：`build/macos/Build/Products/Release/`
- Linux：`build/linux/x64/release/bundle/`

## 许可证与鸣谢

FYL的源代码采用 [GPL-3](http://www.gnu.org/licenses/gpl-3.0) 许可证发布

我本人也曾是[hmcl](https://github.com/HMCL-dev/HMCL/)和[pcl2](https://github.com/Meloong-Git/PCL/)的用户，FYL的诸多功能都参考了hmcl和pcl2的设计
