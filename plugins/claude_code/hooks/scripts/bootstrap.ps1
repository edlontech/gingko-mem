# SessionStart bootstrap (Windows / pwsh): mirrors hooks/scripts/bootstrap.sh.
# Ensures the gingko binary is installed and the user-level service is
# running before the main session-start hook fires. Failures surface to
# Claude Code via systemMessage but never block session start.

if (-not $IsWindows) { exit 0 }

$ErrorActionPreference = 'Continue'

function Send-SystemMessage {
    param([string]$Message)
    $payload = @{ systemMessage = $Message } | ConvertTo-Json -Compress
    Write-Output $payload
}

$gingkoUrl = if ($env:GINGKO_URL) { $env:GINGKO_URL } else { 'http://localhost:8008' }
$gingkoHome = if ($env:GINGKO_HOME) { $env:GINGKO_HOME } else { Join-Path $env:USERPROFILE '.gingko' }
$gingkoBinDir = Join-Path $gingkoHome 'bin'
$env:Path = "$gingkoBinDir;$env:Path"

if (-not $env:CLAUDE_PLUGIN_ROOT) {
    Send-SystemMessage '[gingko] CLAUDE_PLUGIN_ROOT not set'
    exit 0
}

$installer = Join-Path $env:CLAUDE_PLUGIN_ROOT 'scripts\smart-install.ps1'
$installLog = ''

try {
    $installLog = (& $installer 2>&1 | Out-String).Trim()
} catch {
    Send-SystemMessage "[gingko] smart-install failed; continuing without bootstrap`n$_"
    exit 0
}

function Test-GingkoHealth {
    try {
        $null = Invoke-WebRequest -Uri "$gingkoUrl/health" -TimeoutSec 2 -UseBasicParsing
        return $true
    } catch {
        return $false
    }
}

if (Test-GingkoHealth) {
    if ($installLog) { Send-SystemMessage $installLog }
    exit 0
}

if (Get-Command gingko -ErrorAction SilentlyContinue) {
    & gingko service install 2>&1 | Out-Null
    & gingko service start 2>&1 | Out-Null
}

for ($i = 0; $i -lt 20; $i++) {
    if (Test-GingkoHealth) {
        $msg = "[gingko] service started at $gingkoUrl"
        if ($installLog) { $msg = "$installLog`n$msg" }
        Send-SystemMessage $msg
        exit 0
    }
    Start-Sleep -Seconds 1
}

$msg = "[gingko] service did not become healthy at $gingkoUrl within 20s"
if ($installLog) { $msg = "$installLog`n$msg" }
Send-SystemMessage $msg
exit 0
