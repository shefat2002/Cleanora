# Cleanora

Transparent native macOS cleaner — Scan → Review → Clean → Verify. SwiftUI app over a UI-free
engine (`Models`/`Scanning`/`Cleaning`/`Storage`/`Support`), Swift 6 strict concurrency, XcodeGen,
XCTest.

## QA

### Environment

| Component | Version |
|---|---|
| macOS | 26.6.2 (Build 25G83) |
| Xcode | 26.6 (17F113) |
| xcodegen | required by `make project` |
| Deployment target | macOS 14.0 |

### Automated gate

```bash
make verify        # layering check → xcodegen generate → build → full test suite
./scripts/check-layering.sh   # engine layers must stay UI-free; must exit 0
```

Last recorded gate run: **231 tests, 0 failures, 4.84 s** (`make verify` exit 0 in 10.4 s,
`check-layering: OK`). All 231 tests must pass before a phase gate.

### Fixture home (`CLEANORA_FIXTURE_HOME`)

All QA that touches the filesystem runs against a throwaway fixture home — never the real
`$HOME`. `ScanEnvironment.live()` and `ScannerCatalog` re-root the entire engine (scanners,
temp root, Application Support, history, cleanup logs) at the fixture directory when the
environment variable is set (DEBUG builds only).

Build the fixture:

```bash
FX=/tmp/cleanora-fixture-home
rm -rf "$FX"
mkdir -p "$FX/Library/Caches/com.apple.Safari/WebsiteCaches" \
         "$FX/Library/Caches/com.google.Chrome/Default/Cache" \
         "$FX/Library/Caches/com.example.app" \
         "$FX/Library/Logs/old-app-logs" \
         "$FX/Library/Logs/DiagnosticReports" \
         "$FX/Library/Application Support/CrashReporter" \
         "$FX/.Trash" "$FX/tmp/stale-temp-dir"

echo payload > "$FX/Library/Caches/com.apple.Safari/WebsiteCaches/pagecache.dat"
head -c 4096 /dev/zero > "$FX/Library/Caches/com.google.Chrome/Default/Cache/data_1"
head -c 2048 /dev/zero > "$FX/Library/Caches/com.example.app/thumbs.cache"
echo old > "$FX/Library/Logs/old-app-logs/session.log"
echo old > "$FX/Library/Logs/DiagnosticReports/Cleanora-2026-09-01.crash"
echo old > "$FX/Library/Application Support/CrashReporter/oldreport.ips"
echo trashed > "$FX/.Trash/discarded-file.txt"
head -c 8192 /dev/zero > "$FX/tmp/stale-temp-dir/scratch.bin"
echo stale > "$FX/tmp/stale-temp-file.tmp"
echo fresh > "$FX/tmp/fresh-work.tmp"
echo fresh > "$FX/Library/Logs/fresh-app.log"

# Staleness stamps go on AFTER content is created, so directory mtimes stay old.
touch -t 202609010900 "$FX/Library/Logs/old-app-logs" "$FX/Library/Logs/old-app-logs/session.log" \
  "$FX/Library/Logs/DiagnosticReports/Cleanora-2026-09-01.crash" \
  "$FX/Library/Application Support/CrashReporter/oldreport.ips"        # > 7 days → log candidates
touch -t 202609100900 "$FX/tmp/stale-temp-dir" "$FX/tmp/stale-temp-dir/scratch.bin" \
  "$FX/tmp/stale-temp-file.tmp"                                        # > 24 h → temp candidates
```

Layout and what each scanner should report:

| Fixture path | Scanner | Expected item |
|---|---|---|
| `.Trash/*` | TrashScanner | one `.destructive` `.removeContents` item |
| `Library/Caches/com.example.app` | ApplicationCacheScanner | `.safe`, trash |
| `Library/Caches/com.apple.Safari` | App/Browser scanners | `.review` (override + whole-directory) |
| `Library/Caches/Google/Chrome/Default/Cache` | BrowserCacheScanner | `.safe` chromium profile cache |
| `Library/Logs/old-app-logs`, old loose files, DiagnosticReports, CrashReporter | LogScanner | `.safe`, only entries > 7 days |
| `Library/Logs/fresh-app.log` | LogScanner | excluded (fresh) |
| `tmp/stale-temp-*` | TempScanner | `.safe`, only entries > 24 h |
| `tmp/fresh-work.tmp` | TempScanner | excluded (fresh) |

Run the app against the fixture — launch the **binary directly** (not `open`) so the
environment variable reaches the process:

```bash
xcodebuild -project Cleanora.xcodeproj -scheme Cleanora -destination 'platform=macOS' \
  -derivedDataPath /tmp/cleanora-dd-qa build

CLEANORA_FIXTURE_HOME=/tmp/cleanora-fixture-home \
  /tmp/cleanora-dd-qa/Build/Products/Debug/Cleanora.app/Contents/MacOS/Cleanora
```

Safety notes on fixture mode:

- File-based state (history, last scan, write-ahead cleanup logs) is written under
  `FIXTURE_HOME/Library/Application Support/Cleanora`, not the real home.
- `ScanEnvironment.live()` fatal-errors if the fixture path does not exist or is a bare
  root (`/`), so the seam cannot silently re-aim the allowlist at real system paths.
- Caveat: preferences persist through `UserDefaults.standard`, so fixture runs still write
  the app's own `com.cleanora` preference domain (`~/Library/Preferences`). Harmless — it is
  the app's own settings — but it is not fixture-local.

### Manual QA checklist (Phase 1 gate — UI flows, run against the fixture home)

Automated suites cover the engine and view-model logic; the following end-to-end flows have
**no** automated coverage and must be verified by hand in the fixture-mode app:

1. **Dashboard (§4)** — health headline, "X GB safe to clean" counts safe items only,
   exactly one primary `Scan Mac` button, last-scan line, category rows (empty categories hidden).
2. **Scan → progress (§5)** — per-scanner rows move pending → running → completed/skipped,
   live byte counts, Cancel stops the run and exits cleanly.
3. **Scan → results totals (§6)** — header total equals the sum of category rows; expanding
   Application Caches groups by app name with an Other rollup; review items (Safari) are
   unchecked; tri-state category checkboxes update totals instantly.
4. **Confirm → clean (§8)** — Clean Now opens the confirmation sheet listing every selected
   item with sizes; selecting Trash shows the irreversible-destruction warning and requires
   the explicit destructive confirm; sheet is non-dismissable while cleaning runs.
5. **Completion (§9)** — measured GB freed (not estimated), item count, per-category totals,
   Done returns to a refreshed dashboard.
6. **History write-back (§10)** — after a real clean, the history screen shows a new
   day-grouped entry whose totals match the completion screen; relaunching keeps it
   (`FIXTURE_HOME/Library/Application Support/Cleanora/history.json`).
7. **Trash destructive warning** — with `.Trash` selected, the destructive warning appears
   and cleaning empties the fixture `.Trash` contents while `.Trash` itself survives.
8. **Cancel mid-scan / mid-clean** — cancelling during a scan or a multi-item clean leaves
   unprocessed items untouched and the app responsive for a fresh run.
9. **FDA-denied banner** — deny Full Disk Access to Cleanora in System Settings, relaunch:
   the permission banner appears and the deep-link button opens the Privacy pane
   (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`). Fixture
   homes suppress the banner by design (missing canaries are not denials), so this check
   needs a real TCC denial.
10. **Settings persistence (§11)** — toggle a scanner off and a cleaning option, relaunch,
    confirm the toggles stuck; the last enabled category cannot be switched off.
