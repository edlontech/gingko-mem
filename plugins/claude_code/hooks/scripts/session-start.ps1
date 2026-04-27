# SessionStart hook (Windows / pwsh): defers to the gingko CLI binary,
# which emits the hook JSON contract on stdout. Bootstrap runs before
# this hook and is responsible for installing the binary.

if (-not $IsWindows) { exit 0 }

$gingkoHome = if ($env:GINGKO_HOME) { $env:GINGKO_HOME } else { Join-Path $env:USERPROFILE '.gingko' }
$env:Path = "$(Join-Path $gingkoHome 'bin');$env:Path"

if (-not (Get-Command gingko -ErrorAction SilentlyContinue)) { exit 0 }

& gingko hook session-start
exit $LASTEXITCODE
