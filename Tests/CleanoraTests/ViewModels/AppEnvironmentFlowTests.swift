import XCTest
@testable import Cleanora

/// App-layer flow glue: scan finish → last-scan persistence, cleanup finish →
/// history write-back (QA gate found these untested), plus the Phase-2 flow
/// wiring — auto-clean after a scan (P-13), the developer gate → scanner set,
/// launch at login (P-15) and the Finder reveal seam (P-09).
@MainActor
final class AppEnvironmentFlowTests: TempHomeTestCase {
    private func makeEnvironment(
        loginItem: LoginItemController? = nil,
        fileRevealer: FileRevealer? = nil
    ) -> AppEnvironment {
        // Isolated defaults: the standard domain may carry state from real
        // app runs and must never decide test outcomes.
        let defaults = UserDefaults(suiteName: "AppEnvironmentFlowTests-\(UUID().uuidString)")!
        return AppEnvironment(
            preferences: PreferencesStore(defaults: defaults),
            scanEnvironment: environment,
            permissionProbe: PermissionProbe(
                hasFullDiskAccess: { true },
                openFullDiskAccessSettings: {}
            ),
            loginItem: loginItem,
            fileRevealer: fileRevealer
        )
    }

    private func makeResult(items: [CleanupItem]) -> ScanResult {
        ScanResult(
            startedAt: Date(), finishedAt: Date().addingTimeInterval(2),
            items: items
        )
    }

    private func safeItem(
        name: String = "Cache",
        bytes: Int64 = 500,
        cacheBundle: String = "com.example"
    ) -> CleanupItem {
        CleanupItem(
            name: name, category: .applicationCaches,
            path: tempHome.appendingPathComponent("Library/Caches/\(cacheBundle)"),
            size: bytes, riskLevel: .safe, reason: "test",
            deletionMethod: .trashDirectory
        )
    }

    private func trashItem() -> CleanupItem {
        CleanupItem(
            name: "Trash", category: .trash,
            path: tempHome.appendingPathComponent(".Trash/stuff"),
            size: 400, riskLevel: .safe, reason: "test",
            deletionMethod: .removeContents, confirmationLevel: .destructive
        )
    }

    private func reviewItem() -> CleanupItem {
        CleanupItem(
            name: "Big File", category: .largeFiles,
            path: tempHome.appendingPathComponent("Movies/big.mkv"),
            size: 900, riskLevel: .review, reason: "test",
            deletionMethod: .moveToTrash
        )
    }

    // MARK: Base flow persistence

    func testFinishScanPersistsLastScan() {
        let env = makeEnvironment()
        let result = makeResult(items: [safeItem()])
        env.finishScan(result)
        let persisted = env.scanHistoryStore.lastScan()
        XCTAssertEqual(persisted?.id, result.id)
    }

    func testFinishCleanupAppendsHistoryWhenKeepHistoryOn() {
        let env = makeEnvironment()
        XCTAssertTrue(env.preferences.value.keepCleanupHistory)
        let report = CleanupReport(
            startedAt: Date(), finishedAt: Date(),
            outcomes: [ItemOutcome(
                itemID: UUID(), name: "Cache", category: .applicationCaches,
                path: "/tmp/x", status: .removed, bytesFreed: 100
            )],
            freeSpaceBefore: nil, freeSpaceAfter: nil, scanResultID: nil
        )
        env.finishCleanup(report)
        XCTAssertEqual(env.scanHistoryStore.history(limit: 10).count, 1)
        XCTAssertEqual(env.scanHistoryStore.history().first?.bytesFreed, 100)
    }

    func testFinishCleanupSkipsHistoryWhenKeepHistoryOff() {
        let env = makeEnvironment()
        env.preferences.update { $0.keepCleanupHistory = false }
        let report = CleanupReport(
            startedAt: Date(), finishedAt: Date(),
            outcomes: [ItemOutcome(
                itemID: UUID(), name: "Cache", category: .applicationCaches,
                path: "/tmp/x", status: .removed, bytesFreed: 100
            )],
            freeSpaceBefore: nil, freeSpaceAfter: nil, scanResultID: nil
        )
        env.finishCleanup(report)
        XCTAssertTrue(env.scanHistoryStore.history().isEmpty)
    }

    func testFinishCleanupIgnoresEmptyOutcomeReports() {
        let env = makeEnvironment()
        let report = CleanupReport(
            startedAt: Date(), finishedAt: Date(), outcomes: [],
            freeSpaceBefore: nil, freeSpaceAfter: nil, scanResultID: nil
        )
        env.finishCleanup(report)
        XCTAssertTrue(env.scanHistoryStore.history().isEmpty)
    }

    // MARK: P-13 auto-clean after a scan

    func testScanDidFinishRoutesToResultsWhenAutoCleanOff() {
        let env = makeEnvironment()
        XCTAssertFalse(env.preferences.value.automaticallyCleanSafeItems)
        env.scanDidFinish(makeResult(items: [safeItem()]))

        XCTAssertEqual(env.navigation.route, .results)
        XCTAssertNil(env.pendingCleaning)
        XCTAssertNil(env.autoCleanFallbackMessage, "disabled auto-clean is not a fallback — no banner")
    }

    func testScanDidFinishAutoCleansSafeSelectionWithoutConfirmation() {
        let env = makeEnvironment()
        env.preferences.update { $0.automaticallyCleanSafeItems = true }
        let safe = safeItem(bytes: 500)
        let review = reviewItem()
        env.scanDidFinish(makeResult(items: [safe, review]))

        XCTAssertEqual(env.navigation.route, .cleaning, "safe-only selections clean without asking")
        let request = env.takePendingCleaning()
        XCTAssertNotNil(request, "no confirmation sheet intervenes")
        XCTAssertEqual(request?.items.map(\.name), ["Cache"], "review items never join an auto-clean")
        XCTAssertEqual(request?.confirmed, Set([safe.id]), "I5: confirmed set carries the item ids")
        XCTAssertEqual(request?.selectedBytes, 500)
        XCTAssertNil(env.autoCleanFallbackMessage)
    }

    func testScanDidFinishFallsBackLoudlyWhenTrashIsSelected() {
        let env = makeEnvironment()
        env.preferences.update { $0.automaticallyCleanSafeItems = true }
        env.scanDidFinish(makeResult(items: [safeItem(), trashItem()]))

        XCTAssertEqual(env.navigation.route, .results, "a non-empty Trash forces the review flow")
        XCTAssertNil(env.pendingCleaning, "nothing may start cleaning behind the user's back")
        XCTAssertNotNil(env.autoCleanFallbackMessage, "the skipped auto-clean is stated, never silent")
    }

    func testScanDidFinishFallsBackWhenNothingWasPreselected() {
        let env = makeEnvironment()
        env.preferences.update { $0.automaticallyCleanSafeItems = true }
        env.scanDidFinish(makeResult(items: [reviewItem()]))

        XCTAssertEqual(env.navigation.route, .results)
        XCTAssertNil(env.pendingCleaning)
        XCTAssertNotNil(env.autoCleanFallbackMessage)
    }

    func testCancelledCleanupMarksResultsForReconciliationOnce() {
        let env = makeEnvironment()
        XCTAssertFalse(env.takeResultsReconciliation())

        env.markResultsStaleAfterCancelledCleanup()
        XCTAssertTrue(env.takeResultsReconciliation())
        XCTAssertFalse(env.takeResultsReconciliation(), "consumed exactly once")

        env.markResultsStaleAfterCancelledCleanup()
        env.finishScan(makeResult(items: [safeItem()]))
        XCTAssertFalse(env.takeResultsReconciliation(), "a new scan replaces the stale review")
    }

    // MARK: P-13 end-to-end: the scan VM's finish routes through the policy

    func testScanViewModelFinishRoutesThroughAutoCleanPolicy() async {
        let env = makeEnvironment()
        env.preferences.update { $0.automaticallyCleanSafeItems = true }
        let cacheDir = tempHome.appendingPathComponent("Library/Caches/com.example.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? Data(repeating: 1, count: 64).write(to: cacheDir.appendingPathComponent("blob.bin"))

        let viewModel = ScanViewModel(environment: env)
        viewModel.start()
        let routed = await waitUntil(timeout: 10) {
            env.navigation.route == .cleaning || env.navigation.route == .results
        }
        XCTAssertTrue(routed, "scan finish must route through the flow policy")
        XCTAssertEqual(env.navigation.route, .cleaning, "a safe-only scan result auto-cleans")
        XCTAssertNotNil(env.takePendingCleaning())
    }

    // MARK: Fan-out progress rows (engine-a2 wiring)

    func testScanViewModelExpandsDeveloperFanOutProgressRows() {
        let env = makeEnvironment()
        env.preferences.update { $0.includeDeveloperData = true }
        let viewModel = ScanViewModel(environment: env)
        let labels = viewModel.keys.map(\.label)

        XCTAssertTrue(
            labels.contains { $0.contains("Xcode") },
            "fan-out scanners must expand into per-tool rows, got \(labels)"
        )
        XCTAssertGreaterThan(viewModel.keys.count, 6)
    }

    func testScanViewModelCollapsesFanOutRowsWhenDeveloperModeOff() {
        let env = makeEnvironment()
        XCTAssertFalse(env.preferences.value.includeDeveloperData)
        let viewModel = ScanViewModel(environment: env)
        let labels = Set(viewModel.keys.map(\.label))

        XCTAssertFalse(
            labels.contains { $0.contains("Xcode") },
            "gated-off fan-out stays collapsed"
        )
        XCTAssertEqual(labels, [
            "Application Caches", "Browser Caches", "Temporary Files",
            "Old Logs", "Trash", "Large Files",
        ])
    }

    // MARK: P-13 options resolution (developer gate → scanner set)

    func testResolvedOptionsMirrorDeveloperGateIntoCategories() {
        var options = ScanOptions()
        options.includeDeveloperData = true
        let resolved = ScannerCatalog.resolvedOptions(options)

        XCTAssertTrue(resolved.includeDeveloperData)
        XCTAssertTrue(
            resolved.enabledCategories.contains(.developerData),
            "the coordinator gates on enabledCategories — the flag must be mirrored"
        )
    }

    func testResolvedOptionsAlwaysScanLargeFiles() {
        var options = ScanOptions()
        options.includeDeveloperData = false
        let resolved = ScannerCatalog.resolvedOptions(options)

        XCTAssertTrue(
            resolved.enabledCategories.contains(.largeFiles),
            "large files are informational and review-only — no toggle exists, so always scanned"
        )
        XCTAssertEqual(resolved.largeFileMinimumBytes, options.largeFileMinimumBytes)
    }

    func testResolvedOptionsLeavePhaseOneCategoriesUntouched() {
        let resolved = ScannerCatalog.resolvedOptions(ScanOptions())
        XCTAssertEqual(resolved.enabledCategories, Set(ScanCategory.phaseOne).union([.largeFiles]))
    }

    // MARK: P-15 launch at login

    /// @MainActor-isolated doubles: implicitly Sendable, so the controller's
    /// @Sendable closures can capture them under strict concurrency.
    @MainActor
    private final class LoginItemRecorder {
        private(set) var requests: [Bool] = []
        var outcome: LoginItemController.Outcome = .succeeded

        func record(_ enabled: Bool) { requests.append(enabled) }
    }

    @MainActor
    private final class RevealRecorder {
        private(set) var revealed: [URL] = []
        func record(_ url: URL) { revealed.append(url) }
    }

    func testLaunchAtLoginSuccessPersistsPreferenceAndStatus() {
        let recorder = LoginItemRecorder()
        let controller = LoginItemController(
            setEnabled: { [recorder] in recorder.record($0); return recorder.outcome },
            isCurrentlyEnabled: { false }
        )
        let env = makeEnvironment(loginItem: controller)

        env.setLaunchAtLogin(true)

        XCTAssertEqual(recorder.requests, [true])
        XCTAssertTrue(env.preferences.value.launchAtLogin, "success persists the preference")
        XCTAssertEqual(
            env.loginItemStatusMessage,
            SettingsViewModel.launchAtLoginStatus(outcome: .succeeded, enabled: true)
        )
    }

    func testLaunchAtLoginFailureKeepsPreferenceAndSurfacesError() {
        let recorder = LoginItemRecorder()
        recorder.outcome = .failed("missing signature")
        let controller = LoginItemController(
            setEnabled: { [recorder] in recorder.record($0); return recorder.outcome },
            isCurrentlyEnabled: { false }
        )
        let env = makeEnvironment(loginItem: controller)

        env.setLaunchAtLogin(true)

        XCTAssertFalse(
            env.preferences.value.launchAtLogin,
            "a failed registration must not persist the toggle"
        )
        XCTAssertEqual(
            env.loginItemStatusMessage,
            SettingsViewModel.launchAtLoginStatus(outcome: .failed("missing signature"), enabled: false),
            "the ServiceManagement error surfaces as row status — loud, never silent"
        )
    }

    func testDisableAtLoginUnregistersOnSuccess() {
        let recorder = LoginItemRecorder()
        let controller = LoginItemController(
            setEnabled: { [recorder] in recorder.record($0); return recorder.outcome },
            isCurrentlyEnabled: { true }
        )
        let env = makeEnvironment(loginItem: controller)
        env.preferences.update { $0.launchAtLogin = true }

        env.setLaunchAtLogin(false)

        XCTAssertEqual(recorder.requests, [false])
        XCTAssertFalse(env.preferences.value.launchAtLogin)
    }

    // MARK: P-09 Finder reveal seam

    func testRevealInFinderDelegatesToInjectedSeam() {
        let recorder = RevealRecorder()
        let env = makeEnvironment(fileRevealer: FileRevealer(reveal: { [recorder] in recorder.record($0) }))
        let url = URL(fileURLWithPath: "/tmp/some-large-file.mkv")

        env.revealInFinder(url)

        XCTAssertEqual(recorder.revealed, [url])
    }

    // MARK: CleaningRequest construction

    func testCleaningRequestCarriesConfirmedIDsAndBytes() {
        let a = safeItem(name: "A", bytes: 100)
        let b = safeItem(name: "B", bytes: 250)
        let request = AppEnvironment.cleaningRequest(for: [a, b], scanResultID: UUID())

        XCTAssertEqual(request.items.map(\.name), ["A", "B"])
        XCTAssertEqual(request.confirmed, Set([a.id, b.id]), "I5: every item is explicitly confirmed")
        XCTAssertFalse(request.destructiveConfirmed, "only set by the sheet for destructive selections")
        XCTAssertEqual(request.selectedBytes, 350)
    }

    // MARK: Reviewer finding 2 — lastScanResult reconciles after a partial clean

    func testFinishCleanupDropsRemovedItemsFromLastScan() {
        let env = makeEnvironment()
        let removed = safeItem(name: "Removed", bytes: 500, cacheBundle: "com.removed")
        let survivor = safeItem(name: "Survivor", bytes: 250, cacheBundle: "com.survivor")
        env.finishScan(makeResult(items: [removed, survivor]))

        let report = CleanupReport(
            startedAt: Date(), finishedAt: Date(),
            outcomes: [ItemOutcome(
                itemID: removed.id, name: removed.name, category: removed.category,
                path: removed.path.path, status: .removed, bytesFreed: 500
            )],
            freeSpaceBefore: nil, freeSpaceAfter: nil, scanResultID: nil
        )
        env.finishCleanup(report)

        let result = env.lastScanResult
        XCTAssertEqual(result?.items.map(\.name), ["Survivor"], "deleted items stop counting")
        XCTAssertEqual(env.scanHistoryStore.lastScan()?.items.map(\.name), ["Survivor"])
    }

    func testFinishCleanupKeepsLastScanUntouchedWhenNothingRemoved() {
        let env = makeEnvironment()
        env.finishScan(makeResult(items: [safeItem(name: "A", bytes: 100)]))

        let report = CleanupReport(
            startedAt: Date(), finishedAt: Date(),
            outcomes: [ItemOutcome(
                itemID: UUID(), name: "A", category: .applicationCaches,
                path: "/nowhere", status: .failed, bytesFreed: 0
            )],
            freeSpaceBefore: nil, freeSpaceAfter: nil, scanResultID: nil
        )
        env.finishCleanup(report)

        XCTAssertEqual(env.lastScanResult?.items.count, 1)
    }
}
