<div align="center">
  <img src="assets/brand/icon.png" alt="FYL 圖示" width="96" height="96" />

  <h1>FYL</h1>

  <p>
    <img src="https://img.shields.io/badge/Flutter-3.41.6-02569B?style=flat-square&amp;logo=flutter&amp;logoColor=white" alt="Flutter 3.41.6" />
    <img src="https://img.shields.io/badge/Forui-0.21.3-18181B?style=flat-square" alt="Forui 0.21.3" />
    <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-4B5563?style=flat-square" alt="Windows、macOS 和 Linux" />
  </p>

  <p>
    <a href="README.md">简体中文</a> ·
    <strong>繁體中文</strong> ·
    <a href="README.en.md">English</a> ·
    <a href="README.ru.md">Русский</a>
  </p>

  <p>
    <a href="#簡介">簡介</a> ·
    <a href="#編譯與執行">編譯與執行</a>
  </p>
</div>

---

## 簡介

FYL（free_your_launcher）是一款以 Flutter + Forui 開發的跨平台 Minecraft 啟動器，支援安裝來自 Modrinth 和 CurseForge 的模組與整合包。

FYL 旨在成為一款讓你完全掌握的 Minecraft 啟動器。FYL 不包含任何遙測或付費贊助功能，原始碼完全開源，也不會有開發者[刻意封鎖特定地區使用者的遊戲下載功能](https://github.com/HMCL-dev/HMCL/commit/583e004d718102ae4489aa3f64bcde0c0161d000)的情況。

> FYL 仍處於早期開發階段，可能存在許多錯誤。如果你遇到問題，請點選儲存庫頁面上方的「Issues」分頁。

## 編譯與執行

```sh
javac --release 8 -encoding UTF-8 -g:none -d assets/java tool/java/FylOptiFineBridge.java
flutter pub get
```

| 平台 | 開發執行 | Release 建置 |
| --- | --- | --- |
| Windows | `flutter run -d windows` | `flutter build windows --release` |
| macOS | `flutter run -d macos` | `flutter build macos --release` |
| Linux | `flutter run -d linux` | `flutter build linux --release` |

產物位置：

- Windows：`build/windows/x64/runner/Release/`
- macOS：`build/macos/Build/Products/Release/`
- Linux：`build/linux/x64/release/bundle/`

## 授權條款

FYL 的原始碼採用 [GPL-3](http://www.gnu.org/licenses/gpl-3.0) 授權條款發布。
