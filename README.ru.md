<div align="center">
  <img src="assets/brand/icon.png" alt="Логотип FYL" width="96" height="96" />

  <h1>FYL</h1>

  <p>
    <img src="https://img.shields.io/badge/Flutter-3.41.6-02569B?style=flat-square&amp;logo=flutter&amp;logoColor=white" alt="Flutter 3.41.6" />
    <img src="https://img.shields.io/badge/Forui-0.21.3-18181B?style=flat-square" alt="Forui 0.21.3" />
    <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-4B5563?style=flat-square" alt="Windows, macOS и Linux" />
  </p>

  <p>
    <a href="README.md">简体中文</a> ·
    <a href="README.zh-Hant.md">繁體中文</a> ·
    <a href="README.en.md">English</a> ·
    <strong>Русский</strong>
  </p>

  <p>
    <a href="#о-проекте">О проекте</a> ·
    <a href="#сборка-и-запуск">Сборка и запуск</a>
  </p>
</div>

---

## О проекте

FYL (free_your_launcher) — кроссплатформенный лаунчер Minecraft, разработанный на Flutter + Forui. Он поддерживает установку модов и сборок из Modrinth и CurseForge.

FYL задуман как лаунчер Minecraft, который полностью находится под вашим контролем. Он не содержит телеметрии и платных спонсорских функций; его исходный код полностью открыт. Разработчики FYL не будут [намеренно блокировать загрузку игры для пользователей отдельных регионов](https://github.com/HMCL-dev/HMCL/commit/583e004d718102ae4489aa3f64bcde0c0161d000).

> FYL находится на ранней стадии разработки, поэтому в нём может быть много ошибок. Если вы столкнулись с проблемой, откройте вкладку Issues в верхней части страницы репозитория.

## Сборка и запуск

```sh
javac --release 8 -encoding UTF-8 -g:none -d assets/java tool/java/FylOptiFineBridge.java
flutter pub get
```

| Платформа | Запуск для разработки | Сборка Release |
| --- | --- | --- |
| Windows | `flutter run -d windows` | `flutter build windows --release` |
| macOS | `flutter run -d macos` | `flutter build macos --release` |
| Linux | `flutter run -d linux` | `flutter build linux --release` |

Расположение результатов сборки:

- Windows: `build/windows/x64/runner/Release/`
- macOS: `build/macos/Build/Products/Release/`
- Linux: `build/linux/x64/release/bundle/`

## Лицензия

Исходный код FYL распространяется под лицензией [GPL-3](http://www.gnu.org/licenses/gpl-3.0).
