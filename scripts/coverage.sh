#!/bin/zsh
# Runs all tests with coverage and prints per-file line coverage (lowest first) for Sources/.
cd "${0:A:h}/.."
swift test --enable-code-coverage 2>&1 | grep -E "✘|Test run"
D=.build/out/Products/Debug
objs=(); for t in Persistence MarketData Domain Presentation; do objs+=(-object $D/${t}Tests.xctest/Contents/MacOS/${t}Tests); done
xcrun llvm-cov report $D/WidgetsTests.xctest/Contents/MacOS/WidgetsTests $objs -instr-profile=$D/codecov/default.profdata \
  -ignore-filename-regex='\.build|Tests' | awk 'NR>2 {print $10, $8, $9, $1}' | sed "s#$PWD/##" | sort -n
