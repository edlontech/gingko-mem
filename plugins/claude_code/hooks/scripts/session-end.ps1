# SessionEnd hook (Windows / pwsh): defers to the gingko CLI binary,
# which commits the active session and clears the on-disk pointer.

if (-not $IsWindows) { exit 0 }

$gingkoHome = if ($env:GINGKO_HOME) { $env:GINGKO_HOME } else { Join-Path $env:USERPROFILE '.gingko' }
$env:Path = "$(Join-Path $gingkoHome 'bin');$env:Path"

if (-not (Get-Command gingko -ErrorAction SilentlyContinue)) { exit 0 }

& gingko hook session-end
exit $LASTEXITCODE
