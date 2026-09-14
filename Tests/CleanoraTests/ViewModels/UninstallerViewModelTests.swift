import XCTest
@testable import Cleanora

@MainActor
final class UninstallerViewModelTests: XCTestCase {
    private func app(
        name: String = "Example",
        bundleID: String = "com.example.app",
        version: String? = "2.1"
    ) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleID: bundleID,
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            bundleSize: 120_000_000,
            version: version
        )
    }

    private func makeViewModel(
        apps: [InstalledApp],
        leftovers: @escaping (InstalledApp) -> [CleanupItem] = { _ in [] },
        running: Set<String> = []
    ) -> UninstallerViewModel {
        UninstallerViewModel(
            loadInventory: { apps },
            planLeftovers: { app in leftovers(app) },
            isAppRunning: { app in
                guard let bundleID = app.bundleID else { return false }
                return running.contains(bundleID)
            }
        )
    }

    // MARK: - Inventory

    func testLoadInventorySortsCaseInsensitively() async {
        let viewModel = makeViewModel(apps: [
            app(name: "zeta"),
            app(name: "Alpha"),
            app(name: "beta"),
        ])
        await viewModel.loadInventoryIfNeeded()
        XCTAssertEqual(viewModel.apps.map(\.name), ["Alpha", "beta", "zeta"])
        XCTAssertEqual(viewModel.filteredApps.map(\.name), ["Alpha", "beta", "zeta"])
        XCTAssertFalse(viewModel.isEmpty)
    }

    func testInventoryErrorSurfacesAndEmptyStateApplies() async {
        let viewModel = UninstallerViewModel(
            loadInventory: { throw NSError(domain: "test", code: 1) },
            planLeftovers: { _ in [] },
            isAppRunning: { _ in false }
        )
        await viewModel.loadInventoryIfNeeded()
        XCTAssertNotNil(viewModel.inventoryError)
        XCTAssertTrue(viewModel.isEmpty)
    }

    // MARK: - Search filter

    func testFilterMatchesNameOrBundleIDCaseInsensitively() {
        let apps = [app(name: "Firefox"), app(name: "Xcode", bundleID: "com.apple.dt.Xcode")]
        XCTAssertEqual(
            UninstallerViewModel.filteredApps(apps, matching: "fire").map(\.name),
            ["Firefox"]
        )
        XCTAssertEqual(
            UninstallerViewModel.filteredApps(apps, matching: "DT.XCODE").map(\.name),
            ["Xcode"]
        )
        XCTAssertEqual(UninstallerViewModel.filteredApps(apps, matching: "  ").count, 2)
    }

    // MARK: - Running-app gate (injected seam)

    func testRunningAppDisablesUninstallWithReason() async {
        let viewModel = makeViewModel(
            apps: [app(name: "Runner", bundleID: "com.example.runner")],
            running: ["com.example.runner"]
        )
        await viewModel.loadInventoryIfNeeded()
        viewModel.select(viewModel.apps[0])
        let settled = await waitUntil { !viewModel.isLoadingLeftovers }
        XCTAssertTrue(settled)

        XCTAssertTrue(viewModel.isAppRunning)
        XCTAssertFalse(viewModel.canUninstall)
        XCTAssertEqual(viewModel.uninstallDisabledReason, "Quit Runner first")
    }

    func testStoppedAppAllowsUninstallOnceSomethingIsSelected() async {
        let viewModel = makeViewModel(
            apps: [app(name: "Calm", bundleID: "com.example.calm")],
            leftovers: { selected in
                [
                    VMFixtures.item(
                        name: "Example caches",
                        category: .appLeftovers,
                        size: 4_000,
                        risk: .review
                    )
                ]
            }
        )
        await viewModel.loadInventoryIfNeeded()
        viewModel.select(viewModel.apps[0])
        _ = await waitUntil { !viewModel.isLoadingLeftovers }

        XCTAssertFalse(viewModel.isAppRunning)
        XCTAssertFalse(viewModel.canUninstall, "nothing selected yet")

        viewModel.setSelection(true, itemID: viewModel.leftovers[0].id)
        XCTAssertTrue(viewModel.canUninstall)
        XCTAssertNil(viewModel.uninstallDisabledReason)
    }

    // MARK: - Planner output normalization

    func testPlannerRowsAreForcedUncheckedAtTheUIBoundary() async {
        // A misbehaving planner that preselects must not survive selection.
        let viewModel = makeViewModel(
            apps: [app(name: "Pushy", bundleID: "com.example.pushy")],
            leftovers: { _ in
                [
                    VMFixtures.item(
                        name: "support",
                        category: .appLeftovers,
                        size: 1_000,
                        risk: .review,
                        selected: true
                    )
                ]
            }
        )
        await viewModel.loadInventoryIfNeeded()
        viewModel.select(viewModel.apps[0])
        _ = await waitUntil { !viewModel.isLoadingLeftovers }

        XCTAssertEqual(viewModel.leftovers.map(\.selected), [false])
        XCTAssertEqual(viewModel.selectedBytes, 0)
    }

    // MARK: - Pure helpers

    func testVersionLineIsNilWithoutVersion() {
        XCTAssertEqual(UninstallerViewModel.versionLine(for: app(version: "3.0")), "Version 3.0")
        XCTAssertNil(UninstallerViewModel.versionLine(for: app(version: nil)))
        XCTAssertNil(UninstallerViewModel.versionLine(for: app(version: "")))
    }

    func testSelectionProvidingBasics() async {
        let viewModel = makeViewModel(
            apps: [app(name: "B", bundleID: "b"), app(name: "a", bundleID: "a")],
            leftovers: { _ in
                [
                    VMFixtures.item(name: "one", category: .appLeftovers, size: 100, risk: .review),
                    VMFixtures.item(name: "two", category: .appLeftovers, size: 200, risk: .review),
                ]
            }
        )
        await viewModel.loadInventoryIfNeeded()
        viewModel.select(viewModel.apps[0])
        _ = await waitUntil { !viewModel.isLoadingLeftovers }
        viewModel.setSelection(true, itemIDs: Set(viewModel.leftovers.map(\.id)))

        XCTAssertEqual(viewModel.selectedItems.count, 2)
        XCTAssertEqual(viewModel.selectedBytes, 300)
        XCTAssertEqual(viewModel.selectedCount, 2)
        XCTAssertFalse(viewModel.requiresDestructiveConfirmation)
    }
// Reviewer finding: the running gate is re-probed on every uninstall
    // attempt — launching the app AFTER selecting it must still be caught.
    func testRunningGateRevalidatedOnEveryUninstallAttempt() async {
        var running: Set<String> = []
        let runner = app(name: "Runner", bundleID: "com.example.runner")
        let viewModel = UninstallerViewModel(
            loadInventory: { [runner] },
            planLeftovers: { _ in
                [VMFixtures.item(
                    name: "Leftover",
                    category: .appLeftovers,
                    size: 10,
                    risk: .review
                )]
            },
            isAppRunning: { app in running.contains(app.bundleID ?? "") }
        )
        await viewModel.loadInventoryIfNeeded()
        viewModel.select(viewModel.apps[0])
        _ = await waitUntil { !viewModel.isLoadingLeftovers }
        viewModel.setSelection(true, itemID: viewModel.leftovers[0].id)
        XCTAssertTrue(viewModel.canUninstall)

        running.insert("com.example.runner")
        XCTAssertFalse(viewModel.uninstallAllowedAfterRevalidation())
        XCTAssertTrue(viewModel.isAppRunning)
        XCTAssertEqual(viewModel.uninstallDisabledReason, "Quit Runner first")
    }
}

private extension UninstallerViewModel {
    /// Batch selection helper for tests.
    func setSelection(_ isSelected: Bool, itemIDs: Set<UUID>) {
        for id in itemIDs {
            setSelection(isSelected, itemID: id)
        }
    }}
