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
    <a href="README.ru.md">Русский</a> ·
    <a href="README.fr.md">Français</a> ·
    <a href="README.de.md">Deutsch</a>
  </p>

  <p>
    <a href="#introduction">Introduction</a> ·
    <a href="#build-and-run">Build and run</a>
  </p>
</div>

---

## Introduction

FYL (free_your_launcher) is a cross-platform Minecraft launcher built with Flutter + Forui. It supports installing mods and modpacks from Modrinth and CurseForge. Designed to put you fully in control, FYL contains no telemetry or paid sponsorship features, and its source code is fully open. If you would like to support development, donations in USDT on TRON or an EVM-compatible chain are welcome.

I started FYL because Minecraft launchers from mainland China have recently been [deliberately disabling game downloads for users in mainland China](https://github.com/HMCL-dev/HMCL/commit/583e004d718102ae4489aa3f64bcde0c0161d000). I understand that this is not what the HMCL developers wanted. I will not demand that HMCL or other launcher developers restore game downloads. Instead, I chose to build FYL to preserve users' freedom, including the freedom to download the game.

> FYL is still in early development and may contain many bugs. If you encounter a problem, open the Issues tab at the top of the repository page.

Choose Simplified Chinese, Traditional Chinese, English, Russian, French or German under Settings → General.

## Build and run

Requires Go 1.24+ and Python 3; the Minecraft networking helper builds automatically with the launcher

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

## Data storage

Upgrades keep using your existing data directory, including the previous AppData location, without requiring migration. Fresh installations default to `FYL-data/` next to the launcher. Change the path under Settings → Data storage and explicitly choose whether to migrate data. External game directories stay in place.

You can also use the `--data-dir "path"` startup argument or the `FYL_DATA_DIR` environment variable. `fyl-storage.json` next to the launcher records the selected location; command-line and environment overrides do not require this file to be written.

## License and acknowledgements

FYL's source code is released under the [GPL-3](http://www.gnu.org/licenses/gpl-3.0) license.

I have also used [HMCL](https://github.com/HMCL-dev/HMCL/) and [PCL2](https://github.com/Meloong-Git/PCL/). Many FYL features take inspiration from their designs.
