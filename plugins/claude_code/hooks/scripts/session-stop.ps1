# Stop hook (Windows / pwsh): defers to the gingko CLI binary, which
# reads the hook payload from stdin, summarizes the transcript tail,
# and emits the bail JSON on stdout.

if (-not $IsWindows) { exit 0 }

$gingkoHome = if ($env:GINGKO_HOME) { $env:GINGKO_HOME } else { Join-Path $env:USERPROFILE '.gingko' }
$env:Path = "$(Join-Path $gingkoHome 'bin');$env:Path"

if (-not (Get-Command gingko -ErrorAction SilentlyContinue)) {
    Write-Output '{"continue": true, "suppressOutput": true}'
    exit 0
}

& gingko hook session-stop
exit $LASTEXITCODE
