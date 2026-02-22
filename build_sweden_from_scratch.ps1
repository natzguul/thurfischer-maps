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
    [string]$ManifestBaseUrl = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$progressPreference = "Continue"

$CountryName = "Sweden"
$CountryCode = "se"
$CountrySlug = "sweden"

function Log([string]$Message) {
    $ts = (Get-Date -Format "HH:mm:ss")
    Write-Host "[$ts] $Message"
}

function Convert-ToWslPath([string]$WindowsPath) {
    $full = $WindowsPath
    try { $full = (Resolve-Path $WindowsPath).Path } catch { $full = [System.IO.Path]::GetFullPath($WindowsPath) }
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

function Ensure-Dir([string]$Path) { if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null } }

function Download-File([string]$Url, [string]$OutFile, [int]$Retries) {
    Ensure-Dir (Split-Path $OutFile -Parent)
    if (Test-Path $OutFile) { Log "Skip download (exists): $OutFile"; return }
    $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Log "Downloading (attempt $i/$Retries): $Url"
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -MaximumRedirection 10
            return
        } catch {
            if ($i -eq $Retries -and $bits) {
                Log "Invoke-WebRequest failed, trying BITS once: $Url"
                Start-BitsTransfer -Source $Url -Destination $OutFile
                return
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
            if ($layer.PSObject.Properties.Name -contains "minzoom" -and $layer.minzoom -lt $MinZoom) { $layer.minzoom = $MinZoom }
            if ($layer.PSObject.Properties.Name -contains "maxzoom" -and $layer.maxzoom -gt $MaxZoom) { $layer.maxzoom = $MaxZoom }
        }
    }
    $jsonString = $json | ConvertTo-Json -Depth 50
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ConfigOut, $jsonString, $utf8NoBom)
}

function Ensure-Coastline([string]$DataDir, [int]$Retries) {
    $coastDir = Join-Path $DataDir "coastline"
    $targetShp = Join-Path $coastDir "water_polygons.shp"
    if (Test-Path $targetShp) { Log "Coastline data present: $targetShp"; return }
    if (-not $DownloadCoastline) { throw "Missing coastline data: $targetShp" }
    Ensure-Dir $coastDir
    $zipUrl = "https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip"
    $zipPath = Join-Path $coastDir "water-polygons-split-4326.zip"
    Download-File $zipUrl $zipPath $Retries
    $extractDir = Join-Path $coastDir "water-polygons-split-4326"
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $found = Get-ChildItem -Path $extractDir -Recurse -Filter "water_polygons.shp" | Select-Object -First 1
    if (-not $found) { throw "Could not find water_polygons.shp after extracting coastline data." }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($found.Name)
    $dir = $found.Directory.FullName
    Get-ChildItem -Path $dir -Filter "$base.*" | ForEach-Object { Copy-Item $_.FullName (Join-Path $coastDir $_.Name) -Force }
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
        if (-not $DownloadLandcover) { throw "Missing landcover data under: $landDir" }
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
if ($freeGB -lt $MinFreeGB) { throw "Low disk space on $($drive.Name): ${freeGB}GB free, need at least ${MinFreeGB}GB." }

$configPath = Join-Path $configDir "config-openmaptiles.json"
$processPath = Join-Path $configDir "process-openmaptiles.lua"
$configAdjustedPath = Join-Path $configDir "config-openmaptiles.minmax.json"
Copy-Item (Join-Path $resourcesDir "config-openmaptiles.json") $configPath -Force
Copy-Item (Join-Path $resourcesDir "process-openmaptiles.lua") $processPath -Force
Update-ConfigZoom -ConfigIn $configPath -ConfigOut $configAdjustedPath -MinZoom $MinZoom -MaxZoom $MaxZoom
Log "Config prepared: $configAdjustedPath (MinZoom=$MinZoom, MaxZoom=$MaxZoom)"

Ensure-Coastline -DataDir $configDir -Retries $DownloadRetries
Ensure-Landcover -DataDir $configDir -Retries $DownloadRetries

$manifestPath = Join-Path $OutputDir "download_manifest.json"
$manifestItems = @()

$slug = $CountrySlug
$pbfUrl = "https://download.geofabrik.de/europe/$slug-latest.osm.pbf"
$pbfPath = Join-Path $pbfDir "$slug-latest.osm.pbf"
$md5Url = "$pbfUrl.md5"
$md5Path = Join-Path $pbfDir "$slug-latest.osm.pbf.md5"
$mbtilesPath = Join-Path $OutputDir ("$CountryCode" + "_" + $slug + ".mbtiles")
$pmtilesPath = Join-Path $OutputDir ("$CountryCode" + "_" + $slug + ".pmtiles")

if ($VerifyChecksums -and (Test-Path $pbfPath)) {
    if (-not (Test-Path $md5Path)) { Download-File $md5Url $md5Path $DownloadRetries }
    if (-not (Verify-Md5 $pbfPath $md5Path)) { Log "Checksum mismatch, re-downloading: $pbfPath"; Remove-Item -Force $pbfPath }
}

if (-not (Test-Path $pbfPath)) { Log "PBF missing, downloading: $pbfPath"; Download-File $pbfUrl $pbfPath $DownloadRetries }

if ($VerifyChecksums) {
    Log "Verifying MD5: $pbfPath"
    Download-File $md5Url $md5Path $DownloadRetries
    if (-not (Verify-Md5 $pbfPath $md5Path)) { throw "MD5 check failed for $pbfPath" }
}

if (-not (Test-Path $mbtilesPath)) {
    Log "Building MBTiles for $CountryName -> $mbtilesPath"
    if ($UseWsl) {
        Run-TilemakerWsl -WorkDirWin $configDir -InputWin $pbfPath -OutputWin $mbtilesPath -ConfigWin $configAdjustedPath -ProcessWin $processPath -StoreWin $storeDir
        if ($LASTEXITCODE -ne 0) { throw "tilemaker (WSL) failed for $CountryName (exit code: $LASTEXITCODE)" }
    } else {
        Push-Location $configDir
        try {
            & $tilemaker --input $pbfPath --output $mbtilesPath --config $configAdjustedPath --process $processPath --store $storeDir --threads 0
            if ($LASTEXITCODE -ne 0) { throw "tilemaker failed for $CountryName (exit code: $LASTEXITCODE)" }
        } finally { Pop-Location }
    }
} else {
    Log "Skip tilemaker (exists): $mbtilesPath"
}

if (-not (Test-Path $pmtilesPath)) {
    Log "Converting to PMTiles -> $pmtilesPath"
    & $pmtiles convert $mbtilesPath $pmtilesPath
    if ($LASTEXITCODE -ne 0) { throw "pmtiles convert failed for $CountryName (exit code: $LASTEXITCODE)" }
} else {
    Log "Skip pmtiles (exists): $pmtilesPath"
}

$sizeBytes = (Get-Item $pmtilesPath).Length
$manifestItems += [ordered]@{
    name = "$CountryCode" + "_" + $slug
    file = "$CountryCode" + "_" + $slug + ".pmtiles"
    sizeBytes = $sizeBytes
    url = if ($ManifestBaseUrl) { "$ManifestBaseUrl/$CountryCode" + "_" + $slug + ".pmtiles" } else { "" }
}

if ($DeleteMbtiles -and (Test-Path $mbtilesPath)) { Remove-Item -Force $mbtilesPath }

$manifest = [ordered]@{
    generatedAt = (Get-Date).ToString("o")
    format = "pmtiles"
    minZoom = $MinZoom
    maxZoom = $MaxZoom
    regions = $manifestItems
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), $utf8NoBom)
Log "Manifest written: $manifestPath"
Log "Done. Output: $OutputDir"
