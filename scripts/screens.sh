#!/bin/zsh
# Regenerates the screen gallery (docs/screens/*.png) from the UI tests: real windows, native controls.
cd "${0:A:h}/.."
rm -rf docs/screens && SNAPSHOT_DIR=$PWD/docs/screens swift test --filter UITests 2>&1 | grep -E "✘|Test run"
ls docs/screens | wc -l
