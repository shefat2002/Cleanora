#!/bin/bash
# Regenerate the Xcode project under a lock — parallel agents add files and
# xcodegen writes the same .xcodeproj; last-writer-wins races break builds.
set -euo pipefail
cd "$(dirname "$0")/.."

LOCK="/tmp/cleanora-xcodegen.lock"
while ! mkdir "$LOCK" 2>/dev/null; do
  sleep 0.3
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

xcodegen generate
echo "project regenerated"
