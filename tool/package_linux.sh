#!/usr/bin/env bash
# Builds the Rust desktop app and packages it as a .deb in dist/.
#
#   tool/package_linux.sh
#
# Needs: Rust (cargo), cargo-deb (`cargo install cargo-deb`), pkg-config.
# libmpv is not bundled: the package depends on libmpv2 (Ubuntu 24.04+) or
# libmpv1 (22.04) and the app loads whichever is installed.
set -euo pipefail
cd "$(dirname "$0")/../desktop"

VERSION=$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)

cargo build --release --locked
cargo deb --no-build --locked

mkdir -p ../dist
cp target/debian/catplay_"$VERSION"-1_amd64.deb "../dist/catplay_${VERSION}_amd64.deb"
ls -lh "../dist/catplay_${VERSION}_amd64.deb"
