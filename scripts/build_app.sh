#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product APFSFindDesktop
BIN_DIR="$(swift build -c release --show-bin-path)"
[[ ! -L "$ROOT/dist" ]] || { echo "Refusing symlink dist" >&2; exit 1; }
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/APFSFind.app"
[[ ! -L "$OUT" ]] || { echo "Refusing symlink app" >&2; exit 1; }
if [[ -e "$OUT" ]]; then
  [[ -d "$OUT" && "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$OUT/Contents/Info.plist")" == "local.apfsfind.desktop" ]] || { echo "Refusing foreign bundle" >&2; exit 1; }
fi
STAGE="$(mktemp -d "$ROOT/dist/.app-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/APFSFind.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/APFSFindDesktop" "$APP/Contents/MacOS/APFSFind"
chmod 755 "$APP/Contents/MacOS/APFSFind"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.apfsfind.desktop</string>
<key>CFBundleName</key><string>APFSFind</string>
<key>CFBundleDisplayName</key><string>APFSFind</string>
<key>CFBundleExecutable</key><string>APFSFind</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleVersion</key><string>600</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
if [[ -e "$OUT" ]]; then rm -rf "$OUT"; fi
mv "$APP" "$OUT"
echo "$OUT"
