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

FYL（free_your_launcher）是一款以 Flutter + Forui 開發的跨平台 Minecraft 啟動器，支援安裝來自 Modrinth 和 CurseForge 的模組與整合包。作為一款讓你完全掌握的 Minecraft 啟動器，FYL 不包含任何遙測或付費贊助功能，原始碼完全開源。如果你願意支持我們的開發，也歡迎透過 USDT（TRON 或 EVM 相容鏈）捐款。

之所以開發 FYL，是因為近期中國大陸的 Minecraft 啟動器普遍出現了[刻意關閉中國大陸使用者遊戲下載功能](https://github.com/HMCL-dev/HMCL/commit/583e004d718102ae4489aa3f64bcde0c0161d000)的情況。當然，我知道這並非 HMCL 開發者所願意的。我不會要求 HMCL 或其他啟動器的開發者恢復遊戲下載功能，而是選擇開發 FYL，希望建立一款自由的啟動器，至少不讓下載遊戲的自由受到干涉。

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

## 授權條款與致謝

FYL 的原始碼採用 [GPL-3](http://www.gnu.org/licenses/gpl-3.0) 授權條款發布。

我也曾是 [HMCL](https://github.com/HMCL-dev/HMCL/) 和 [PCL2](https://github.com/Meloong-Git/PCL/) 的使用者，FYL 的許多功能都參考了它們的設計。
