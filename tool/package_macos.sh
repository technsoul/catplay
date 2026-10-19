#!/usr/bin/env bash
# Builds the Rust desktop app as CAT.app with libmpv bundled, in a
# drag-to-Applications .dmg in dist/.
#
#   tool/package_macos.sh
#
# Needs: Rust, Homebrew `mpv` and `dylibbundler`. The app is built for the
# Mac's own architecture (Apple Silicon on GitHub's macos-latest runners).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -m1 '^version' desktop/Cargo.toml | cut -d'"' -f2)
BREW=$(brew --prefix)

(cd desktop && cargo build --release --locked)

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/dmg/CAT.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp desktop/target/release/catplay "$APP/Contents/MacOS/CAT"

# libmpv is loaded at run time from Contents/Frameworks; copy it there with
# every library it needs, rewritten to load from the same folder.
MPV=$(ls "$BREW"/lib/libmpv.2.dylib "$BREW"/opt/mpv/lib/libmpv.2.dylib 2>/dev/null | head -1)
cp -L "$MPV" "$APP/Contents/Frameworks/libmpv.2.dylib"
chmod u+w "$APP/Contents/Frameworks/libmpv.2.dylib"
install_name_tool -id @loader_path/libmpv.2.dylib "$APP/Contents/Frameworks/libmpv.2.dylib"
dylibbundler -cd -of -b \
  -x "$APP/Contents/Frameworks/libmpv.2.dylib" \
  -d "$APP/Contents/Frameworks/" \
  -p @loader_path/ \
  -s "$BREW/lib"

# App icon from the brand mark.
ICONSET="$STAGE/CAT.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/brand/mark.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/brand/mark.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/CAT.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CAT</string>
  <key>CFBundleDisplayName</key><string>CAT</string>
  <key>CFBundleIdentifier</key><string>com.iptvplayer.iptvPlayer</string>
  <key>CFBundleExecutable</key><string>CAT</string>
  <key>CFBundleIconFile</key><string>CAT</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature (the bundled libraries were rewritten above).
codesign --force --deep --sign - "$APP"

ln -s /Applications "$STAGE/dmg/Applications"
mkdir -p dist
hdiutil create -volname CAT -srcfolder "$STAGE/dmg" -ov -format UDZO "dist/catplay-v$VERSION-macos.dmg"
ls -lh "dist/catplay-v$VERSION-macos.dmg"
