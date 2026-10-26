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
    <strong>Русский</strong> ·
    <a href="README.fr.md">Français</a> ·
    <a href="README.de.md">Deutsch</a>
  </p>

  <p>
    <a href="#о-проекте">О проекте</a> ·
    <a href="#сборка-и-запуск">Сборка и запуск</a>
  </p>
</div>

---

## О проекте

FYL (free_your_launcher) — кроссплатформенный лаунчер Minecraft, разработанный на Flutter + Forui. Он поддерживает установку модов и сборок из Modrinth и CurseForge. FYL создан для того, чтобы вы полностью контролировали свой лаунчер: в нём нет телеметрии и платных спонсорских функций, а исходный код полностью открыт. Если вы хотите поддержать разработку, мы также принимаем добровольные пожертвования в USDT в сети TRON или любой сети, совместимой с EVM.

Я начал разрабатывать FYL, потому что в последнее время среди лаунчеров Minecraft из материкового Китая стала распространяться практика [намеренного отключения загрузки игры для пользователей материкового Китая](https://github.com/HMCL-dev/HMCL/commit/583e004d718102ae4489aa3f64bcde0c0161d000). Я понимаю, что разработчики HMCL сами этого не хотели. Я не стану требовать от них или авторов других лаунчеров вернуть загрузку игры. Вместо этого я решил создать FYL — свободный лаунчер, который сохраняет за пользователями хотя бы свободу скачивать игру.

> FYL находится на ранней стадии разработки, поэтому в нём может быть много ошибок. Если вы столкнулись с проблемой, откройте вкладку Issues в верхней части страницы репозитория.

В разделе «Настройки → Общие» можно выбрать упрощённый или традиционный китайский, английский, русский, французский или немецкий язык.

## Сборка и запуск

Требуется Python 3; обычная сборка не включает экспериментальную совместную игру

```sh
javac --release 8 -encoding UTF-8 -g:none -d assets/java tool/java/FylOptiFineBridge.java
flutter pub get
```

| Платформа | Запуск для разработки | Сборка Release |
| --- | --- | --- |
| Windows | `flutter run -d windows` | `flutter build windows --release` |
| macOS | `flutter run -d macos` | `flutter build macos --release` |
| Linux | `flutter run -d linux` | `flutter build linux --release` |

Для экспериментальной совместной игры дополнительно нужны Go 1.24+ и параметр `--dart-define=FYL_ENABLE_MULTIPLAYER=true`, например `flutter build windows --release --dart-define=FYL_ENABLE_MULTIPLAYER=true`. Подробнее в [заметках по разработке](docs/MULTIPLAYER.md)

Расположение результатов сборки:

- Windows: `build/windows/x64/runner/Release/`
- macOS: `build/macos/Build/Products/Release/`
- Linux: `build/linux/x64/release/bundle/`

## Хранение данных

После обновления FYL продолжает использовать прежний каталог данных, включая AppData, без обязательного переноса. При новой установке по умолчанию используется папка `FYL-data/` рядом с лаунчером. Путь можно изменить в настройках хранения данных и самостоятельно выбрать, переносить ли данные. Внешние игровые каталоги остаются на месте.

Каталог также можно задать аргументом запуска `--data-dir "путь"` или переменной окружения `FYL_DATA_DIR`. Файл `fyl-storage.json` рядом с лаунчером хранит выбранный путь; при использовании аргумента или переменной окружения записывать этот файл не требуется.

## Лицензия и благодарности

Исходный код FYL распространяется под лицензией [GPL-3](http://www.gnu.org/licenses/gpl-3.0).

Я также пользовался [HMCL](https://github.com/HMCL-dev/HMCL/) и [PCL2](https://github.com/Meloong-Git/PCL/). Многие функции FYL созданы с учётом их решений.
