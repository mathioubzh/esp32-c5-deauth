# Application Windows 11

Le contrôleur Flutter prend en charge Windows 11 x64 et conserve toutes les
fonctions de la version d’origine : liste des réseaux, whitelist, blacklist,
nuke, console et serveur API local. La connexion à l’ESP32-C5 utilise le
Bluetooth Low Energy (Nordic UART Service).

> Utilisez les fonctions de désauthentification uniquement sur un réseau qui
> vous appartient ou pour lequel vous avez une autorisation écrite explicite.

## Prérequis

- Windows 11 x64 avec Bluetooth Low Energy 4.0 ou plus récent ;
- [Flutter stable pour Windows](https://docs.flutter.dev/get-started/install/windows/desktop) ;
- Visual Studio 2022 Community avec la charge de travail
  **Développement Desktop en C++** ;
- le SDK Windows 10 ou Windows 11 sélectionné dans l’installateur Visual Studio.

Vérifiez l’installation dans une nouvelle fenêtre **Invite de commandes** :

```bat
flutter doctor -v
```

La section `Windows toolchain` doit être validée.

## Compiler l’archive portable

Dans l’Invite de commandes, ouvrez le dossier `flutter`, puis lancez :

```bat
build_windows.bat
```

Le script télécharge les dépendances Flutter, compile en mode Release et crée
`deauther-windows-x64.zip` à la racine du projet.

Il est aussi possible de compiler manuellement :

```bat
flutter config --enable-windows-desktop
flutter pub get
flutter build windows --release
```

Le résultat non compressé se trouve dans
`flutter\build\windows\x64\runner\Release`.

## Utiliser l’application

1. Décompressez entièrement `deauther-windows-x64.zip` dans un nouveau dossier.
2. Allumez le Bluetooth de Windows et alimentez l’ESP32-C5.
3. Lancez `esp32_c5_controller.exe` sans déplacer le fichier hors de son
   dossier : les DLL et le dossier `data` sont nécessaires.
4. L’application détecte automatiquement le périphérique BLE du firmware.

Les réglages sont enregistrés dans
`%APPDATA%\ESP32-C5 Deauther\settings.json`.

L’exécutable n’est pas signé. Sur une compilation personnelle, Windows peut
afficher SmartScreen ; vérifiez la provenance des fichiers avant de choisir
**Informations complémentaires**, puis **Exécuter quand même**.

## Compilation dans GitHub Actions

Le workflow `.github/workflows/windows.yml` permet aussi de produire le ZIP
sur un runner Windows : ouvrez l’onglet **Actions**, choisissez
**Build Windows app**, lancez **Run workflow**, puis téléchargez l’artefact
`deauther-windows-x64` à la fin du job.

## Dépannage Bluetooth

- Vérifiez que l’adaptateur prend en charge BLE, pas seulement le Bluetooth
  audio classique.
- Fermez toute autre application déjà connectée à l’ESP32-C5.
- Éteignez/rallumez le Bluetooth et redémarrez l’ESP32-C5 si le périphérique
  n’apparaît plus après une déconnexion brutale.
- Ne créez pas d’appairage manuel dans les Paramètres Windows : le contrôleur
  se connecte directement au service BLE annoncé par le firmware.
