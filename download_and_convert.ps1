param(
    [string]$TargetDir = (Join-Path $PSScriptRoot "maps"),
    [string]$BaseUrl = "https://github.com/natzguul/thurfischer-maps/releases/download/V2",
    [string]$ManifestName = "download_manifest.json",
    [string[]]$OnlyRegions = @(),
    [switch]$ConvertMbtiles
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Log([string]$Message) {
    $ts = (Get-Date -Format "HH:mm:ss")
    Write-Host "[$ts] $Message"
}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Download-File([string]$Url, [string]$OutFile) {
    Ensure-Dir (Split-Path $OutFile -Parent)
    if (Test-Path $OutFile) {
        Log "Skip download (exists): $OutFile"
        return
    }
    $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
    try {
        Log "Downloading: $Url"
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -MaximumRedirection 10
    } catch {
        if ($bits) {
            Log "Invoke-WebRequest failed, trying BITS: $Url"
            Start-BitsTransfer -Source $Url -Destination $OutFile
        } else {
            throw
        }
    }
}

Ensure-Dir $TargetDir

$manifestUrl = "$BaseUrl/$ManifestName"
$manifestPath = Join-Path $TargetDir $ManifestName
Log "Fetching manifest: $manifestUrl"
Download-File $manifestUrl $manifestPath

$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
if (-not $manifest.regions) {
    throw "Manifest format invalid (missing regions)."
}

$regions = $manifest.regions
if ($OnlyRegions.Count -gt 0) {
    $set = $OnlyRegions | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique
    $regions = $regions | Where-Object { $set -contains $_.name.ToLowerInvariant() -or $set -contains $_.file.ToLowerInvariant() }
    if (-not $regions) {
        throw "No regions matched. Use e.g. -OnlyRegions de_thueringen"
    }
}

foreach ($r in $regions) {
    $url = $r.url
    if (-not $url) {
        $url = "$BaseUrl/$($r.file)"
    }
    $out = Join-Path $TargetDir $r.file
    Download-File $url $out
}

if ($ConvertMbtiles) {
    $pmtilesExe = Join-Path $PSScriptRoot "pmtiles.exe"
    if (-not (Test-Path $pmtilesExe)) {
        throw "pmtiles.exe not found in $PSScriptRoot"
    }
    Get-ChildItem -Path $TargetDir -Filter "*.mbtiles" | ForEach-Object {
        $out = Join-Path $TargetDir ($_.BaseName + ".pmtiles")
        if (Test-Path $out) {
            Log "Skip convert (exists): $out"
            return
        }
        Log "Converting: $($_.FullName) -> $out"
        & $pmtilesExe convert $_.FullName $out
        if ($LASTEXITCODE -ne 0) { throw "pmtiles convert failed for $($_.Name)" }
    }
}

Log "Done. Files in: $TargetDir"
