# Cleanora

Transparent native macOS cleaner — Scan → Review → Clean → Verify. SwiftUI app over a UI-free
engine (`Models`/`Scanning`/`Cleaning`/`Storage`/`Support`), Swift 6 strict concurrency, XcodeGen,
XCTest.

## Building

```bash
brew install xcodegen   # once
make verify             # generate + build + test
make run                # build + launch the app
```

## Distribution (Developer ID + notarization)

The app is **deliberately non-sandboxed** (`Config/Cleanora.entitlements` has no sandbox key) —
a sandboxed app can only read its own container, which would make scanning other apps' caches
impossible. App Store distribution is therefore out of scope; ship via Developer ID.

One-time setup:

```bash
security find-identity -v -p codesigning        # confirm a Developer ID Application cert
xcrun notarytool store-credentials <PROFILE>   # store App Store Connect API or Apple ID creds
```

Package (archive → codesign hardened → notarize → staple → Gatekeeper check):

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=<PROFILE> \
./scripts/package.sh
```

Hardened runtime is ON in all configurations (`project.yml`); notarization requires it.

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

Last recorded gate run (2026-09-14): **362 tests, 0 failures, 6.15 s** (`make verify` exit 0 in
10.6 s, `check-layering: OK`). All 362 tests must pass before a phase gate.

### Fixture home (`CLEANORA_FIXTURE_HOME`)

All QA that touches the filesystem runs against a throwaway fixture home — never the real
`$HOME`. `ScanEnvironment.live()` and `ScannerCatalog` re-root the entire engine (scanners,
temp root, Application Support, history, cleanup logs) at the fixture directory when the
environment variable is set (DEBUG builds only).

Build the fixture (writes only under the fixture directory):

```bash
./scripts/build-fixture-home.sh                 # default: /tmp/cleanora-fixture-home
./scripts/build-fixture-home.sh /tmp/other-fx   # custom destination
```

The script lays out the Phase 1 trees plus the Phase 2 developer-tool trees
(Xcode, CoreSimulator, Homebrew, npm, pip, Yarn, Docker) and a home-rooted
`Projects/big-video.bin` (~600 KB — deliberately BELOW the default 500,000,000-byte
large-file threshold, so it must NOT appear under Large Files; large-file
discovery, blocked-root pruning, depth cap, symlink and budget behavior is pinned by
`LargeFileScannerTests` instead, and the threshold is not lowered in app code). To
hand-test the Large Files UI, add a sparse above-threshold file to the fixture (no
real disk cost on APFS):

```bash
dd if=/dev/zero of=/tmp/cleanora-fixture-home/Projects/huge.bin bs=1 count=0 seek=600000000
```

Layout and what each scanner should report:

| Fixture path | Scanner | Expected item |
|---|---|---|
| `.Trash/*` | TrashScanner | one `.destructive` `.removeContents` item |
| `Library/Caches/com.example.app` | ApplicationCacheScanner | `.safe`, trash |
| `Library/Caches/com.apple.Safari` | App/Browser scanners | `.review` (override + whole-directory) |
| `Library/Caches/Google/Chrome/Default/Cache` | BrowserCacheScanner | `.safe` chromium profile cache |
| `Library/Caches/com.docker.docker` | ApplicationCacheScanner | `.review` (Docker override) |
| `Library/Logs/old-app-logs`, old loose files, DiagnosticReports, CrashReporter | LogScanner | `.safe`, only entries > 7 days |
| `Library/Logs/fresh-app.log` | LogScanner | excluded (fresh) |
| `tmp/stale-temp-*` | TempScanner | `.safe`, only entries > 24 h |
| `tmp/fresh-work.tmp` | TempScanner | excluded (fresh) |
| `Library/Developer/Xcode/DerivedData` | XcodeScanner | `.safe`, trash — per-root row |
| `Library/Developer/Xcode/Archives/App 9-12-26.xcarchive` | XcodeScanner | `.review`, trash — per-root row |
| `Library/Developer/Xcode/iOS DeviceSupport/16.4 arm64` | XcodeScanner | `.review`, trash — per-root row |
| `Library/Developer/CoreSimulator/Caches` | XcodeScanner | `.safe`, removeContents — per-root row |
| `Library/Caches/Homebrew/{api,downloads}` | HomebrewScanner | `.safe`, removeContents |
| `.npm/_cacache`, `.npm/_logs` | NpmScanner | two `.safe` items, removeContents |
| `Library/Caches/pip` (+ `.cache/pip` XDG) | PipScanner | `.safe`, removeContents per present root |
| `Library/Caches/Yarn`, `.yarn/berry/cache` | YarnScanner | `.safe`, removeContents per present root |
| `Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` | DockerScanner | measured READ-ONLY; its path is never an item path |
| `Library/Containers/com.docker.docker/Data` (marker) | DockerScanner | one `.review` INFORMATIONAL item that the cleanup gate must reject |
| `Projects/big-video.bin` (600 KB) | LargeFileScanner | excluded — below the 500 MB default threshold |

Expected developer-scan outcomes in fixture mode (Settings → Developer Data ON):

- All four Xcode root rows complete and yield items; Archives and iOS DeviceSupport
  are `.review` (unchecked), DerivedData and CoreSimulator Caches are `.safe`.
- Homebrew, npm, pip, Yarn report `.safe` items for every present root; Docker emits
  the informational review row for `…/com.docker.docker/Data` (Docker.raw exists).
  Absent tools report `.skipped(.toolNotInstalled)` instead of failing the scan.
- Known dedup overlap (expected, not a bug): the Homebrew/pip/Yarn roots live inside
  the `Library/Caches` allowlist, so ApplicationCacheScanner produces items for the
  same paths. The coordinator's dedup collapses identical paths to the FIRST producer
  (phase-one scanners run before developer ones), so those three roots surface once,
  under **Application Caches** with the recoverable trash method; their developer
  twins are dropped. Only paths outside `Library/Caches` (Xcode roots,
  CoreSimulator, `.npm/*`, `.cache/pip`, `.yarn/*`) group under Developer Data.
  Either producer cleans the data; the bytes are not double counted.

Run the app against the fixture — launch the **binary directly** (not `open`) so the
environment variable reaches the process:

```bash
xcodebuild -project Cleanora.xcodeproj -scheme Cleanora -destination 'platform=macOS' \
  -derivedDataPath /tmp/cleanora-dd-qa build

CLEANORA_FIXTURE_HOME=/tmp/cleanora-fixture-home \
  /tmp/cleanora-dd-qa/Build/Products/Debug/Cleanora.app/Contents/MacOS/Cleanora
```

Fixture runs store preferences in the `com.cleanora.fixture` suite (not the real
`com.cleanora` domain). To boot with Developer Data ON, seed that suite with a
Preferences blob (a JSON-encoded `Preferences` struct) before launch:

```bash
cat > /tmp/qa-prefs.json <<'EOF'
{"askBeforeDeleting":true,"automaticallyCleanSafeItems":false,"confirmBeforeCleaning":true,
 "enabledCategories":["applicationCaches","browserCaches","temporaryFiles","logs","trash",
 "developerData","largeFiles"],
 "includeDeveloperData":true,"keepCleanupHistory":true,"launchAtLogin":false,
 "showCleanupReminder":false}
EOF
defaults delete com.cleanora.fixture 2>/dev/null
defaults write com.cleanora.fixture "com.cleanora.preferences.v1" \
  -data "$(xxd -p -c 100000 /tmp/qa-prefs.json | tr -d '\n')"
```

A recorded fixture-mode run (2026-09-14): app boots, stays alive 10 s at ~0 % CPU,
`SIGTERM` exits cleanly (code 143), nothing written outside the fixture home, no
crash reports, and the seeded fixture prefs decode with
`includeDeveloperData = true`.

Safety notes on fixture mode:

- File-based state (history, last scan, write-ahead cleanup logs) is written under
  `FIXTURE_HOME/Library/Application Support/Cleanora`, not the real home.
- `ScanEnvironment.live()` fatal-errors if the fixture path does not exist or is a bare
  root (`/`), so the seam cannot silently re-aim the allowlist at real system paths.
- Preferences are fixture-scoped too: with `CLEANORA_FIXTURE_HOME` set, `AppEnvironment`
  routes `PreferencesStore` at the `com.cleanora.fixture` defaults suite
  (`~/Library/Preferences/com.cleanora.fixture.plist`), so the real `com.cleanora`
  domain is never written. Verified: a fixture-mode run leaves no `com.cleanora.plist`.

### Automated coverage map (Phase 2)

Exact test cases covering each Phase 2 behavior:

| Behavior | Test cases |
|---|---|
| Xcode per-root rows + risks (`DerivedData`/CoreSimulator safe, Archives/DeviceSupport review) | `XcodeScannerTests.testProducesOneItemPerPresentXcodeRoot`, `testRowKeysExposeExactlyTheFourRoots`, `testCompletedRowsCarryPerRowTotals`, `testEmptyRootsProduceNoItems` |
| Tool-absent skips (`.toolNotInstalled`) | `ToolCacheScannerTests.testHomebrewAbsentIsSkippedAsToolNotInstalled`, `testNpmAbsentIsSkippedAsToolNotInstalled`, `testPipAbsentIsSkippedAsToolNotInstalled`, `testYarnAbsentIsSkippedAsToolNotInstalled`; `DeveloperScannerTests.testAllToolsAbsentProducesEmptyOutcomeWithPerRowSkips`; `XcodeScannerTests.testAbsentRootsAreSkippedPerRowWithoutFailingTheScanner`, `testMixedPresenceSkipsOnlyAbsentRows`; `DockerScannerTests.testNeitherRawDiskNorCLIMeansToolNotInstalled` |
| Docker gate rejection pin (marker never deletable, Docker.raw never a path) | `DockerScannerTests.testInformationalItemIsRejectedByTheSafetyGate`, `testRawDiskPathIsNeverAnItemPath`, `testNonAllowlistedDockerPathsNeverBecomeItems`; `DeveloperCleanupViewModelTests.testContainersMarkerRowIsNotSelectable`, `testGroupSelectionSkipsInformationalRows` |
| Large files (blocked pruning / budget / symlink / depth / sort) | `LargeFileScannerTests.testBlockedRootsAndFragmentsAreExcluded`, `testExhaustedBudgetWithoutFindingsYieldsTooLargeToScan`, `testFindingsBeforeBudgetExhaustionSurvive`, `testSymlinksAreNeverFollowedOrCounted`, `testDepthBeyondFourIsNotScanned`, `testFindsLargeFilesSortedDescending`, `testLimitKeepsOnlyTheLargestFiles`, `testThresholdAboveEveryFileSizeProducesNothing`; gate carve-out: `SafetyPolicyTests.testLargeFileUnderArbitraryHomePathAllowedWithCarveOut`, `testLargeFileCarveOutStillRespectsBlockedPaths`, `testLargeFileCarveOutRequiresMoveToTrash`, `testNonLargeFileOutsideAllowlistStillRejected` |
| History migration v0→current + trim 150→100 | `ScanHistoryStoreTests.testMigrateHookUpgradesV0EntryToCurrentVersion`, `testMigrateHookLeavesCurrentVersionEntryUnchanged`, `testMigrateHookDropsFutureVersionEntry`, `testPersistedV0EntryReadMigratedAndConvergesOnNextAppend`, `testAppending150EntriesTrimsToMaxHistoryEntriesKeepingNewest`, `testHistoryTrimmedToOneHundredNewestKept`, `testHistoryLimitParameter` |
| Clear history | `ScanHistoryStoreTests.testClearHistoryRemovesAllEntriesButKeepsLastScan`, `testClearHistoryEmptiesDayGrouping`, `testClearHistoryThenAppendStartsFresh`, `testClearHistoryWithoutHistoryFileIsHarmless`; `HistoryViewModelTests.testClearHistoryDeletesAndRefreshesWhenCapabilityInjected`, `testClearIsHiddenAndNoOpWhenStoreLacksTheCapability`, `testClearHistoryRoutesToStoreAndKeepsLastScan` |
| Auto-clean fallback paths (trash selected → loud fallback) | `CleaningFlowPolicyTests.testAutoCleanWithTrashPresentFallsBackLoudly`, `testAutoCleanWithNothingPreselectedFallsBackLoudly`, `testAutoCleanFallbackReasonsAreNonEmpty`; `AppEnvironmentFlowTests.testScanDidFinishFallsBackLoudlyWhenTrashIsSelected`, `testScanDidFinishFallsBackWhenNothingWasPreselected` |
| Destructive always confirms | `CleaningFlowPolicyTests.testDestructiveSelectionAlwaysConfirmsEvenWithBothTogglesOff`, `testDestructiveConfirmationLevelFlagAlsoCounts`; `SafetyPolicyTests.testDestructiveRequiresExplicitConfirm`, `testTrashCategoryWithoutDestructiveMarkingRejected` |
| Reconciliation after a cancelled run | `AppEnvironmentFlowTests.testCancelledCleanupMarksResultsForReconciliationOnce`; `ResultsViewModelTests.testReconciliationDropsMissingFilesAndCountsThem`, `testReconcilingInitDropsGoneFilesAndReportsTheCount`, `testReconciliationWithEverythingPresentIsIdentity`, `testCancelledRunBannerCopy`; `CleanupExecutorTests.testCancellationBetweenItemsLeavesRemainderUntouched` |
| Launch-at-login error surface | `AppEnvironmentFlowTests.testLaunchAtLoginSuccessPersistsPreferenceAndStatus`, `testLaunchAtLoginFailureKeepsPreferenceAndSurfacesError`, `testDisableAtLoginUnregistersOnSuccess`; `SettingsViewModelTests.testLaunchAtLoginStatusDescribesSuccess`, `testLaunchAtLoginStatusSurfacesTheServiceManagementError` |
| Settings wiring (developer gate → engine) | `AppEnvironmentFlowTests.testResolvedOptionsMirrorDeveloperGateIntoCategories`, `testResolvedOptionsAlwaysScanLargeFiles`, `testResolvedOptionsLeavePhaseOneCategoriesUntouched`, `testScanViewModelExpandsDeveloperFanOutProgressRows`, `testScanViewModelCollapsesFanOutRowsWhenDeveloperModeOff`; `ScannerCatalog` gating pinned in `DeveloperScannerTests.testFullScannersExtendsPhaseOneWithDeveloperAndLargeFiles`, `testCoordinatorRunSurfacesDeveloperItems` |

Flows with **no** automated coverage (verified by hand — see the checklist below): the
end-to-end UI round trip (dashboard → scan progress rows → results grouping → confirm
sheet → completion), trash-first visual ordering in the confirm sheet, the disk chart's
rendered segments against a real scan, launch-at-login against real ServiceManagement
(only the seam outcomes are unit-tested), FDA-denied banner (needs a real TCC denial),
and the fixture-mode app boot itself.

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

### Manual QA checklist additions (Phase 2 gate — fixture home, developer prefs seeded)

11. **Developer scan on/off** — Settings: Developer Data OFF → the progress screen shows
    exactly one explained `Developer Data` skipped row (no per-tool rows); ON → the row
    list fans out to Developer Data + 4 Xcode root rows + Homebrew, npm, pip, Yarn,
    Docker (16 progress rows with phase one), and every row reaches completed or an
    explained skip.
12. **Developer results grouping** — Developer Data groups by tool family; Xcode
    Archives and iOS DeviceSupport rows are `.review` (unchecked by default);
    DerivedData, CoreSimulator Caches and the package-manager caches are preselected;
    Homebrew/pip/Yarn roots appear under Application Caches (dedup overlap — expected,
    see the fixture table above), while Xcode/CoreSimulator/`.npm`/`.yarn`/`.cache`
    paths appear under Developer Data.
13. **Docker row behavior** — the informational `Docker build cache` review row (sized
    from Docker.raw, 4 MiB in the fixture) is NOT selectable; selecting the rest of its
    group must not select it; cleaning a developer selection never touches
    `…/com.docker.docker/Data`.
14. **Large-file selection + confirm** — add the sparse >threshold file (command in the
    fixture section), rescan: the file appears under Large Files, unchecked, as a plain
    file row (no app grouping); selecting it demands the normal confirm; cleaning moves
    it to the fixture `.Trash` (recoverable). `Projects/big-video.bin` (600 KB) must
    NOT be listed.
15. **Clear history** — with at least one history entry, Clear History empties the
    history screen, keeps the dashboard's last-scan line, and a following clean starts
    a fresh history file
    (`FIXTURE_HOME/Library/Application Support/Cleanora/history.json`).
16. **Launch-at-login (dev builds)** — toggling Launch at Login shows a status line on
    the row; in dev/ad-hoc builds where ServiceManagement registration fails, the
    failure copy appears instead and the toggle keeps its persisted value — never a
    silent dead toggle.
