#!/bin/bash
# Cleanora verification gate: layering check -> generate -> build -> test.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Layering check"
./scripts/check-layering.sh

echo "==> Generating project"
xcodegen generate

echo "==> Building"
xcodebuild -project Cleanora.xcodeproj -scheme Cleanora -destination 'platform=macOS' build 2>&1 | tail -5

echo "==> Testing"
xcodebuild -project Cleanora.xcodeproj -scheme Cleanora -destination 'platform=macOS' test 2>&1 | tail -25

echo "==> verify: OK"
