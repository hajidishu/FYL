<div align="center">
  <img src="assets/brand/icon.png" alt="Logo FYL" width="96" height="96" />

  <h1>FYL</h1>

  <p>
    <img src="https://img.shields.io/badge/Flutter-3.41.6-02569B?style=flat-square&amp;logo=flutter&amp;logoColor=white" alt="Flutter 3.41.6" />
    <img src="https://img.shields.io/badge/Forui-0.21.3-18181B?style=flat-square" alt="Forui 0.21.3" />
    <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-4B5563?style=flat-square" alt="Windows, macOS et Linux" />
  </p>

  <p>
    <a href="README.md">简体中文</a> ·
    <a href="README.zh-Hant.md">繁體中文</a> ·
    <a href="README.en.md">English</a> ·
    <a href="README.ru.md">Русский</a> ·
    <strong>Français</strong> ·
    <a href="README.de.md">Deutsch</a>
  </p>

  <p>
    <a href="#présentation">Présentation</a> ·
    <a href="#compilation-et-exécution">Compilation et exécution</a>
  </p>
</div>

---

## Présentation

FYL (free_your_launcher) est un lanceur Minecraft multiplateforme développé avec Flutter + Forui. Il permet d’installer des mods et modpacks depuis Modrinth et CurseForge. Conçu pour vous laisser le contrôle, FYL ne contient ni télémétrie ni fonctionnalités de parrainage payantes, et son code source est entièrement ouvert. Si vous souhaitez soutenir le développement, les dons en USDT sur TRON ou un réseau compatible EVM sont les bienvenus.

J’ai créé FYL parce que des lanceurs Minecraft de Chine continentale ont récemment commencé à [désactiver volontairement le téléchargement du jeu pour les utilisateurs de Chine continentale](https://github.com/HMCL-dev/HMCL/commit/583e004d718102ae4489aa3f64bcde0c0161d000). Je comprends que ce n’était pas le souhait des développeurs de HMCL. Je ne leur demanderai pas, ni aux auteurs d’autres lanceurs, de rétablir ces téléchargements. J’ai choisi de créer FYL pour préserver la liberté des utilisateurs, y compris celle de télécharger le jeu.

> FYL est encore à un stade précoce de développement et peut contenir de nombreux bugs. Si vous rencontrez un problème, ouvrez l’onglet Issues en haut de la page du dépôt.

Choisissez le chinois simplifié, le chinois traditionnel, l’anglais, le russe, le français ou l’allemand dans Paramètres → Général.

## Compilation et exécution

Python 3 est nécessaire ; les compilations normales excluent le mode multijoueur expérimental

```sh
javac --release 8 -encoding UTF-8 -g:none -d assets/java tool/java/FylOptiFineBridge.java
flutter pub get
```

| Plateforme | Exécution en développement | Compilation Release |
| --- | --- | --- |
| Windows | `flutter run -d windows` | `flutter build windows --release` |
| macOS | `flutter run -d macos` | `flutter build macos --release` |
| Linux | `flutter run -d linux` | `flutter build linux --release` |

Le mode multijoueur expérimental nécessite aussi Go 1.24+ et `--dart-define=FYL_ENABLE_MULTIPLAYER=true`, par exemple `flutter build windows --release --dart-define=FYL_ENABLE_MULTIPLAYER=true`. Voir les [notes de développement](docs/MULTIPLAYER.md)

Emplacement des fichiers compilés :

- Windows : `build/windows/x64/runner/Release/`
- macOS : `build/macos/Build/Products/Release/`
- Linux : `build/linux/x64/release/bundle/`

## Stockage des données

Après une mise à jour, FYL conserve le dossier de données existant, y compris l’ancien emplacement AppData, sans imposer de transfert. Une nouvelle installation utilise par défaut `FYL-data/`, à côté du lanceur. Le chemin peut être modifié dans Paramètres → Stockage des données, en choisissant explicitement de transférer ou non les données. Les dossiers de jeu externes restent en place.

Vous pouvez aussi utiliser l’argument `--data-dir "chemin"` ou la variable d’environnement `FYL_DATA_DIR`. Le fichier `fyl-storage.json`, à côté du lanceur, mémorise le dossier choisi ; les arguments et variables d’environnement ne nécessitent pas d’écrire ce fichier.

## Licence et remerciements

Le code source de FYL est distribué sous licence [GPL-3](http://www.gnu.org/licenses/gpl-3.0).

J’ai également utilisé [HMCL](https://github.com/HMCL-dev/HMCL/) et [PCL2](https://github.com/Meloong-Git/PCL/). De nombreuses fonctionnalités de FYL s’inspirent de leurs choix de conception.
