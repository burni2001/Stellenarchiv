#!/bin/zsh
# Baut Stellenarchiv.app. Mit "./build.sh install" wird die App nach ~/Applications kopiert.
set -euo pipefail
cd "$(dirname "$0")"

# Zwischendateien ausserhalb des Projekts (Cloud-Sync-Ordner wie OneDrive stören den Build)
SCRATCH="$HOME/Library/Caches/Stellenarchiv-build"
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/Stellenarchiv"

APP="build/Stellenarchiv.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Stellenarchiv"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep -s - "$APP"
echo "Gebaut: $PWD/$APP"

if [[ "${1:-}" == "install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Stellenarchiv.app
  cp -R "$APP" ~/Applications/
  echo "Installiert: ~/Applications/Stellenarchiv.app"
fi
