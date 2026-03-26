# Universal Rclone Mount Manager

A robust, enterprise-grade cloud storage mount manager leveraging `rclone`. It supports **Windows 11 (x86/ARM)**, **macOS (Intel/Apple Silicon)**, and **Linux (x86/ARM64)** natively.

This suite is designed for power users who require absolute stability, zero-I/O latency, large-file caching, auto-mounting at boot, and intelligent crash-recovery watchdogs.

---

## 🚀 Features

- **Cross-Platform**: Run the PowerShell/NSIS suite on Windows, or the unified Bash script on macOS/Linux. 100% feature parity.
- **Multi-Remote JSON Configuration**: Mount an arbitrary number of remotes (`gdrive`, `onedrive`, `s3`, etc.) using a single config file.
- **Auto-Start & OS-Native Crash Watchdog**: Automatically mount your drives at system boot/logon. On Linux and macOS, the daemon is fully delegated to the native OS kernel/init system (`systemd` with `Restart=always` / `launchd` with `KeepAlive=true`), guaranteeing 100% reliable auto-remounts if `rclone` ever crashes. Windows utilizes a reliable Task Scheduler periodic loop.
- **Status Dashboard**: A unified CLI command (`-Action Status`) provides a beautiful overview of all active mounts, PIDs, uptimes, RAM/disk cache usage, and recent log tailing.
- **Aggressive VFS Caching**: Zero-I/O latency. Uses `vfs-cache-mode full` for in-place editing, rapid seek, media playback buffering, and offline writes.
- **Anomaly Clearance & State Reset**: Automatically cleans up stale PID files, forcefully kills hanging `rclone` daemon threads, and clears old VFS cache chunks to prevent disk bloat.
- **Bandwidth Limits & Log Rotation**: Natively cap bandwidth and rotate log files automatically once they exceed 5MB.

### ⚡ Under the Hood: Performance Optimizations
These scripts configure `rclone` mounts with highly optimized flags designed for API-limit avoidance and streaming:
- **`--vfs-read-chunk-size 128M`** & **`--vfs-read-chunk-size-limit off`**: Significantly reduces API rate limits when streaming media by pulling massive chunks dynamically instead of tiny 16MB slivers.
- **`--vfs-read-ahead 128M`**: Buffers the next 128MB of the file proactively into RAM, eliminating stutter in high-bitrate playback.
- **`--tpslimit 10`** & **`--tpslimit-burst 20`**: Imposes a hard cap on API queries to prevent cloud providers (like Google Drive) from issuing 24-hour rate limit bans, while allowing small bursts for directory browsing.

---

## ✨ 1-Click Installation (Recommended)

Getting started is fully automated and flawless. Just run the installer designed for your OS. If you are missing any dependencies (e.g., `rclone`, `WinFsp`, `macFUSE`, `fuse3`, or `python3`), the installer will automatically download, install, and configure the latest versions directly from official sources in the background.

Once dependencies are installed, **an Interactive Setup Wizard will launch**, guiding you through:
1. Connecting to your preferred cloud provider (Google Drive, OneDrive, S3, Dropbox, etc.).
2. Selecting which remotes to mount, and where to mount them (e.g. `X:`, `/mnt/gdrive`). You can configure **multiple remotes** in a single session.
3. Tuning advanced performance settings (e.g., maximizing the Local Cache Size or setting Bandwidth Limits).

- **Windows**: Right-click `Install-Windows.bat` and select **Run as Administrator** (or double-click and approve the UAC prompt). It handles `winget` dependencies, launches the wizard, configures your Task Scheduler, and maps your drives immediately.
- **macOS**: Double-click `Install-macOS.command` inside Finder. It automatically installs Homebrew (if needed), `macFUSE`, and configures the `launchd` auto-start service.
- **Linux**: Run `./Install-Linux.sh` in your terminal. It leverages your native package manager (APT/DNF/Pacman) and configures your `systemd` user service.

*That's it. Your cloud storage is now natively mounted and will survive reboots.*

## Shellcheck and Testing
Both `Mount-GDrive.ps1` and `mount-gdrive.sh` are thoroughly linted with Shellcheck and PSScriptAnalyzer respectively to ensure maximum execution stability across OS variations.

---

## 📦 Zero-Touch Architecture (Auto-Install)

The suite is designed for a **100% zero-touch deployment**. If any underlying dependencies are missing, the scripts fetch them automatically during the "Install" action.

**Auto-Installation Mechanisms:**
- **Windows**: Automatically utilizes `winget` to pull `Rclone.Rclone` and `WinFsp.WinFsp`.
- **macOS**: Automatically installs Homebrew (if missing), then `brew install rclone macfuse python`. *(Note: `macFUSE` requires manual kernel extension approval in System Settings > Security).*
- **Linux**: Automatically utilizes `apt-get`, `dnf`, `pacman`, or the official `curl` bash scripts depending on your distribution.

*Just run the scripts; they handle the rest.*

---

## ⚙️ Compiling Assembly Launchers (Optional)

For absolute minimal footprint and speed, this project includes lightweight Assembly language wrappers for both Windows and Linux. These wrappers act as silent executors for the underlying scripts and compile to tiny binaries (~1-3KB).

You can compile them on any machine with `nasm` and `mingw-w64` installed:

```bash
make
```

- **Linux**: Produces `RcloneMount-Linux`. This is a lightweight x86_64 ELF binary that safely forwards CLI arguments directly to `mount-gdrive.sh` via the `execve` syscall.
- **Windows**: Produces `RcloneMount-Windows.exe`. This is a lightweight x86 PE32 binary that silently invokes `Mount-GDrive.ps1` in the background via the Windows API `WinExec`.

---

## 🖥️ Windows Usage

### Compiling the NSIS Installer `.exe` (Optional)

If you prefer deploying a single file, you can compile the `installer.nsi` script into a standalone executable (requires [NSIS](https://nsis.sourceforge.io/Download)).

Once compiled, simply distribute and double-click `Rclone-Optimized.exe`. It acts just like `Install-Windows.bat`, but silently installs the PowerShell scripts into `%LOCALAPPDATA%\RcloneMountManager`, places a `Run-Rclone.bat` shortcut on your Desktop, and mounts your `gdrive` immediately.

**Network Drive Discovery:** The rclone mount acts as a true Windows Network Location and will immediately appear under "This PC". You can also map it to any letter or browse to it via "Add Network Location" if desired.

### Advanced PowerShell Usage

Open an elevated PowerShell prompt to access advanced features directly:

```powershell
# Default mount of 'gdrive' on X:
.\Mount-GDrive.ps1

# Install an auto-start Task Scheduler entry + Crash Watchdog
.\Mount-GDrive.ps1 -Action Install -Watchdog

# Display the Status Dashboard
.\Mount-GDrive.ps1 -Action Status

# Unmount all active drives
.\Mount-GDrive.ps1 -Action Unmount
```

---

## 🍏🐧 macOS & Linux Usage

Ensure the script is executable before running:
```bash
chmod +x mount-gdrive.sh
```

### Advanced CLI Commands

```bash
# Force a manual mount in the current session
./mount-gdrive.sh -a mount

# Mount a specific remote with a bandwidth limit
./mount-gdrive.sh -r onedrive -m ~/onedrive --bw-limit 10M -a mount

# Show the interactive Status Dashboard
./mount-gdrive.sh -a status

# Unmount all active drives gracefully
./mount-gdrive.sh -a unmount
```

### Auto-Start Service & Watchdog Integration

You can register the script to run automatically in the background using native system services (`systemd` for Linux, `launchd` for macOS).

```bash
# Install the system service and enable the crash watchdog
./mount-gdrive.sh -a install --watchdog

# Uninstall the system services completely
./mount-gdrive.sh -a uninstall
```

---

## 🛠️ Troubleshooting

- **Error 0x8007045D (Windows I/O Device Error)**: This occurs when Windows Explorer treats a FUSE mount as a physical local disk and tries to probe file attributes it doesn't support while copying or creating folders. The scripts now natively enforce `--network-mode` to mount as a mapped network drive, which mitigates this bug. If you still encounter it, ensure your local VFS cache drive (e.g., `C:\`) is not genuinely failing or out of space.
- **macOS macFUSE Kext Errors**: Newer versions of macOS strongly restrict kernel extensions. If the script hangs or rclone fails to mount, go to `System Settings` > `Privacy & Security` > `Security` and click "Allow" for "macFUSE". You may need to reboot into Recovery Mode and lower the security policy to "Reduced Security" for kernel extensions to load.
- **Linux systemd user services**: The auto-start services on Linux run under `systemctl --user`. If your mounts don't start at boot until you log in, you must enable lingering for your user account: `sudo loginctl enable-linger $USER`.
- **Cache Drive Full**: The script enforces a strict 5GB minimum free space check to prevent `rclone` from writing a bad cache loop that soft-bricks your OS drive. You can increase or decrease this limit in the script directly (`assert_disk_space`).

---

## ⚙️ Multi-Remote JSON Configuration

For power users with multiple cloud drives, you can use a single `config.json` file to dictate all mounting behavior.

1. Generate a starter config by running:
   - Windows: `.\Mount-GDrive.ps1 -Action Install`
   - Mac/Linux: `./mount-gdrive.sh -a install`
2. Edit the generated `config.json` located in `~/.rcloneCache/config.json` (Mac/Linux) or `C:\RcloneCache\config.json` (Windows).

### Example `config.json`

```json
{
  "remotes": [
    {
      "name": "gdrive",
      "mountPoint": "/mnt/gdrive",
      "enabled": true
    },
    {
      "name": "dropbox",
      "mountPoint": "/mnt/dropbox",
      "enabled": true
    }
  ],
  "cachePath": "/home/user/.rcloneCache",
  "vfsCacheMode": "full",
  "cacheMaxSize": "50G",
  "bufferSize": "256M",
  "driveChunkSize": "128M",
  "bwLimit": "0",
  "watchdog": true,
  "watchdogIntervalMinutes": 2
}
```

Once edited, load it manually or install it into the service manager:
```bash
./mount-gdrive.sh --config-file ~/.rcloneCache/config.json -a mount
```
---

# Gestionnaire de Montage Universel Rclone

Un gestionnaire de montage de stockage cloud robuste et de niveau entreprise s'appuyant sur `rclone`. Il prend en charge **Windows 11 (x86/ARM)**, **macOS (Intel/Apple Silicon)** et **Linux (x86/ARM64)** de manière native.

Cette suite est conçue pour les utilisateurs avancés qui exigent une stabilité absolue, une latence d'E/S nulle, une mise en cache des gros fichiers, un montage automatique au démarrage et des veilleurs de récupération après plantage intelligents.

---

## 🚀 Fonctionnalités

- **Multiplateforme** : Exécutez la suite PowerShell/NSIS sur Windows, ou le script Bash unifié sur macOS/Linux. 100% de parité des fonctionnalités.
- **Configuration JSON Multi-Drives** : Montez un nombre arbitraire de stockages distants (`gdrive`, `onedrive`, `s3`, etc.) en utilisant un seul fichier de configuration.
- **Démarrage Automatique et Veilleur Natif à l'OS** : Montez automatiquement vos disques au démarrage/à l'ouverture de session du système. Sur Linux et macOS, le démon est entièrement délégué au noyau natif de l'OS/système d'initialisation (`systemd` avec `Restart=always` / `launchd` avec `KeepAlive=true`), garantissant des remontages automatiques 100% fiables si `rclone` venait à planter. Windows utilise une boucle périodique fiable du Planificateur de Tâches.
- **Tableau de Bord d'État** : Une commande CLI unifiée (`-Action Status`) fournit un aperçu détaillé de tous les montages actifs, PIDs, temps de disponibilité, utilisation du cache RAM/disque, et le suivi récent des journaux.
- **Mise en Cache VFS Agressive** : Latence d'E/S nulle. Utilise `vfs-cache-mode full` pour l'édition sur place, la recherche rapide, la mise en mémoire tampon de la lecture multimédia et les écritures hors ligne.
- **Dégagement d'Anomalies et Réinitialisation d'État** : Nettoie automatiquement les fichiers PID obsolètes, tue de force les threads de démon `rclone` suspendus, et efface les anciens morceaux de cache VFS pour empêcher le gonflement du disque.
- **Limites de Bande Passante et Rotation des Journaux** : Limite nativement la bande passante et fait pivoter les fichiers journaux automatiquement une fois qu'ils dépassent 5 Mo.

### ⚡ Sous le Capot : Optimisations de Performance
Ces scripts configurent les montages `rclone` avec des indicateurs hautement optimisés conçus pour éviter les limites de l'API et le streaming :
- **`--vfs-read-chunk-size 128M`** & **`--vfs-read-chunk-size-limit off`** : Réduit considérablement les limites de taux de l'API lors du streaming multimédia en tirant massivement et dynamiquement des morceaux au lieu de minuscules éclats de 16 Mo.
- **`--vfs-read-ahead 128M`** : Met en mémoire tampon les prochains 128 Mo du fichier de manière proactive dans la RAM, éliminant les saccades lors de la lecture à haut débit.
- **`--tpslimit 10`** & **`--tpslimit-burst 20`** : Impose un plafond strict aux requêtes API pour empêcher les fournisseurs de cloud (comme Google Drive) d'émettre des interdictions de limite de taux de 24 heures, tout en autorisant de petites rafales pour la navigation dans les répertoires.

---

## ✨ Installation en 1 Clic (Recommandé)

La mise en route est entièrement automatisée et sans faille. Il vous suffit d'exécuter le programme d'installation conçu pour votre OS. S'il vous manque des dépendances (par exemple, `rclone`, `WinFsp`, `macFUSE`, `fuse3` ou `python3`), le programme d'installation téléchargera, installera et configurera automatiquement les dernières versions directement à partir de sources officielles en arrière-plan.

Une fois les dépendances installées, **un Assistant de Configuration Interactif se lancera**, vous guidant pour :
1. Vous connecter à votre fournisseur de cloud préféré (Google Drive, OneDrive, S3, Dropbox, etc.).
2. Sélectionner les stockages à monter, et où les monter (par exemple `X:`, `/mnt/gdrive`). Vous pouvez configurer **plusieurs stockages** en une seule session.
3. Ajuster les paramètres de performance avancés (par exemple, maximiser la taille du cache local ou définir des limites de bande passante).

- **Windows** : Faites un clic droit sur `Install-Windows.bat` et sélectionnez **Exécuter en tant qu'administrateur** (ou double-cliquez et approuvez l'invite de l'UAC). Il gère les dépendances `winget`, lance l'assistant, configure votre Planificateur de Tâches et mappe vos disques immédiatement.
- **macOS** : Double-cliquez sur `Install-macOS.command` dans le Finder. Il installe automatiquement Homebrew (si nécessaire), `macFUSE`, et configure le service de démarrage automatique `launchd`.
- **Linux** : Exécutez `./Install-Linux.sh` dans votre terminal. Il exploite votre gestionnaire de paquets natif (APT/DNF/Pacman) et configure votre service utilisateur `systemd`.

*C'est tout. Votre stockage cloud est désormais monté nativement et survivra aux redémarrages.*

## Shellcheck et Tests
Aussi bien `Mount-GDrive.ps1` que `mount-gdrive.sh` sont soigneusement validés avec Shellcheck et PSScriptAnalyzer respectivement pour garantir une stabilité d'exécution maximale à travers les variations des OS.

---

## 📦 Architecture Zéro-Touche (Installation Automatique)

La suite est conçue pour un **déploiement 100% zéro-touche**. Si des dépendances sous-jacentes sont manquantes, les scripts les récupèrent automatiquement lors de l'action "Install".

**Mécanismes d'Installation Automatique :**
- **Windows** : Utilise automatiquement `winget` pour récupérer `Rclone.Rclone` et `WinFsp.WinFsp`.
- **macOS** : Installe automatiquement Homebrew (si manquant), puis `brew install rclone macfuse python`. *(Remarque : `macFUSE` nécessite l'approbation manuelle de l'extension du noyau dans Paramètres Système > Sécurité).*
- **Linux** : Utilise automatiquement `apt-get`, `dnf`, `pacman`, ou les scripts bash officiels `curl` selon votre distribution.

*Exécutez simplement les scripts ; ils gèrent le reste.*

---

## ⚙️ Compilation des Lanceurs Assembly (Optionnel)

Pour une empreinte et une vitesse minimales absolues, ce projet comprend des wrappers légers en langage Assembly pour Windows et Linux. Ces wrappers agissent comme des exécuteurs silencieux pour les scripts sous-jacents et se compilent en minuscules binaires (~1-3 Ko).

Vous pouvez les compiler sur n'importe quelle machine avec `nasm` et `mingw-w64` installés :

```bash
make
```

- **Linux** : Produit `RcloneMount-Linux`. Il s'agit d'un binaire ELF x86_64 léger qui transmet en toute sécurité les arguments CLI directement à `mount-gdrive.sh` via l'appel système `execve`.
- **Windows** : Produit `RcloneMount-Windows.exe`. Il s'agit d'un binaire PE32 x86 léger qui invoque silencieusement `Mount-GDrive.ps1` en arrière-plan via l'API Windows `WinExec`.

---

## 🖥️ Utilisation Windows

### Compilation de l'exécutable d'Installation NSIS `.exe` (Optionnel)

Si vous préférez déployer un seul fichier, vous pouvez compiler le script `installer.nsi` en un exécutable autonome (nécessite [NSIS](https://nsis.sourceforge.io/Download)).

Une fois compilé, distribuez-le simplement et double-cliquez sur `Rclone-Optimized.exe`. Il agit tout comme `Install-Windows.bat`, mais installe silencieusement les scripts PowerShell dans `%LOCALAPPDATA%\RcloneMountManager`, place un raccourci `Run-Rclone.bat` sur votre bureau, et monte immédiatement votre `gdrive`.

**Découverte de Lecteur Réseau :** Le montage rclone agit comme un véritable Emplacement Réseau Windows et apparaîtra immédiatement sous "Ce PC". Vous pouvez également le mapper à n'importe quelle lettre ou y accéder via "Ajouter un emplacement réseau" si vous le souhaitez.

### Utilisation Avancée PowerShell

Ouvrez une invite PowerShell avec des privilèges élevés pour accéder directement aux fonctionnalités avancées :

```powershell
# Montage par défaut de 'gdrive' sur X:
.\Mount-GDrive.ps1

# Installer une entrée de Planificateur de Tâches à démarrage automatique + Veilleur de Plantage
.\Mount-GDrive.ps1 -Action Install -Watchdog

# Afficher le Tableau de Bord d'État
.\Mount-GDrive.ps1 -Action Status

# Démonter tous les disques actifs
.\Mount-GDrive.ps1 -Action Unmount
```

---

## 🍏🐧 Utilisation macOS & Linux

Assurez-vous que le script est exécutable avant de l'exécuter :
```bash
chmod +x mount-gdrive.sh
```

### Commandes CLI Avancées

```bash
# Forcer un montage manuel dans la session en cours
./mount-gdrive.sh -a mount

# Monter un disque distant spécifique avec une limite de bande passante
./mount-gdrive.sh -r onedrive -m ~/onedrive --bw-limit 10M -a mount

# Afficher le Tableau de Bord d'État interactif
./mount-gdrive.sh -a status

# Démonter tous les disques actifs proprement
./mount-gdrive.sh -a unmount
```

### Intégration du Service de Démarrage Automatique et du Veilleur

Vous pouvez enregistrer le script pour qu'il s'exécute automatiquement en arrière-plan à l'aide de services système natifs (`systemd` pour Linux, `launchd` pour macOS).

```bash
# Installer le service système et activer le veilleur de plantage
./mount-gdrive.sh -a install --watchdog

# Désinstaller complètement les services système
./mount-gdrive.sh -a uninstall
```

---

## 🛠️ Dépannage

- **Erreur 0x8007045D (Erreur de périphérique d'E/S Windows)** : Cela se produit lorsque l'Explorateur Windows traite un montage FUSE comme un disque local physique et essaie de sonder des attributs de fichier qu'il ne prend pas en charge lors de la copie ou de la création de dossiers. Les scripts imposent désormais nativement `--network-mode` pour monter en tant que lecteur réseau mappé, ce qui atténue ce bogue. Si vous le rencontrez toujours, assurez-vous que votre lecteur de cache VFS local (par exemple, `C:\`) n'est pas véritablement défaillant ou à court d'espace.
- **Erreurs Kext macFUSE macOS** : Les versions plus récentes de macOS restreignent fortement les extensions du noyau. Si le script se bloque ou que rclone ne parvient pas à monter, allez dans `Paramètres Système` > `Confidentialité et Sécurité` > `Sécurité` et cliquez sur "Autoriser" pour "macFUSE". Vous devrez peut-être redémarrer en Mode de Récupération et abaisser la politique de sécurité à "Sécurité réduite" pour que les extensions du noyau se chargent.
- **Services utilisateur systemd Linux** : Les services de démarrage automatique sur Linux s'exécutent sous `systemctl --user`. Si vos montages ne démarrent pas au démarrage jusqu'à ce que vous vous connectiez, vous devez activer la persistance pour votre compte utilisateur : `sudo loginctl enable-linger $USER`.
- **Lecteur de Cache Plein** : Le script applique une vérification stricte de l'espace libre minimum de 5 Go pour empêcher `rclone` d'écrire une boucle de cache défectueuse qui bloque de manière logicielle votre lecteur OS. Vous pouvez augmenter ou diminuer cette limite directement dans le script (`assert_disk_space`).

---

## ⚙️ Configuration JSON Multi-Drives

Pour les utilisateurs avancés disposant de plusieurs disques cloud, vous pouvez utiliser un seul fichier `config.json` pour dicter tout le comportement de montage.

1. Générez une configuration de départ en exécutant :
   - Windows : `.\Mount-GDrive.ps1 -Action Install`
   - Mac/Linux : `./mount-gdrive.sh -a install`
2. Modifiez le fichier `config.json` généré situé dans `~/.rcloneCache/config.json` (Mac/Linux) ou `C:\RcloneCache\config.json` (Windows).

### Exemple `config.json`

```json
{
  "remotes": [
    {
      "name": "gdrive",
      "mountPoint": "/mnt/gdrive",
      "enabled": true
    },
    {
      "name": "dropbox",
      "mountPoint": "/mnt/dropbox",
      "enabled": true
    }
  ],
  "cachePath": "/home/user/.rcloneCache",
  "vfsCacheMode": "full",
  "cacheMaxSize": "50G",
  "bufferSize": "256M",
  "driveChunkSize": "128M",
  "bwLimit": "0",
  "watchdog": true,
  "watchdogIntervalMinutes": 2
}
```

Une fois modifié, chargez-le manuellement ou installez-le dans le gestionnaire de services :
```bash
./mount-gdrive.sh --config-file ~/.rcloneCache/config.json -a mount
```
