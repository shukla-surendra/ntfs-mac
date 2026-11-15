#!/bin/bash
# Builds the open-source ntfs-3g driver against FUSE-T (no kernel extension, SIP stays on).
# Output: build/prefix/{bin,sbin,lib}
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER="${NTFS3G_VERSION:-2022.10.3}"
PREFIX="$ROOT/build/prefix"
SRC="$ROOT/vendor/ntfs-3g-src"
FUSE_HDR=/Library/Frameworks/fuse_t.framework/Headers

[ -d "$FUSE_HDR" ] || { echo "FUSE-T not found. Install: brew install --cask macos-fuse-t/cask/fuse-t"; exit 1; }
for t in autoconf automake libtool; do brew list "$t" >/dev/null 2>&1 || brew install "$t"; done
brew list gettext >/dev/null 2>&1 || brew install gettext
export PATH="$(brew --prefix libtool)/libexec/gnubin:$PATH"

if [ ! -d "$SRC" ]; then
  mkdir -p "$ROOT/vendor" "$SRC"
  curl -fsSL "https://github.com/tuxera/ntfs-3g/archive/refs/tags/$VER.tar.gz" | tar xz -C "$SRC" --strip-components=1
fi
cd "$SRC"
[ -x configure ] || ./autogen.sh
./configure --prefix="$PREFIX" --disable-static --with-fuse=external --disable-mount-helper --disable-ldconfig \
  FUSE_MODULE_CFLAGS="-I$FUSE_HDR -D_FILE_OFFSET_BITS=64 -DFUSE_USE_VERSION=26" \
  FUSE_MODULE_LIBS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib -lfuse-t" \
  CFLAGS="-O2 -I$(brew --prefix gettext)/include" LDFLAGS="-L$(brew --prefix gettext)/lib"
make -j"$(sysctl -n hw.ncpu)" LIBS="-lintl"
# The install hook moves libs to /lib (a Linux convention); keep everything inside the prefix.
make install rootbindir="$PREFIX/bin" rootsbindir="$PREFIX/sbin" rootlibdir="$PREFIX/lib"
echo "ntfs-3g installed in $PREFIX"
