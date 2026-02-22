param(
    [int]$MinZoom = 1,
    [int]$MaxZoom = 17,
    [string]$OutputDir = (Join-Path $PSScriptRoot "maps"),
    [int]$DownloadRetries = 3,
    [int]$MinFreeGB = 50,
    [bool]$VerifyChecksums = $true,
    [bool]$DownloadLandcover = $true,
    [bool]$DownloadCoastline = $true,
    [bool]$UseWsl = $true,
    [string]$WslDistro = "Ubuntu",
    [switch]$DeleteMbtiles,
    [string]$ManifestBaseUrl = "",
    [switch]$UseWslExampleFiles,
    [bool]$VerboseProgress = $true
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$progressPreference = "Continue"

<#
USAGE (Windows + WSL recommended)
1) Install WSL and tilemaker in your distro (e.g., Ubuntu):
   sudo apt update
   sudo apt install tilemaker

2) Run this script from PowerShell:
   .\build_from_scratch.ps1 -UseWsl:$true -WslDistro "Ubuntu"

Windows-only fallback:
   .\build_from_scratch.ps1 -UseWsl:$false
Note: Windows tilemaker builds have been unreliable on some machines.
#>

function Log([string]$Message) {
    $ts = (Get-Date -Format "HH:mm:ss")
    Write-Host "[$ts] $Message"
}

function Update-Progress([string]$Activity, [string]$Status, [int]$Percent) {
    if (-not $VerboseProgress) { return }
    $pct = [Math]::Max(0, [Math]::Min(100, $Percent))
    Write-Progress -Activity $Activity -Status $Status -PercentComplete $pct
}

function Convert-ToWslPath([string]$WindowsPath) {
    $full = $WindowsPath
    try {
        $full = (Resolve-Path $WindowsPath).Path
    } catch {
        $full = [System.IO.Path]::GetFullPath($WindowsPath)
    }
    if ($full -match "^[A-Za-z]:") {
        $drive = $full.Substring(0,1).ToLowerInvariant()
        $rest = $full.Substring(2).Replace("\", "/")
        if (-not $rest.StartsWith("/")) { $rest = "/" + $rest }
        return "/mnt/$drive$rest"
    }
    throw "Cannot convert to WSL path: $WindowsPath"
}

function Run-TilemakerWsl([string]$WorkDirWin, [string]$InputWin, [string]$OutputWin, [string]$ConfigWin, [string]$ProcessWin, [string]$StoreWin) {
    $work = Convert-ToWslPath $WorkDirWin
    $input = Convert-ToWslPath $InputWin
    $output = Convert-ToWslPath $OutputWin
    $store = Convert-ToWslPath $StoreWin
    $config = "./$(Split-Path -Leaf $ConfigWin)"
    $process = "./$(Split-Path -Leaf $ProcessWin)"

    Log "tilemaker (WSL) start (distro=$WslDistro)"
    & wsl.exe -d $WslDistro --cd $work -- tilemaker `
        --input $input `
        --output $output `
        --config $config `
        --process $process `
        --store $store `
        --threads 0
}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Download-File([string]$Url, [string]$OutFile, [int]$Retries) {
    Ensure-Dir (Split-Path $OutFile -Parent)
    if (Test-Path $OutFile) {
        Log "Skip download (exists): $OutFile"
        return
    }
    $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Log "Downloading (attempt $i/$Retries): $Url"
            Update-Progress "Download" "Attempt $i/$Retries" ([int](($i - 1) / [Math]::Max(1, $Retries) * 100))
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -MaximumRedirection 10
            Update-Progress "Download" "Completed" 100
            return
        } catch {
            if ($i -eq $Retries -and $bits) {
                try {
                    Log "Invoke-WebRequest failed, trying BITS once: $Url"
                    Start-BitsTransfer -Source $Url -Destination $OutFile
                    Update-Progress "Download" "Completed (BITS)" 100
                    return
                } catch {
                    throw
                }
            }
            Start-Sleep -Seconds (2 * $i)
        }
    }
}

function Verify-Md5([string]$FilePath, [string]$Md5Path) {
    if (-not (Test-Path $FilePath)) { return $false }
    if (-not (Test-Path $Md5Path)) { return $false }
    $md5Line = (Get-Content -TotalCount 1 $Md5Path).Trim()
    if (-not $md5Line) { return $false }
    $expected = $md5Line.Split(" ")[0].Trim().ToLowerInvariant()
    if (-not $expected) { return $false }
    $actual = (Get-FileHash -Algorithm MD5 -Path $FilePath).Hash.ToLowerInvariant()
    return $expected -eq $actual
}

function Update-ConfigZoom([string]$ConfigIn, [string]$ConfigOut, [int]$MinZoom, [int]$MaxZoom) {
    $json = Get-Content -Raw $ConfigIn | ConvertFrom-Json
    if ($json.layers) {
        foreach ($layer in $json.layers) {
            if ($layer.PSObject.Properties.Name -contains "minzoom") {
                if ($layer.minzoom -lt $MinZoom) { $layer.minzoom = $MinZoom }
            }
            if ($layer.PSObject.Properties.Name -contains "maxzoom") {
                if ($layer.maxzoom -gt $MaxZoom) { $layer.maxzoom = $MaxZoom }
            }
        }
    }
    $jsonString = $json | ConvertTo-Json -Depth 50
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ConfigOut, $jsonString, $utf8NoBom)
}

function Ensure-Coastline([string]$DataDir, [int]$Retries) {
    $coastDir = Join-Path $DataDir "coastline"
    $targetShp = Join-Path $coastDir "water_polygons.shp"
    if (Test-Path $targetShp) {
        Log "Coastline data present: $targetShp"
        return
    }
    if (-not $DownloadCoastline) {
        throw "Missing coastline data: $targetShp"
    }
    Ensure-Dir $coastDir
    $zipUrl = "https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip"
    $zipPath = Join-Path $coastDir "water-polygons-split-4326.zip"
    Download-File $zipUrl $zipPath $Retries
    $extractDir = Join-Path $coastDir "water-polygons-split-4326"
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $found = Get-ChildItem -Path $extractDir -Recurse -Filter "water_polygons.shp" | Select-Object -First 1
    if (-not $found) {
        throw "Could not find water_polygons.shp after extracting coastline data."
    }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($found.Name)
    $dir = $found.Directory.FullName
    Get-ChildItem -Path $dir -Filter "$base.*" | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $coastDir $_.Name) -Force
    }
    Log "Coastline data ready: $targetShp"
}

function Ensure-Landcover([string]$DataDir, [int]$Retries) {
    $landDir = Join-Path $DataDir "landcover"
    $needFiles = @(
        (Join-Path $landDir "ne_10m_urban_areas\\ne_10m_urban_areas.shp"),
        (Join-Path $landDir "ne_10m_antarctic_ice_shelves_polys\\ne_10m_antarctic_ice_shelves_polys.shp"),
        (Join-Path $landDir "ne_10m_glaciated_areas\\ne_10m_glaciated_areas.shp")
    )
    if ($needFiles | Where-Object { -not (Test-Path $_) } | Measure-Object | Select-Object -ExpandProperty Count) {
        if (-not $DownloadLandcover) {
            throw "Missing landcover data under: $landDir"
        }
        Ensure-Dir $landDir
        Log "Downloading landcover data..."
        $downloads = @(
            @{ Name = "ne_10m_antarctic_ice_shelves_polys"; Url = "https://naciscdn.org/naturalearth/10m/physical/ne_10m_antarctic_ice_shelves_polys.zip" },
            @{ Name = "ne_10m_urban_areas"; Url = "https://naciscdn.org/naturalearth/10m/cultural/ne_10m_urban_areas.zip" },
            @{ Name = "ne_10m_glaciated_areas"; Url = "https://naciscdn.org/naturalearth/10m/physical/ne_10m_glaciated_areas.zip" }
        )
        foreach ($d in $downloads) {
            $zipPath = Join-Path $landDir ($d.Name + ".zip")
            Download-File $d.Url $zipPath $Retries
            $outDir = Join-Path $landDir $d.Name
            Expand-Archive -Path $zipPath -DestinationPath $outDir -Force
        }
        Log "Landcover data ready."
    } else {
        Log "Landcover data present: $landDir"
    }
}

$toolsDir = Join-Path $PSScriptRoot "tools"
$tilemaker = Join-Path $toolsDir "tilemaker.exe"
$pmtiles = Join-Path $toolsDir "pmtiles.exe"
$resourcesDir = Join-Path $toolsDir "resources"

if (-not (Test-Path $pmtiles)) { throw "Missing tool: $pmtiles" }
if (-not (Test-Path $resourcesDir)) { throw "Missing resources: $resourcesDir" }
if (-not $UseWsl) {
    if (-not (Test-Path $tilemaker)) { throw "Missing tool: $tilemaker" }
} else {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) { throw "WSL not found. Install WSL or set -UseWsl:$false" }
    $tm = & wsl.exe -d $WslDistro -- which tilemaker 2>$null
    if (-not $tm) { throw "tilemaker not found in WSL distro '$WslDistro'. Install it or set -UseWsl:$false" }
}

Ensure-Dir $OutputDir
$OutputDir = Resolve-Path $OutputDir

Update-Progress "Setup" "Preparing workspace" 5
$workDir = Join-Path $OutputDir "_work"
$pbfDir = Join-Path $workDir "pbf"
$storeDir = Join-Path $workDir "store"
$configDir = Join-Path $workDir "tilemaker"
Ensure-Dir $pbfDir
Ensure-Dir $storeDir
Ensure-Dir $configDir

$drive = (Get-Item $OutputDir).PSDrive
$freeGB = [math]::Round($drive.Free / 1GB, 2)
Log "Free disk on $($drive.Name): ${freeGB}GB (min required: ${MinFreeGB}GB)"
if ($freeGB -lt $MinFreeGB) {
    throw "Low disk space on $($drive.Name): ${freeGB}GB free, need at least ${MinFreeGB}GB."
}

Update-Progress "Setup" "Preparing config" 10
$configPath = Join-Path $configDir "config-openmaptiles.json"
$processPath = Join-Path $configDir "process-openmaptiles.lua"
$configAdjustedPath = Join-Path $configDir "config-openmaptiles.minmax.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Normalize-Lf([string]$Text) {
    return ($Text -replace "`r`n?", "`n")
}
$resourceConfigPath = Join-Path $resourcesDir "config-openmaptiles.json"
$resourceProcessPath = Join-Path $resourcesDir "process-openmaptiles.lua"
$resourceNeedsWsl = $false
if (Test-Path $resourceProcessPath) {
    $resourceRaw = Get-Content -Raw $resourceProcessPath
    if ($resourceRaw -match "(^|[^:])\bFind\(") {
        $resourceNeedsWsl = $true
    }
}

$needsRefresh = $false
if (Test-Path $processPath) {
    $raw = Get-Content -Raw $processPath
    $lineCount = (Get-Content $processPath).Count
    if ($lineCount -lt 20 -or ($raw -notmatch "`n")) {
        Log "Process file looks invalid (lines=$lineCount). Refreshing."
        $needsRefresh = $true
    } elseif ($raw -match "(^|[^:])\bFind\(") {
        Log "Process file contains bare Find(..). Refreshing."
        $needsRefresh = $true
    }
}
if ((Test-Path $configPath) -and (Test-Path $processPath) -and (-not $needsRefresh)) {
    Log "Using existing config/process in $configDir"
} elseif ($UseWsl -and ($UseWslExampleFiles -or $resourceNeedsWsl)) {
    $wslConfig = & wsl.exe -d $WslDistro -- sh -lc "test -f /usr/share/doc/tilemaker/examples/config-openmaptiles.json && echo ok" 2>$null
    $wslProcess = & wsl.exe -d $WslDistro -- sh -lc "test -f /usr/share/doc/tilemaker/examples/process-openmaptiles.lua && echo ok" 2>$null
    if (-not $wslConfig -or -not $wslProcess) {
        throw "tilemaker examples not found in WSL. Expected /usr/share/doc/tilemaker/examples/*. Install tilemaker in WSL or copy matching config/process files."
    }
    Log "Using WSL tilemaker example config/process (version-matched)."
    $configText = & wsl.exe -d $WslDistro -- cat /usr/share/doc/tilemaker/examples/config-openmaptiles.json
    $processText = & wsl.exe -d $WslDistro -- cat /usr/share/doc/tilemaker/examples/process-openmaptiles.lua
    [System.IO.File]::WriteAllText($configPath, (Normalize-Lf $configText), $utf8NoBom)
    [System.IO.File]::WriteAllText($processPath, (Normalize-Lf $processText), $utf8NoBom)
} else {
    $configSrc = Get-Content -Raw $resourceConfigPath
    $processSrc = Get-Content -Raw $resourceProcessPath
    [System.IO.File]::WriteAllText($configPath, (Normalize-Lf $configSrc), $utf8NoBom)
    [System.IO.File]::WriteAllText($processPath, (Normalize-Lf $processSrc), $utf8NoBom)
}
Update-ConfigZoom -ConfigIn $configPath -ConfigOut $configAdjustedPath -MinZoom $MinZoom -MaxZoom $MaxZoom
Log "Config prepared: $configAdjustedPath (MinZoom=$MinZoom, MaxZoom=$MaxZoom)"

$regions = @(
    "baden-wuerttemberg",
    "bayern",
    "berlin",
    "brandenburg",
    "bremen",
    "hamburg",
    "hessen",
    "mecklenburg-vorpommern",
    "niedersachsen",
    "nordrhein-westfalen",
    "rheinland-pfalz",
    "saarland",
    "sachsen",
    "sachsen-anhalt",
    "schleswig-holstein",
    "thueringen"
)

Update-Progress "Setup" "Ensuring coastline data" 15
Ensure-Coastline -DataDir $configDir -Retries $DownloadRetries
Update-Progress "Setup" "Ensuring landcover data" 20
Ensure-Landcover -DataDir $configDir -Retries $DownloadRetries

$manifestPath = Join-Path $OutputDir "download_manifest.json"
$manifestItems = @()

$total = $regions.Count
$index = 0
foreach ($slug in $regions) {
    $index++
    Log "Region [$index/$total]: $slug"
    $pbfUrl = "https://download.geofabrik.de/europe/germany/$slug-latest.osm.pbf"
    $pbfPath = Join-Path $pbfDir "$slug-latest.osm.pbf"
    $md5Url = "$pbfUrl.md5"
    $md5Path = Join-Path $pbfDir "$slug-latest.osm.pbf.md5"
    $mbtilesPath = Join-Path $OutputDir ("de_" + $slug + ".mbtiles")
    $pmtilesPath = Join-Path $OutputDir ("de_" + $slug + ".pmtiles")

    if ($VerifyChecksums -and (Test-Path $pbfPath)) {
        Update-Progress "PBF" "[$slug] Checking existing checksum" 25
        if (-not (Test-Path $md5Path)) {
            Download-File $md5Url $md5Path $DownloadRetries
        }
        if (-not (Verify-Md5 $pbfPath $md5Path)) {
            Log "Checksum mismatch, re-downloading: $pbfPath"
            Remove-Item -Force $pbfPath
        }
    }

    if (-not (Test-Path $pbfPath)) {
        Update-Progress "PBF" "[$slug] Downloading PBF" 30
        Log "PBF missing, downloading: $pbfPath"
        Download-File $pbfUrl $pbfPath $DownloadRetries
    }

    if ($VerifyChecksums) {
        Update-Progress "PBF" "[$slug] Verifying MD5" 35
        Log "Verifying MD5: $pbfPath"
        Download-File $md5Url $md5Path $DownloadRetries
        if (-not (Verify-Md5 $pbfPath $md5Path)) {
            throw "MD5 check failed for $pbfPath"
        }
    }

    if (-not (Test-Path $mbtilesPath)) {
        Update-Progress "Tilemaker" "[$slug] Generating MBTiles" 55
        Log "Building MBTiles for $slug -> $mbtilesPath"
        if ($UseWsl) {
            Run-TilemakerWsl `
                -WorkDirWin $configDir `
                -InputWin $pbfPath `
                -OutputWin $mbtilesPath `
                -ConfigWin $configAdjustedPath `
                -ProcessWin $processPath `
                -StoreWin $storeDir
            if ($LASTEXITCODE -ne 0) { throw "tilemaker (WSL) failed for $slug (exit code: $LASTEXITCODE)" }
        } else {
            Push-Location $configDir
            try {
                & $tilemaker `
                    --input $pbfPath `
                    --output $mbtilesPath `
                    --config $configAdjustedPath `
                    --process $processPath `
                    --store $storeDir `
                    --threads 0
                if ($LASTEXITCODE -ne 0) { throw "tilemaker failed for $slug (exit code: $LASTEXITCODE)" }
            } finally {
                Pop-Location
            }
        }
    } else {
        Log "Skip tilemaker (exists): $mbtilesPath"
    }

    if (-not (Test-Path $pmtilesPath)) {
        Update-Progress "PMTiles" "[$slug] Converting MBTiles -> PMTiles" 85
        Log "Converting to PMTiles -> $pmtilesPath"
        & $pmtiles convert $mbtilesPath $pmtilesPath
        if ($LASTEXITCODE -ne 0) { throw "pmtiles convert failed for $slug (exit code: $LASTEXITCODE)" }
    } else {
        Log "Skip pmtiles (exists): $pmtilesPath"
    }

    $sizeBytes = (Get-Item $pmtilesPath).Length
    $manifestItems += [ordered]@{
        name = "de_$slug"
        file = "de_$slug.pmtiles"
        sizeBytes = $sizeBytes
        url = if ($ManifestBaseUrl) { "$ManifestBaseUrl/de_$slug.pmtiles" } else { "" }
    }

    if ($DeleteMbtiles -and (Test-Path $mbtilesPath)) {
        Remove-Item -Force $mbtilesPath
    }
}

$manifest = [ordered]@{
    generatedAt = (Get-Date).ToString("o")
    format = "pmtiles"
    minZoom = $MinZoom
    maxZoom = $MaxZoom
    regions = $manifestItems
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
Update-Progress "Manifest" "Writing manifest" 95
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), $utf8NoBom)
Log "Manifest written: $manifestPath"
Update-Progress "Done" "Completed" 100
Log "Done. Output: $OutputDir"
