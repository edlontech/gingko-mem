set windows-shell := ["bash", "-cu"]

default_target := if os() == "macos" { "macos_silicon" } else if os() == "windows" { "windows" } else if arch() == "aarch64" { "linux_arm" } else { "linux" }

# Build for the current native platform
build: (build-target default_target)

# Build a specific target
build-target target:
    mix deps.get
    mix assets.deploy
    BURRITO_TARGET={{target}} MIX_ENV=prod mix release

# Build for macOS Apple Silicon
build-macos: (build-target "macos_silicon")

# Build for Linux x86_64
build-linux: (build-target "linux")

# Build for Linux aarch64
build-linux-arm: (build-target "linux_arm")

# Build for Windows x86_64
build-windows: (build-target "windows")

# Clean build artifacts
clean:
    rm -rf burrito_out/
    rm -rf _build/prod/
    rm -rf "${HOME}/Library/Application Support/.burrito"
    rm -rf "${XDG_DATA_HOME:-${HOME}/.local/share}/.burrito"
