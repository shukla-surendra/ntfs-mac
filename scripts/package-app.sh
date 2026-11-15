#!/bin/bash
# Assembles dist/NTFS Mac.app (menu-bar app + CLI + bundled ntfs-3g). Ad-hoc signed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -x build/prefix/bin/ntfs-3g ] || { echo "Run scripts/build-driver.sh first"; exit 1; }
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/NTFS Mac.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ntfs-3g"/{bin,sbin,lib}
cp "$BIN/NTFSMacApp" "$BIN/ntfsmac" "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

P=build/prefix; R="$APP/Contents/Resources/ntfs-3g"
cp "$P/bin/ntfs-3g" "$P/bin/ntfsfix" "$R/bin/"
cp "$P/sbin/mkntfs" "$P/sbin/ntfslabel" "$R/sbin/" 2>/dev/null || true
cp -L "$P/lib/libntfs-3g.89.dylib" "$R/lib/"
cp -L "$(brew --prefix gettext)/lib/libintl.8.dylib" "$R/lib/"
chmod u+w "$R"/lib/*.dylib
install_name_tool -id "@loader_path/libintl.8.dylib" "$R/lib/libintl.8.dylib"
install_name_tool -id "@loader_path/libntfs-3g.89.dylib" "$R/lib/libntfs-3g.89.dylib"
install_name_tool -change "$(otool -L "$R/lib/libntfs-3g.89.dylib" | awk '/libintl/{print $1}')" "@loader_path/libintl.8.dylib" "$R/lib/libntfs-3g.89.dylib" 2>/dev/null || true
for b in "$R/bin/ntfs-3g" "$R/bin/ntfsfix"; do
  for dep in $(otool -L "$b" | awk '/libntfs-3g|libintl/{print $1}'); do
    install_name_tool -change "$dep" "@executable_path/../lib/$(basename "$dep")" "$b"
  done
done

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>NTFS Mac</string>
<key>CFBundleIdentifier</key><string>dev.local.ntfsmac</string>
<key>CFBundleExecutable</key><string>NTFSMacApp</string>
<key>CFBundleVersion</key><string>0.1.0</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>

</dict></plist>
PL
# install_name_tool invalidates signatures, and --deep does not re-sign Mach-O files under
# Contents/Resources. An invalid dylib signature makes the kernel SIGKILL ntfs-3g on load.
for f in "$R"/lib/*.dylib "$R"/bin/* "$R"/sbin/*; do codesign --force --sign - "$f"; done
codesign --force --deep --sign - "$APP"
for f in "$R"/lib/*.dylib "$R"/bin/* "$R"/sbin/*; do codesign --verify --strict "$f"; done
"$R/bin/ntfs-3g" --version >/dev/null 2>&1 || { echo "Bundled ntfs-3g fails to run"; exit 1; }
echo "Built: $APP"
