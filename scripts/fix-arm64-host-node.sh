#!/bin/sh
#
# smartdns-ui builds a Next.js web UI and needs a working Node >= 20.9 plus
# npm. The feed package feeds/packages/lang/node/node installs a prebuilt
# host node, but its Makefile hardcodes "node-v*-linux-x64.tar.gz": on an
# arm64 build host that binary cannot run (execve fails, npm dies with a
# Rosetta "Trace/breakpoint trap"), and smartdns' compile step swallows the
# error until it tries to copy the missing smartdns-webui/out.
#
# Run this after feeds install on arm64 hosts: it installs the official
# arm64 Node into staging_dir/hostpkg and points bin/node at it, keeping the
# npm/npx symlinks that the feed installed.
set -e

case "$(uname -m)" in
	arm64|aarch64) ;;
	*) exit 0 ;;
esac

BIN=staging_dir/hostpkg/bin
[ -d "$BIN" ] || exit 0
[ -e "$BIN/node" ] || exit 0

if "$BIN/node" --version >/dev/null 2>&1; then
	echo "host node already runnable: $("$BIN/node" --version)"
	exit 0
fi

VER=v22.11.0
TGZ=dl/node-$VER-linux-arm64.tar.xz
DEST=staging_dir/hostpkg/node-arm64

[ -f "$TGZ" ] || curl -fL --retry 3 -o "$TGZ" "https://nodejs.org/dist/$VER/node-$VER-linux-arm64.tar.xz"
mkdir -p "$DEST"
tar -xJf "$TGZ" -C "$DEST" --strip-components=1

[ -e "$BIN/node.x64" ] || cp -a "$BIN/node" "$BIN/node.x64"
ln -sf "$PWD/$DEST/bin/node" "$BIN/node"

echo "host node replaced with $("$BIN/node" --version) (arm64)"
