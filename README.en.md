<div align="center">
  <img src="assets/brand/icon.png" alt="FYL logo" width="96" height="96" />

  <h1>FYL</h1>

  <p>
    <img src="https://img.shields.io/badge/Flutter-3.41.6-02569B?style=flat-square&amp;logo=flutter&amp;logoColor=white" alt="Flutter 3.41.6" />
    <img src="https://img.shields.io/badge/Forui-0.21.3-18181B?style=flat-square" alt="Forui 0.21.3" />
    <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-4B5563?style=flat-square" alt="Windows, macOS and Linux" />
  </p>

  <p>
    <a href="README.md">简体中文</a> ·
    <a href="README.zh-Hant.md">繁體中文</a> ·
    <strong>English</strong> ·
    <a href="README.ru.md">Русский</a>
  </p>

  <p>
    <a href="#introduction">Introduction</a> ·
    <a href="#build-and-run">Build and run</a>
  </p>
</div>

---

## Introduction

FYL (free_your_launcher) is a cross-platform Minecraft launcher built with Flutter + Forui. It supports installing mods and modpacks from Modrinth and CurseForge.

FYL is designed to be a Minecraft launcher that you fully control. It contains no telemetry or paid sponsorship features, and its source code is fully open. FYL's developers will not [deliberately block game downloads for users in specific regions](https://github.com/HMCL-dev/HMCL/commit/583e004d718102ae4489aa3f64bcde0c0161d000).

> FYL is still in early development and may contain many bugs. If you encounter a problem, open the Issues tab at the top of the repository page.

## Build and run

```sh
javac --release 8 -encoding UTF-8 -g:none -d assets/java tool/java/FylOptiFineBridge.java
flutter pub get
```

| Platform | Development | Release build |
| --- | --- | --- |
| Windows | `flutter run -d windows` | `flutter build windows --release` |
| macOS | `flutter run -d macos` | `flutter build macos --release` |
| Linux | `flutter run -d linux` | `flutter build linux --release` |

Build output:

- Windows: `build/windows/x64/runner/Release/`
- macOS: `build/macos/Build/Products/Release/`
- Linux: `build/linux/x64/release/bundle/`

## License

FYL's source code is released under the [GPL-3](http://www.gnu.org/licenses/gpl-3.0) license.
