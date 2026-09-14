#!/bin/bash
# Build the CLEANORA_FIXTURE_HOME QA fixture (Phase 1 + Phase 2 developer trees).
#
#   ./scripts/build-fixture-home.sh [DEST]
#
# Default DEST is /tmp/cleanora-fixture-home. The result is a throwaway home
# for fixture-mode runs (DEBUG builds only):
#
#   CLEANORA_FIXTURE_HOME=$FX /path/to/Cleanora.app/Contents/MacOS/Cleanora
#
# Nothing outside DEST is written. Staleness stamps go on AFTER content is
# created so directory mtimes stay old (Log/Temp scanner gates).
#
# NOTE on the large file: Projects/big-video.bin is ~600 KB on purpose — it is
# BELOW the default 500,000,000-byte large-file threshold, so it must NOT
# appear under Large Files. Large-file discovery/pruning/budget logic is
# covered by LargeFileScannerTests; to hand-test the Large Files UI, add a
# sparse >threshold file (no real disk cost on APFS), e.g.:
#   dd if=/dev/zero of="$FX/Projects/huge.bin" bs=1 count=0 seek=600000000
set -euo pipefail

FX="${1:-/tmp/cleanora-fixture-home}"

rm -rf "$FX"
mkdir -p \
  "$FX/Library/Caches/com.apple.Safari/WebsiteCaches" \
  "$FX/Library/Caches/Google/Chrome/Default/Cache" \
  "$FX/Library/Caches/com.example.app" \
  "$FX/Library/Caches/com.docker.docker" \
  "$FX/Library/Logs/old-app-logs" \
  "$FX/Library/Logs/DiagnosticReports" \
  "$FX/Library/Application Support/CrashReporter" \
  "$FX/Library/Developer/Xcode/DerivedData/App.build/Index" \
  "$FX/Library/Developer/Xcode/Archives/App 9-12-26.xcarchive/Products" \
  "$FX/Library/Developer/Xcode/iOS DeviceSupport/16.4 arm64" \
  "$FX/Library/Developer/CoreSimulator/Caches/simcache" \
  "$FX/Library/Caches/Homebrew/api" \
  "$FX/Library/Caches/Homebrew/downloads" \
  "$FX/Library/Caches/pip/http-v2/aa" \
  "$FX/.cache/pip" \
  "$FX/Library/Caches/Yarn/npm" \
  "$FX/.npm/_cacache/content-v2/sha512" \
  "$FX/.npm/_logs" \
  "$FX/.yarn/berry/cache" \
  "$FX/Library/Containers/com.docker.docker/Data/vms/0/data" \
  "$FX/Projects" \
  "$FX/.Trash" \
  "$FX/tmp/stale-temp-dir" \
  "$FX/tmp/shared"

# --- Phase 1: caches, logs, trash, temp -----------------------------------
echo payload > "$FX/Library/Caches/com.apple.Safari/WebsiteCaches/pagecache.dat"
head -c 4096 /dev/zero > "$FX/Library/Caches/Google/Chrome/Default/Cache/data_1"
head -c 2048 /dev/zero > "$FX/Library/Caches/com.example.app/thumbs.cache"
head -c 1024 /dev/zero > "$FX/Library/Caches/com.docker.docker/build-cache.bin"
echo old > "$FX/Library/Logs/old-app-logs/session.log"
echo old > "$FX/Library/Logs/DiagnosticReports/Cleanora-2026-09-01.crash"
echo old > "$FX/Library/Application Support/CrashReporter/oldreport.ips"
echo trashed > "$FX/.Trash/discarded-file.txt"
head -c 8192 /dev/zero > "$FX/tmp/stale-temp-dir/scratch.bin"
echo stale > "$FX/tmp/stale-temp-file.tmp"
echo fresh > "$FX/tmp/fresh-work.tmp"
echo fresh > "$FX/Library/Logs/fresh-app.log"

# --- Phase 2: developer tools ---------------------------------------------
head -c 16384 /dev/zero > "$FX/Library/Developer/Xcode/DerivedData/App.build/Index/store.o"
head -c 8192 /dev/zero > "$FX/Library/Developer/Xcode/Archives/App 9-12-26.xcarchive/Products/App.app.dSYM"
head -c 4096 /dev/zero > "$FX/Library/Developer/Xcode/iOS DeviceSupport/16.4 arm64/symbols"
head -c 4096 /dev/zero > "$FX/Library/Developer/CoreSimulator/Caches/simcache/runtime-cache"
head -c 2048 /dev/zero > "$FX/Library/Caches/Homebrew/api/formula.jws.json"
head -c 16384 /dev/zero > "$FX/Library/Caches/Homebrew/downloads/foo--1.2.3.bottle.tar.gz"
head -c 4096 /dev/zero > "$FX/Library/Caches/pip/http-v2/aa/bb.wheel"
echo ok > "$FX/.cache/pip/selfcheck"
head -c 4096 /dev/zero > "$FX/Library/Caches/Yarn/npm/lodash-4.17.21.tgz"
head -c 4096 /dev/zero > "$FX/.npm/_cacache/content-v2/sha512/aa"
echo stale > "$FX/.npm/_logs/2026-09-01T09-00-00-debug-0.log"
head -c 4096 /dev/zero > "$FX/.yarn/berry/cache/lodash-npm-4.17.21.zip"

# Docker: Docker.raw is measured read-only and is NEVER an item path; the
# informational review row points at the container's Data directory (gate-
# rejected by SafetyPolicy by construction — prune is out of scope for the
# engine). Docker.raw is sparse: 4 MiB logical, ~0 disk cost.
dd if=/dev/zero of="$FX/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" \
  bs=1 count=0 seek=4194304 2>/dev/null

# Home-rooted large file: 600 KB — deliberately BELOW the default
# 500,000,000-byte threshold (see header note).
head -c 614400 /dev/zero > "$FX/Projects/big-video.bin"

# --- Staleness stamps ------------------------------------------------------
# > 7 days  → log candidates
touch -t 202609010900 \
  "$FX/Library/Logs/old-app-logs" "$FX/Library/Logs/old-app-logs/session.log" \
  "$FX/Library/Logs/DiagnosticReports/Cleanora-2026-09-01.crash" \
  "$FX/Library/Application Support/CrashReporter/oldreport.ips" \
  "$FX/.npm/_logs/2026-09-01T09-00-00-debug-0.log"
# > 24 hours → temp candidates
touch -t 202609100900 \
  "$FX/tmp/stale-temp-dir" "$FX/tmp/stale-temp-dir/scratch.bin" \
  "$FX/tmp/stale-temp-file.tmp"

echo "fixture home ready: $FX ($(du -sh "$FX" | cut -f1) on disk)"
