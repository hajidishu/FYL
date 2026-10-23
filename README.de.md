<div align="center">
  <img src="assets/brand/icon.png" alt="FYL-Logo" width="96" height="96" />

  <h1>FYL</h1>

  <p>
    <img src="https://img.shields.io/badge/Flutter-3.41.6-02569B?style=flat-square&amp;logo=flutter&amp;logoColor=white" alt="Flutter 3.41.6" />
    <img src="https://img.shields.io/badge/Forui-0.21.3-18181B?style=flat-square" alt="Forui 0.21.3" />
    <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-4B5563?style=flat-square" alt="Windows, macOS und Linux" />
  </p>

  <p>
    <a href="README.md">简体中文</a> ·
    <a href="README.zh-Hant.md">繁體中文</a> ·
    <a href="README.en.md">English</a> ·
    <a href="README.ru.md">Русский</a> ·
    <a href="README.fr.md">Français</a> ·
    <strong>Deutsch</strong>
  </p>

  <p>
    <a href="#über-fyl">Über FYL</a> ·
    <a href="#erstellen-und-ausführen">Erstellen und ausführen</a>
  </p>
</div>

---

## Über FYL

FYL (free_your_launcher) ist ein plattformübergreifender Minecraft-Launcher auf Basis von Flutter + Forui. Er unterstützt die Installation von Mods und Modpacks über Modrinth und CurseForge. FYL soll vollständig unter deiner Kontrolle stehen: ohne Telemetrie oder kostenpflichtige Sponsoring-Funktionen und mit vollständig offenem Quellcode. Wenn du die Entwicklung unterstützen möchtest, freuen wir uns über Spenden in USDT auf TRON oder einer EVM-kompatiblen Blockchain.

Ich habe FYL entwickelt, weil Minecraft-Launcher aus Festlandchina zuletzt begonnen haben, [Spieldownloads für Nutzer in Festlandchina absichtlich zu deaktivieren](https://github.com/HMCL-dev/HMCL/commit/583e004d718102ae4489aa3f64bcde0c0161d000). Mir ist bewusst, dass dies nicht dem Wunsch der HMCL-Entwickler entspricht. Ich werde weder sie noch andere Launcher-Entwickler auffordern, die Downloads wiederherzustellen. Stattdessen habe ich FYL begonnen, um die Freiheit der Nutzer zu bewahren, einschließlich der Freiheit, das Spiel herunterzuladen.

> FYL befindet sich noch in einer frühen Entwicklungsphase und kann viele Fehler enthalten. Probleme kannst du über den Reiter Issues oben auf der Repository-Seite melden.

Unter Einstellungen → Allgemein stehen vereinfachtes und traditionelles Chinesisch, Englisch, Russisch, Französisch und Deutsch zur Wahl.

## Erstellen und ausführen

```sh
javac --release 8 -encoding UTF-8 -g:none -d assets/java tool/java/FylOptiFineBridge.java
flutter pub get
```

| Plattform | Entwicklungsmodus | Release-Build |
| --- | --- | --- |
| Windows | `flutter run -d windows` | `flutter build windows --release` |
| macOS | `flutter run -d macos` | `flutter build macos --release` |
| Linux | `flutter run -d linux` | `flutter build linux --release` |

Ausgabeverzeichnisse:

- Windows: `build/windows/x64/runner/Release/`
- macOS: `build/macos/Build/Products/Release/`
- Linux: `build/linux/x64/release/bundle/`

## Datenspeicherung

Daten werden standardmäßig im Ordner `FYL-data/` neben dem Launcher gespeichert. Unter Einstellungen → Datenspeicherung kannst du das Verzeichnis ändern und wählen, ob bestehende Daten übertragen werden sollen. FYL bietet die Übertragung erkannter Daten älterer Versionen aus AppData an. Extern konfigurierte Spielverzeichnisse bleiben unverändert.

Alternativ kannst du das Startargument `--data-dir "Pfad"` oder die Umgebungsvariable `FYL_DATA_DIR` verwenden. `fyl-storage.json` neben dem Launcher speichert das gewählte Verzeichnis; bei Startargumenten oder Umgebungsvariablen muss diese Datei nicht geschrieben werden.

## Lizenz und Danksagungen

Der Quellcode von FYL wird unter der [GPL-3](http://www.gnu.org/licenses/gpl-3.0) veröffentlicht.

Ich habe auch [HMCL](https://github.com/HMCL-dev/HMCL/) und [PCL2](https://github.com/Meloong-Git/PCL/) verwendet. Viele Funktionen von FYL orientieren sich an ihren Entwürfen.
