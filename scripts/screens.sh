#!/bin/zsh
# Regenerates the screen gallery (docs/screens/*.png) from the UI tests: real windows, native controls.
cd "${0:A:h}/.."
rm -rf docs/screens && SNAPSHOT_DIR=$PWD/docs/screens swift test --filter UITests 2>&1 | grep -E "✘|Test run"
ls docs/screens | wc -l
# The few pictures the README shows are tracked copies (docs/screens itself is not).
mkdir -p docs/readme
for pair in sticker-with-drawers:hero new-trade-list:new-trade form-add:add-transaction list-rows:transactions import-selected:import api-keys-connected:api-keys; do
  cp docs/screens/window-${pair%%:*}.png docs/readme/${pair##*:}.png
done
cp docs/screens/window-about.png docs/readme/about.png
