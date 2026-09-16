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

Last recorded gate run (2026-09-14, Phase 3): **508 tests, 0 failures, 6.7 s** (`make verify`
exit 0 in 11.5 s, `check-layering: OK`). All 508 tests must pass before a phase gate.

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
`LargeFileScannerTests` instead, and the threshold is not lowered in app code). Phase 3
adds two extras:

- `DuplicateScope/` — two byte-identical 1.2 MB files (one duplicate group; the
  newest, `Project B/report-copy.dat`, is the keeper) plus `unique.dat`, same size
  with different content, which must never group. Duplicate scanning is strictly
  opt-in — the user picks the scope in the Duplicates screen — so **no automatic scan
  ever reads this tree**; automated duplicate coverage uses its own temp fixtures
  (`DuplicateScannerTests`), and these files exist only so the hand run can point the
  scope at `$FX/DuplicateScope`.
- `Applications/Fixture Editor.app` (bundle ID `com.fixture.editor`) with every
  planner-visible related location: the bundle itself, `Library/Caches/com.fixture.editor`,
  `Library/Application Support/Fixture Editor`,
  `Library/Saved Application State/com.fixture.editor.savedState` — all of which
  validate at cleanup — plus `Library/Preferences/com.fixture.editor.plist` and
  `Library/Containers/com.fixture.editor`, which are planned but **gate-REFUSED**
  (Preferences is a blocked root, Containers a permanent exclusion). Both refusals
  must render in the cleanup results; see manual item 20.

To hand-test the Large Files UI, add a sparse above-threshold file to the fixture (no
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
| `Library/Caches/com.fixture.editor` | ApplicationCacheScanner | `.safe`, trash — Phase 3 fixture-app cache (also planned by the uninstaller as an `.appLeftovers` row) |
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
| `DuplicateScope/*` | (none — duplicates are opt-in) | never scanned automatically; Duplicates screen scope for the hand run (item 19) |
| `Applications/Fixture Editor.app` + related files | UninstallPlanner (Uninstaller screen) | one plan: bundle + cache + App Support + saved state cleanable; Preferences plist + Containers listed but gate-refused (item 20) |

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
 "menuBarEnabled":false,"showCleanupReminder":false,
 "scheduleEnabled":false,"scheduleIntervalDays":7,"scheduleAutoCleanSafeOnly":true,
 "lastScheduledRun":null}
EOF
defaults delete com.cleanora.fixture 2>/dev/null
defaults write com.cleanora.fixture "com.cleanora.preferences.v1" \
  -data "$(xxd -p -c 100000 /tmp/qa-prefs.json | tr -d '\n')"
```

Date-encoding gotcha for `lastScheduledRun`: the store uses `JSONEncoder`'s default
date strategy, i.e. **seconds since 2001-01-01** (`deferredToDate`), not a Unix epoch
and not ISO-8601. To hand-test a catch-up fire, seed
`time.time() - 978307200 - 8*86400` (8 days before now in reference-date seconds; a
7-day interval makes the slot ~1 day overdue and the loop fires one catch-up at
launch). A blob carrying an epoch number or an ISO string fails to decode — which is
itself safe: the app drops the corrupt suite and boots on defaults (verified — the
domain disappears and no scheduler runs).

Recorded fixture-mode runs (2026-09-14):

- **Idle boot** (Phase 3 blob, schedule + menu bar off): app boots, stays alive 10 s
  at 0.0 % CPU, `SIGTERM` exits cleanly (code 143), nothing written outside the
  fixture home (no `com.cleanora.plist`, no real Application Support, 0 crash
  reports), and the seeded fixture prefs decode with `includeDeveloperData = true`.
- **Scheduled-cleanup smoke** (menu bar ON, schedule ON, `lastScheduledRun` 8 days
  overdue): at launch the loop starts, one catch-up fires immediately, and the
  safe-only clean removes 17 items / 102,400 bytes from the fixture in 0.024 s —
  `history.json`, `lastscan.json` and a cleanup WAL land under
  `FIXTURE_HOME/Library/Application Support/Cleanora`; the re-persisted blob carries
  `lastScheduledRun` stamped to the fire second. Trash, the Safari/Docker `.review`
  rows, the fixture app's Preferences plist and Containers folder and the `.review`
  large file survive; real home untouched; `SIGTERM` exits 143 with no crash reports.

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

### Automated coverage map (Phase 3)

Exact test cases covering each Phase 3 behavior:

| Behavior | Test cases |
|---|---|
| Scheduler: interval fire + reschedule, stored options, slot stamping | `CleanupSchedulerTests.testFiresAfterIntervalThenReschedulesNextInterval` (fires exactly once per interval, rescans with `Preferences().enabledCategories`, persists `lastScheduledRun`, records the scan as finished, re-arms a fresh interval) |
| Scheduler: disabled schedule is a no-op | `CleanupSchedulerTests.testStartWithScheduleDisabledIsANoOp` (disabling mid-run is honored by the loop's per-iteration gate but has no dedicated test) |
| Scheduler: exactly ONE catch-up per start; not-yet-due resumes the original cadence | `CleanupSchedulerTests.testOverdueScheduleRunsExactlyOneCatchUpFireOnStart`, `testNotYetDueScheduleResumesOriginalCadenceWithoutCatchUp`, `testLastScheduledRunPersistsAndResumesWithoutCatchUp` |
| Scheduler: safe-only clean selection (review/destructive/deselected never cleaned) | `CleanupSchedulerTests.testCleanClosureReceivesOnlyPreselectedSafeNonDestructiveIDs`, `testScheduledCleanSelectionComputesSafeNonDestructiveSet`, `testMarkingSelectionLeavesOnlyChosenItemsSelected`, `testNotifyOnlyModeScansAndRecordsButNeverCleans`, `testNothingSafeToCleanSkipsTheClean`, `testScanFailureSkipsCleanButLoopStaysAlive` |
| Scheduler: loop hygiene (double start, stop/cancel, no real waits) | `CleanupSchedulerTests.testDoubleStartDoesNotSpawnSecondLoop`, `testStopCancelsTheLoopAndPreventsFurtherFires` (gated sleeper + fixed clock — no test ever waits an interval) |
| Schedule interval clamping (store + end-to-end) | `PreferencesStoreTests.testScheduleDefaultsMatchSpec`, `testScheduleIntervalDaysClampedToOneThroughThirty`, `testScheduleIntervalIsClampedDaysInSeconds`, `testScheduleFieldsRoundTripThroughPersistence`, `testLegacyBlobWithoutScheduleFieldsDecodesWithScheduleDefaults`, `testLegacyBlobConvergesToCurrentShapeOnNextPersist`; `CleanupSchedulerTests.testIntervalDaysBelowRangeIsClampedToOneDay`, `testIntervalDaysAboveRangeIsClampedToThirtyDays` |
| Settings screen logic for the schedule | `SchedulerSettingsViewModelTests` (12 tests): picker covers 1–30, out-of-reach picks keep the stored value, singular/plural labels, Run-now title/state, safe-only copy, last-run/next-run lines, overdue never promises a past time |
| Menu bar panel content (M-01) | `MenuBarPanelViewModelTests` (10 tests): junk estimate sums all items / zero before a scan, junk + free-space + last-clean + last-scan lines, refresh loads all providers |
| Recommendations: rule thresholds (strict `>`), totals before threshold, reason text never read | `RecommendationEngineTests`: `testEmptyResultProducesNoRecommendations`, `testQuietResultProducesNoRecommendations`, `testArchivesAboveThresholdRecommended`, `testArchivesAtExactlyThresholdNotRecommended`, `testArchivesTotalledAcrossItemsBeforeThresholdCheck`, `testDerivedDataNeverCountsAsArchives`, `testDeviceSupportAboveThresholdRecommended`, `testDeviceSupportBelowThresholdNotRecommended`, `testHomebrewCacheAboveThresholdRecommended`, `testHomebrewCacheBelowThresholdNotRecommended`, `testDockerTotalledPerAppNameGroupAboveThreshold`, `testDockerBelowThresholdNotRecommended`, `testReasonTextNeverDrivesRules`, `testTrashAboveThresholdRecommended`, `testLogsAboveThresholdRecommended` (thresholds: archives > 500 MB, device support > 1 GB, Homebrew > 2 GB, Docker > 10 GB, Trash > 5 GB, logs > 1 GB) |
| Recommendations: cap + ordering | `RecommendationEngineTests.testCappedAtFourSortedByEstimatedBytes`, `testEqualEstimatesBreakTiesByTitle`; `RecommendationTests.testIdentityIsStableWithinInstance`, `testCodableRoundTripPreservesAllFields`; `SuggestionsViewModelTests` (7 tests): rows without estimates dropped, sorted descending, duplicates collapse by category+title, display limit, accessibility label |
| Duplicates: grouping, keeper-first (newest wins, tie by path) | `DuplicateScannerTests.testIdenticalFilesGroupWithNewestAsKeeper`, `testEqualModificationTimesBreakKeeperTieByPath`, `testMultipleGroupsReportedLargestWasteFirst`, `testSameSizeDifferentContentIsNotGrouped`, `testSameHeadDifferentTailIsNotGrouped`, `testDifferentSizesWithIdenticalContentAreNotGrouped` |
| Duplicates: size gate | `DuplicateScannerTests.testSizeGateExcludesFilesBelowMinimum` (1 MB engine floor; the VM pins it via `DuplicatesViewModel.scanOptions`) |
| Duplicates: blocked pruning, symlinks, caps, budget | `DuplicateScannerTests.testBlockedSubtreesInsideScopeArePruned`, `testSymlinkedDuplicateIsSkippedNotFollowed`, `testFileLimitCapsCandidatesDeterministically`, `testExpiredTimeBudgetReturnsEmptyResultWithoutThrowing` |
| Duplicates: cancellation + progress | `DuplicateScannerTests.testCancellationBeforeStartThrows`, `testMidScanCancellationThrowsAndAbortsHashing`, `testProgressCountsExaminedFilesAndFoundGroups`; `DuplicatesViewModelTests.testProgressAccumulatesMonotonically`, `testProgressLineReflectsGroupsFound` |
| Duplicates: review UX (keeper not selectable, all unchecked, trash reason) | `DuplicatesViewModelTests.testKeeperIsTheEngineSuggestedFirstFile`, `testBuildCardsLeavesEverythingUnselected`, `testBuildCardsOrdersByWastedBytesAndSkipsDegenerateGroups`, `testTriStateIgnoresKeeperRow`, `testSelectionAggregatesAcrossCards`, `testCleanupItemsCarryReviewTrashAndDuplicateReason`; scope editing `testAddScopeStandardizesAndAppends`, `testNestedScopeIsIgnored`, `testRemoveScope`, `testCanScanRequiresScope`; failure/cancel `testFailedSearchSurfacesTheError`, `testCancellationLeavesNothingBehind` |
| Duplicates: post-clean reconciliation + refusals | `DuplicatesViewModelTests.testReconciliationDropsRemovedFilesAndKeepsGroup`, `testReconciliationPrunesGroupsBelowTwoFiles`, `testReconciliationCollectsRefusals`, `testReconciliationLine` |
| Uninstaller: inventory | `AppInventoryScannerTests` (7 tests): user + system roots via override, case-insensitive sort across roots, dedup of overlapping roots, non-bundles and symlinked bundles ignored, InfoPlist-less bundle still listed, missing roots yield empty; `UninstallerViewModelTests.testLoadInventorySortsCaseInsensitively`, `testInventoryErrorSurfacesAndEmptyStateApplies`, `testFilterMatchesNameOrBundleIDCaseInsensitively` |
| Uninstaller: planner (bundle + every related location, missing skipped, bundleless fallback) | `UninstallPlannerTests.testPlanIncludesBundleAndEveryRelatedLocation`, `testPlanSkipsMissingRelatedFiles`, `testApplicationSupportMatchesNameOrBundleID`, `testSavedApplicationStateAndHTTPStoragesMatchByBundlePrefix`, `testBundlelessAppPlansOnlyBundleAndNameMatchedSupport`, `testPlannedSizesReflectFixtureContents` |
| Uninstaller: running-app gate | `UninstallerViewModelTests.testRunningAppDisablesUninstallWithReason`, `testStoppedAppAllowsUninstallOnceSomethingIsSelected`; planner rows forced unchecked at the UI boundary `testPlannerRowsAreForcedUncheckedAtTheUIBoundary`; `testVersionLineIsNilWithoutVersion`, `testSelectionProvidingBasics` |
| Uninstaller: safety-gate carve-out pins | `SafetyPolicyTests.testAppLeftoversBundleUnderApplicationsAllowed`, `testAppLeftoversUnderHomeAllowed`, `testAppLeftoversPreferencesPlistStillBlocked`, `testAppLeftoversContainersStillBlocked`, `testAppLeftoversCarveOutRequiresReviewRisk`, `testAppLeftoversCarveOutOutsideHomeAndApplicationsRejected` |
| Startup items (M-05, degraded by macOS) | `StartupItemsViewModelTests`: `testRowsMapStatusLinesAndToggleAvailability`, `testForeignItemsAreNeverTogglable`, `testRefreshLoadsFromController`, `testForeignItemsHintDirectsToSystemSettings` |

Phase 3 flows with **no** automated coverage (hand-verified — see item 17–22 below):
`AppEnvironment.applySchedulePreference()` (launch wiring of the loop) and
`AppEnvironment.runScheduledCleanupNow()` — including the "Run now never stamps
`lastScheduledRun`" invariant, which no test asserts — the `NSStatusItem` itself
(installation/removal and the popover's SwiftUI content), the SwiftUI settings rows
their view models are tested underneath, an end-to-end scheduled fire inside the app
(proven once by the recorded fixture smoke above, not repeatable in CI), the
uninstaller screen's end-to-end flow with real refusal rendering, and the Login Items
screen against the real SMAppService.

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

### Manual QA checklist additions (Phase 3 gate — fixture home, prefs seeded)

17. **Scheduled cleanup (enable + Run now + catch-up)** — Settings: the schedule toggle,
    interval picker (1–30 days) and safe-only copy render; enabling the schedule shows the
    last-run/next-run lines. **Run now** runs a full scan inline — the button reads
    "Scanning…" and disables while running, the dashboard's last-scan line refreshes, no
    confirmation sheet appears — and must NOT advance the schedule's last-run line. For the
    unattended fire, seed `lastScheduledRun` 8 days overdue (command in the fixture section;
    reference-date seconds!), relaunch: exactly one catch-up runs at launch — the fixture's
    safe items are cleaned, `history.json`/`lastscan.json` appear under
    `FIXTURE_HOME/Library/Application Support/Cleanora`, and `.Trash`, the Safari and Docker
    `.review` rows and the large file are untouched. Disabling the schedule mid-flight stops
    the loop (a subsequent fire does not happen).
18. **Menu bar (M-01)** — Settings: Menu Bar Item ON installs the status item immediately;
    the panel shows the junk estimate, free space, last-clean and last-scan lines plus a
    button that opens the main window; closing the main window keeps the app alive in the
    menu bar; toggling OFF removes the item and closing the window then quits the app.
19. **Duplicates (opt-in flow)** — Duplicates screen starts empty; add
    `$FX/DuplicateScope` as the scope (a nested folder, e.g. the scope itself, must be
    rejected), Scan: progress counts climb, and exactly ONE group appears from
    `report.dat`/`report-copy.dat` — the keeper (newer `report-copy.dat`) renders without a
    checkbox, `unique.dat` appears nowhere; all deletable rows start unchecked; checking
    one and running Move to Trash goes through the normal confirmation sheet and lands the
    file in the fixture `.Trash`; the group reconciles on return (removed row gone; a group
    down to one file disappears).
20. **Uninstaller (flow + refusal rendering)** — Uninstaller screen lists `Fixture Editor`
    (from the fixture `Applications` folder); searching filters it; selecting it plans six
    rows, ALL unchecked: the bundle, its cache, Application Support and saved state
    (cleanable), plus `com.fixture.editor.plist` and the `Containers/com.fixture.editor`
    row — whose reason copy says the gate never deletes inside Containers. Uninstall is
    disabled with a reason while nothing is selected. Select the cleanable rows plus both
    refusal rows, confirm: the cleanable rows are removed (bundle to the fixture
    `.Trash`), and the results render the two gate REFUSALS as refusals — never silent
    successes. Re-running with `Fixture Editor.app` running (launch it from Finder) must
    disable Uninstall with the "Quit … first" reason.
21. **Startup items (degraded by macOS)** — the Login Items screen lists ONLY Cleanora's
    own row with an honest On/Off status; the foreign-items hint names System Settings as
    the place for everything else (no toggle is offered for rows the app cannot manage);
    in dev/ad-hoc builds the toggle surfaces the ServiceManagement failure copy and keeps
    its persisted value.
22. **Suggestions card (M-03)** — with the plain fixture the dashboard card stays empty
    (every fixture total sits far below the rule thresholds). To see cards, add a sparse
    above-threshold archive
    (`dd if=/dev/zero of="$FX/Library/Developer/Xcode/Archives/Big 1-1-26.xcarchive/Products/App.dSYM" bs=1 count=0 seek=600000000`),
    rescan: the "Old Xcode archives" card appears with the measured estimate, is inert
    (nothing is auto-selected) and routes back into the Developer Data review.
23. **Uninstaller footer reason** — with the `Fixture Editor` app running and leftover
    rows selected, the Uninstall bar reads "Quit Fixture Editor first" (next to the
    totals and as the button's hint) — never "select at least one item".

### Manual QA checklist additions (UX quick wins)

24. **First-run explainer** — on first fixture boot the dashboard shows the three-point
    explainer card above a single Scan Mac button; after a scan the card is gone and never
    returns after Clear History.
