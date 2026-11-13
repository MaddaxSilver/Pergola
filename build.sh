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

# The water's warp shader (Shaders/Liquid.metal).
xcrun metal -c Shaders/Liquid.metal -o build/Liquid.air
xcrun metallib build/Liquid.air -o "$APP/Contents/Resources/Liquid.metallib"
rm -f build/Liquid.air

# Browser music: MediaRemote Adapter (BSD-3-Clause, ThirdParty/mediaremote-adapter) reads what any app,
# browsers included, reports as now playing. macOS only lets Apple's own programs ask, so Pergola runs it
# inside /usr/bin/perl. Built here as a small framework next to the script that loads it.
MRA=ThirdParty/mediaremote-adapter
FW="$APP/Contents/Resources/MediaRemoteAdapter.framework"
mkdir -p "$FW/Versions/A/Resources"
clang -dynamiclib -fobjc-arc -fvisibility=default -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -I"$MRA/include" -I"$MRA/src" "$MRA"/src/adapter/*.m "$MRA"/src/private/*.m "$MRA"/src/utility/*.m \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$FW/Versions/A/MediaRemoteAdapter"
cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundleIdentifier</key><string>com.pergola.MediaRemoteAdapter</string>
<key>CFBundleName</key><string>MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PLIST
ln -sfn A "$FW/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$FW/Resources"
cp "$MRA/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"

IDENTITY="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$FW"

# Safari extension (SafariExtension/): reports where the playing video is on the page, for
# picture in picture. Turned on by you in Safari › Settings › Extensions.
EXT="$APP/Contents/PlugIns/PergolaSafari.appex"
mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
for ARCH in arm64 x86_64; do
    swiftc -O -parse-as-library -application-extension -module-name PergolaSafari \
        -target "$ARCH-apple-macos26.0" SafariExtension/Handler.swift \
        -framework SafariServices -Xlinker -e -Xlinker _NSExtensionMain \
        -o "build/PergolaSafari-$ARCH"
done
lipo -create build/PergolaSafari-arm64 build/PergolaSafari-x86_64 -output "$EXT/Contents/MacOS/PergolaSafari"
rm -f build/PergolaSafari-arm64 build/PergolaSafari-x86_64
cp SafariExtension/Info.plist "$EXT/Contents/Info.plist"
cp -R SafariExtension/Resources/ "$EXT/Contents/Resources/"
sips -s format png -Z 128 "$APP/Contents/Resources/AppIcon.icns" --out "$EXT/Contents/Resources/icon.png" >/dev/null
codesign --force --sign "${IDENTITY:--}" --entitlements SafariExtension/Extension.entitlements "$EXT"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

# ./build.sh --install also puts it in /Applications (where Open at Login needs it to be).
if [[ "${1:-}" == "--install" ]]; then
    pkill -x Pergola 2>/dev/null || true
    rm -rf /Applications/Pergola.app
    ditto "$APP" /Applications/Pergola.app
    echo "Installed /Applications/Pergola.app"
fi
