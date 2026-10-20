#!/bin/zsh
# Checks a dist/TradeStick-<version>.zip without running the app (running it would use the installed app's data).
# Usage: scripts/verify-package.sh dist/TradeStick-0.1.2.zip 0.1.2
set -euo pipefail
ZIP=${1:?usage: verify-package.sh <zip> <version>}
V=${2:?usage: verify-package.sh <zip> <version>}
DIR=$(mktemp -d); trap 'rm -rf $DIR' EXIT
ditto -x -k "$ZIP" "$DIR"
APP="$DIR/TradeStick.app"; C="$APP/Contents"
fail() { echo "FAIL: $1"; exit 1 }
ok() { echo "ok:   $1" }
[[ -d $APP ]] || fail "no TradeStick.app in the zip"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$C/Info.plist" }
[[ $(plist CFBundleShortVersionString) == $V ]] && ok "version $V" || fail "version is $(plist CFBundleShortVersionString), expected $V"
[[ $(plist CFBundleIdentifier) == com.caskbrew.tradestick ]] && ok "bundle id" || fail "bundle id"
[[ $(plist LSUIElement) == true ]] && ok "menu-bar app (no Dock icon)" || fail "LSUIElement"
[[ -x $C/MacOS/TradeStick ]] && ok "executable" || fail "executable missing"
ARCHS=$(lipo -archs "$C/MacOS/TradeStick"); [[ $ARCHS == *arm64* && $ARCHS == *x86_64* ]] && ok "universal binary ($ARCHS)" || fail "architectures: $ARCHS"
[[ -f $C/Resources/AppIcon.icns ]] && ok "app icon" || fail "AppIcon.icns missing"
[[ -d $C/Resources/TradeStick_TradeStick.bundle ]] && ok "resource bundle (menu icon)" || fail "TradeStick resource bundle missing"
[[ -d $C/Resources/GRDB_GRDB.bundle ]] && ok "GRDB bundle" || fail "GRDB bundle missing"
codesign --verify --deep --strict "$APP" 2>&1 && ok "code signature valid (ad-hoc)" || fail "code signature"
otool -L "$C/MacOS/TradeStick" | grep -qE "/usr/local|/opt/homebrew|/Users/" && fail "links a library outside the system" || ok "links only system libraries"
echo "package OK"
