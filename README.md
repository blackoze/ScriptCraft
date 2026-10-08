# ScriptCraft

> PowerShell automation for Minecraft — Fabric, mods, shaders, and resource packs.

ScriptCraft is a lightweight single-file PowerShell tool that keeps your Minecraft setup up-to-date automatically.

## Features

- **Fabric Loader** — installs and updates the correct version for your Minecraft
- **Mods** — syncs mods from Modrinth and updates them
- **Shaders** — keeps your shader packs current
- **Resource Packs** — syncs resource packs automatically
- **Options Guard** — repairs corrupted options.txt
- **Auto-manage** — moves incompatible mods aside and returns them when compatible
- **Fabric Cleanup** — removes old loader versions

## Requirements

- Windows 10 or 11
- PowerShell 5.1 or newer (pre-installed)
- Java (installed by Minecraft Launcher)
- Internet connection

## Installation

1. Download this repository.
2. Copy the ScriptCraft folder to Documents.
3. Rename config.example.json to config.json.
4. Double-click ScriptCraft shortcut on Desktop (or run ScriptCraft.ps1).

## Configuration

Edit config.json to change behavior:

| Setting | Default | Description |
|---------|---------|-------------|
| Loader | fabric | Mod loader |
| Backup | true | Backup files before replacing |
| KeepBackups | 5 | Number of backup folders to keep |
| Launch | false | Open Minecraft Launcher after sync |
| PreferredMcVersion | "" | Lock to a specific MC version |
| HashCache | true | Cache SHA1 hashes for faster runs |
| AutoDisableIncompatible | true | Move incompatible mods aside |
| OptionsGuard | true | Repair corrupted options.txt |
| FabricCleanup | true | Remove old Fabric versions |
| FabricCleanupMode | global | global or perMC |
| FabricCleanupDelete | false | Permanently delete (vs archive) |

## Safety

ScriptCraft is non-destructive:

- All replaced files are backed up first
- Incompatible mods are moved aside, never deleted
- Old Fabric versions are archived, not removed
- Your worlds and Minecraft installation are never touched

## License

MIT License — see LICENSE file.

## Author

BLACKOZE
