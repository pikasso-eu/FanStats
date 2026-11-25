#!/bin/bash
# Baut FanStats.app nach dist/. Kein Xcode-Projekt nötig.
#
# Es entsteht ein Universal-Binary: arm64 für Apple Silicon, x86_64 für
# Intel-Macs. Beide Architekturen werden immer gebaut, egal auf welchem Mac
# dieser Script läuft - die macOS-SDK enthält beide Slice-Typen.
set -euo pipefail
cd "$(dirname "$0")"

# Build-Caches im Projekt halten (stört nicht, hält das Home-Verzeichnis sauber)
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/modulecache"
mkdir -p .cache/modulecache .cache/swiftpm .cache/config .cache/security

ARCHS=(arm64 x86_64)
BINARIES=()

for ARCH in "${ARCHS[@]}"; do
    echo "Baue FanStats für $ARCH …"
    swift build -c release --product FanStats --arch "$ARCH" \
        --disable-sandbox \
        --cache-path "$PWD/.cache/swiftpm" \
        --config-path "$PWD/.cache/config" \
        --security-path "$PWD/.cache/security" \
        --scratch-path "$PWD/.build/$ARCH"
    BINARIES+=("$PWD/.build/$ARCH/release/FanStats")
done

APP="$PWD/dist/FanStats.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Beide Einzel-Binaries zu einem Fat-Binary zusammenfügen.
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/FanStats"
echo "Architekturen: $(lipo -archs "$APP/Contents/MacOS/FanStats")"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>FanStats</string>
    <key>CFBundleDisplayName</key>           <string>FanStats</string>
    <key>CFBundleExecutable</key>            <string>FanStats</string>
    <key>CFBundleIdentifier</key>            <string>local.fanstats</string>
    <key>CFBundleVersion</key>               <string>0.9.0</string>
    <key>CFBundleShortVersionString</key>    <string>0.9.0</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSHighResolutionCapable</key>       <true/>
</dict>
</plist>
PLIST

# Ad-hoc signieren: reicht für den lokalen Betrieb (kein Apple-Developer-Account nötig).
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "Hinweis: codesign fehlgeschlagen (App läuft trotzdem)"

echo "Fertig: $APP"
