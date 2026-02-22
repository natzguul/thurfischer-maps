# Download Tool (Build From Scratch)

Dieses Tool erzeugt die Karten **komplett von Null**:
1. Rohdaten (.pbf) von Geofabrik
2. Tilemaker baut MBTiles
3. PMTiles-Konvertierung
4. `download_manifest.json` wird erzeugt

## Voraussetzungen (WSL empfohlen)

1. **WSL installieren** (z. B. Ubuntu)
2. **Tilemaker** in der WSL-Distribution installieren:

```bash
sudo apt update
sudo apt install tilemaker
```

## Start

```powershell
.\build_from_scratch.ps1 -UseWsl:$true -WslDistro "Ubuntu"
```

## Windows-Only (Fallback)

```powershell
.\build_from_scratch.ps1 -UseWsl:$false
```

> Hinweis: Windows-Tilemaker Builds können instabil sein.
