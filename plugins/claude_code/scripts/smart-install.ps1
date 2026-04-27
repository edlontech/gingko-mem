# Idempotent installer for Windows: downloads the gingko binary matching
# the plugin version into $GINGKO_HOME\bin\gingko.exe, verifies SHA256,
# and records a marker so subsequent runs are no-ops until the plugin is
# upgraded. Mirrors scripts/smart-install.sh.

if (-not $IsWindows) { exit 0 }

$ErrorActionPreference = 'Stop'

$gingkoHome = if ($env:GINGKO_HOME) { $env:GINGKO_HOME } else { Join-Path $env:USERPROFILE '.gingko' }
$gingkoBinDir = Join-Path $gingkoHome 'bin'
$gingkoBin = Join-Path $gingkoBinDir 'gingko.exe'
$marker = Join-Path $gingkoHome '.install-version'
$repo = 'edlontech/gingko-mem'

if (-not $env:CLAUDE_PLUGIN_ROOT) {
    Write-Error '[gingko] CLAUDE_PLUGIN_ROOT not set'
    exit 1
}

$pluginJson = Join-Path $env:CLAUDE_PLUGIN_ROOT '.claude-plugin\plugin.json'
if (-not (Test-Path $pluginJson)) {
    Write-Error "[gingko] plugin.json not found at $pluginJson"
    exit 1
}

$manifest = Get-Content $pluginJson -Raw | ConvertFrom-Json
$version = $manifest.version
if (-not $version) {
    Write-Error '[gingko] could not parse version from plugin.json'
    exit 1
}

$tag = "gingko-v$version"

if ((Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $version) -and (Test-Path $gingkoBin)) {
    exit 0
}

$artifact = 'gingko_windows.exe'
$base = "https://github.com/$repo/releases/download/$tag"
$url = "$base/$artifact"
$sumUrl = "$base/SHA256SUMS"

Write-Host "[gingko] installing $version for windows (one-time download, ~50MB)"

New-Item -ItemType Directory -Force -Path $gingkoBinDir | Out-Null
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

try {
    $artifactPath = Join-Path $tmpDir $artifact
    Invoke-WebRequest -Uri $url -OutFile $artifactPath -UseBasicParsing

    $sumsPath = Join-Path $tmpDir 'SHA256SUMS'
    Invoke-WebRequest -Uri $sumUrl -OutFile $sumsPath -UseBasicParsing

    $expected = $null
    foreach ($line in Get-Content $sumsPath) {
        $parts = $line -split '\s+', 2
        if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $artifact) {
            $expected = $parts[0]
            break
        }
    }

    if (-not $expected) {
        Write-Error "[gingko] no checksum entry for $artifact in SHA256SUMS"
        exit 1
    }

    $actual = (Get-FileHash -Path $artifactPath -Algorithm SHA256).Hash
    if ($expected.ToLower() -ne $actual.ToLower()) {
        Write-Error "[gingko] checksum mismatch (expected=$expected actual=$actual)"
        exit 1
    }

    Move-Item -Force -Path $artifactPath -Destination $gingkoBin
    Set-Content -Path $marker -Value $version
    Write-Host "[gingko] installed $version to $gingkoBin"
} finally {
    Remove-Item -Recurse -Force -Path $tmpDir -ErrorAction SilentlyContinue
}
