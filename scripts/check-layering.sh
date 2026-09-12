#!/bin/bash
# Engine layers (Models, Scanning, Cleaning, Storage, Support) must stay UI-free.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE_DIRS="Sources/Models Sources/Scanning Sources/Cleaning Sources/Storage Sources/Support"
BANNED="import SwiftUI|import AppKit|import Cocoa|import Charts|import ServiceManagement"

violations=0
for dir in $ENGINE_DIRS; do
  if [ ! -d "$dir" ]; then
    # Missing dir is fine only while the layer hasn't landed. If git tracks
    # files under it, the dir was renamed/moved — that must be loud.
    if [ -n "$(git ls-files "$dir")" ]; then
      echo "LAYERING: tracked dir missing on disk: $dir" >&2
      violations=$((violations + 1))
    fi
    continue
  fi
  if grep -rEn "$BANNED" "$dir" 2>/dev/null; then
    echo "LAYERING VIOLATION in $dir" >&2
    violations=$((violations + 1))
  fi
done

if [ "$violations" -gt 0 ]; then
  echo "check-layering: $violations violating dir(s)" >&2
  exit 1
fi
echo "check-layering: OK"
