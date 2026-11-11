#!/bin/bash
# Builds Pergola.app into ./build. Signs with your Apple Development identity when
# one is available so macOS remembers Pergola's permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Pergola"

APP="build/Pergola.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pergola"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Render the app icon from code (Sources/Pergola/Icons.swift).
"$BIN" --write-icon "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

# ./build.sh --install also puts it in /Applications (where Open at Login needs it to be).
if [[ "${1:-}" == "--install" ]]; then
    pkill -x Pergola 2>/dev/null || true
    rm -rf /Applications/Pergola.app
    ditto "$APP" /Applications/Pergola.app
    echo "Installed /Applications/Pergola.app"
fi
