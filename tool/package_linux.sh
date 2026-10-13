#!/usr/bin/env bash
# Builds the Linux release and packages it as a .deb in dist/.
#
#   tool/package_linux.sh
#
# Needs: flutter, clang, cmake, ninja, pkg-config, libgtk-3-dev, libmpv-dev,
# libsecret-1-dev, libjsoncpp-dev, dpkg-deb.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep '^version:' pubspec.yaml | sed -E 's/version: *([^+]*).*/\1/')
ARCH=x64
DEB_ARCH=amd64
NAME=catplay
BUNDLE=build/linux/$ARCH/release/bundle

flutter build linux --release

mkdir -p dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# libmpv is not bundled on Linux; depend on whichever soname we linked against.
MPV_SO=$(ldd "$BUNDLE"/lib/*.so | grep -o 'libmpv\.so\.[0-9]*' | sort -u | head -1)
MPV_PKG=libmpv${MPV_SO##*.so.}

# --- .deb: installs to /opt/catplay with a menu entry -----------------------
DEB=$STAGE/deb
mkdir -p "$DEB/opt" "$DEB/usr/bin" "$DEB/usr/share/applications" \
  "$DEB/usr/share/icons/hicolor/512x512/apps" "$DEB/DEBIAN"
cp -r "$BUNDLE" "$DEB/opt/$NAME"
mv "$DEB/opt/$NAME/iptv_player" "$DEB/opt/$NAME/$NAME"
ln -s "/opt/$NAME/$NAME" "$DEB/usr/bin/$NAME"
cp assets/brand/mark.png "$DEB/usr/share/icons/hicolor/512x512/apps/$NAME.png"
cat > "$DEB/usr/share/applications/$NAME.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CAT
Comment=Fast IPTV player: Xtream Codes, M3U, XMLTV guide, movies & series
Exec=/opt/$NAME/$NAME
Icon=$NAME
Categories=AudioVideo;Video;Player;TV;
StartupWMClass=$NAME
Terminal=false
EOF
cat > "$DEB/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Section: video
Priority: optional
Architecture: $DEB_ARCH
Depends: libgtk-3-0 | libgtk-3-0t64, $MPV_PKG, libsecret-1-0, libjsoncpp25 | libjsoncpp26
Maintainer: CAT <noreply@catplay.app>
Description: CAT - fast desktop IPTV player
 Xtream Codes, M3U/M3U8 and XMLTV guides, live TV, movies and series.
EOF
dpkg-deb --root-owner-group --build "$DEB" "dist/${NAME}_${VERSION}_${DEB_ARCH}.deb" >/dev/null

ls -lh "dist/${NAME}_${VERSION}_${DEB_ARCH}.deb"
