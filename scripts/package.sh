#!/bin/zsh
# Builds dist/TradeSticker-<version>.zip (an ad-hoc signed .app) and prints its sha256.
# Usage: scripts/package.sh 0.1.0
set -euo pipefail
cd "${0:A:h}/.."
V=${1:?usage: package.sh <version>}
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
APP=dist/TradeSticker.app
rm -rf dist && mkdir -p $APP/Contents/{MacOS,Resources}
cp $BIN/TradeSticker $APP/Contents/MacOS/
cp -R $BIN/TradeSticker_TradeSticker.bundle $BIN/GRDB_GRDB.bundle $APP/Contents/Resources/ 2>/dev/null || true

ICONSET=dist/AppIcon.iconset; mkdir -p $ICONSET
SRC=Sources/TradeSticker/Resources/AppIcon.png
for s in 16 32 128 256 512; do
  sips -z $s $s $SRC --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $SRC --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns && rm -rf $ICONSET

cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TradeSticker</string>
  <key>CFBundleIdentifier</key><string>com.sgoroshko.tradesticker</string>
  <key>CFBundleExecutable</key><string>TradeSticker</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$V</string>
  <key>CFBundleVersion</key><string>$V</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep --sign - $APP
ditto -c -k --keepParent $APP dist/TradeSticker-$V.zip
echo "dist/TradeSticker-$V.zip"; shasum -a 256 dist/TradeSticker-$V.zip
