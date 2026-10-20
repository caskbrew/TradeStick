#!/bin/zsh
# Builds and runs the DEV instance. Touches only processes started from .build/ and the TradeStick-Dev data
# folder; the installed app (/Applications/TradeStick.app) and its data are never stopped or opened.
set -euo pipefail
cd "${0:A:h}/.."
BIN="$PWD/.build/out/Products/Release/TradeStick"
pkill -f "^$BIN" 2>/dev/null || true
swift build -c release 2>&1 | grep -E "error|Build complete" || true
exec nohup "$BIN" >/dev/null 2>&1 &
