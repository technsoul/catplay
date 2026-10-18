#!/usr/bin/env bash
# Builds the Linux release and packages it as a .deb in dist/.
#
#   tool/package_linux.sh
#
# Needs: flutter, clang, cmake, ninja, pkg-config, libgtk-3-dev, libmpv-dev,
# libsecret-1-dev, libjsoncpp-dev, patchelf, dpkg-deb.
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

# --- .deb: installs to /opt/catplay with a menu entry -----------------------
DEB=$STAGE/deb
mkdir -p "$DEB/opt" "$DEB/usr/bin" "$DEB/usr/share/applications" \
  "$DEB/usr/share/icons/hicolor/512x512/apps" "$DEB/DEBIAN"
cp -r "$BUNDLE" "$DEB/opt/$NAME"
mv "$DEB/opt/$NAME/iptv_player" "$DEB/opt/$NAME/$NAME"
ln -s "/opt/$NAME/$NAME" "$DEB/usr/bin/$NAME"

# libmpv is not bundled. The build links it as libmpv.so.1 (Ubuntu 22.04),
# but 24.04+ only ships libmpv.so.2 (same render API). Link the plugins to an
# unversioned libmpv.so next to them instead, which postinst points at
# whichever libmpv the system has.
for so in "$DEB/opt/$NAME"/lib/*.so; do
  mpv=$(patchelf --print-needed "$so" | grep '^libmpv\.so' || true)
  [ -n "$mpv" ] || continue
  patchelf --replace-needed "$mpv" libmpv.so --set-rpath '$ORIGIN' "$so"
done
cat > "$DEB/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
case "\$1" in
  configure|triggered)
    lib=\$(ls /usr/lib/x86_64-linux-gnu/libmpv.so.[0-9]* 2>/dev/null | sort -V | tail -1)
    [ -z "\$lib" ] || ln -sf "\$lib" /opt/$NAME/lib/libmpv.so
    ;;
esac
EOF
cat > "$DEB/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
rm -f /opt/$NAME/lib/libmpv.so
EOF
chmod 755 "$DEB/DEBIAN/postinst" "$DEB/DEBIAN/prerm"
# Re-link when libmpv changes (a 22.04 -> 24.04 upgrade swaps libmpv1 for libmpv2).
cat > "$DEB/DEBIAN/triggers" <<EOF
interest-noawait /usr/lib/x86_64-linux-gnu/libmpv.so.1
interest-noawait /usr/lib/x86_64-linux-gnu/libmpv.so.2
EOF
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
Depends: libgtk-3-0 | libgtk-3-0t64, libmpv2 | libmpv1, libsecret-1-0, libjsoncpp25 | libjsoncpp26
Maintainer: CAT <noreply@catplay.app>
Description: CAT - fast desktop IPTV player
 Xtream Codes, M3U/M3U8 and XMLTV guides, live TV, movies and series.
EOF
dpkg-deb --root-owner-group --build "$DEB" "dist/${NAME}_${VERSION}_${DEB_ARCH}.deb" >/dev/null

ls -lh "dist/${NAME}_${VERSION}_${DEB_ARCH}.deb"
