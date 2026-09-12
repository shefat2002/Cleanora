import XCTest
@testable import Cleanora

@MainActor
final class CleaningViewModelTests: XCTestCase {
    private func makeRequest(items: [CleanupItem]) -> CleaningRequest {
        CleaningRequest(
            items: items,
            confirmed: Set(items.map(\.id)),
            destructiveConfirmed: items.contains { $0.confirmationLevel == .destructive },
            selectedBytes: items.reduce(0) { $0 + $1.size },
            scanResultID: UUID()
        )
    }

    private func makeViewModel(
        request: CleaningRequest,
        events: [CleanupEvent],
        holdOpen: Bool = false,
        sink: ResultSink<CleanupReport> = ResultSink()
    ) -> CleaningViewModel {
        CleaningViewModel(
            request: request,
            makeStream: { _ in TestStreams.cleanup(events, holdOpen: holdOpen) },
            onFinish: { sink.record($0) }
        )
    }

    func testProgressUpdatesChecklistAndFinishReportsOnce() async {
        let chrome = VMFixtures.item(name: "Chrome", category: .applicationCaches, size: 1_000, risk: .safe)
        let logs = VMFixtures.item(name: "Old Logs", category: .logs, size: 3_000, risk: .safe)
        let request = makeRequest(items: [chrome, logs])
        let chromeOutcome = VMFixtures.outcome(for: chrome, status: .removed, bytesFreed: 800)
        let report = CleanupReport(
            startedAt: Date(timeIntervalSince1970: 5_000),
            finishedAt: Date(timeIntervalSince1970: 5_010),
            outcomes: [chromeOutcome, VMFixtures.outcome(for: logs, status: .removed, bytesFreed: 2_950)],
            freeSpaceBefore: 87_400_000_000,
            freeSpaceAfter: 90_350_000_000,
            scanResultID: request.scanResultID
        )
        let sink = ResultSink<CleanupReport>()
        let viewModel = makeViewModel(
            request: request,
            events: [
                .progress(CleanupProgress(
                    currentItem: chrome,
                    outcomes: [chromeOutcome],
                    bytesFreedSoFar: 800
                )),
                .finished(report),
            ],
            sink: sink
        )

        viewModel.run()
        let finished = await waitUntil { viewModel.phase == .finished }
        XCTAssertTrue(finished)

        XCTAssertEqual(viewModel.bytesFreedSoFar, 800, "last progress sets the live byte counter")
        XCTAssertEqual(viewModel.fraction, 0.2, accuracy: 0.0001, "800 of 4000 bytes")
        XCTAssertEqual(viewModel.progressLine, "800 B / 4.0 KB")

        XCTAssertEqual(sink.count, 1, "onFinish fires exactly once")
        XCTAssertEqual(sink.outputs.first?.id, report.id)

        // Measured numbers only, straight from the report.
        XCTAssertEqual(viewModel.report?.bytesFreed, 3_750)
        XCTAssertEqual(viewModel.report?.itemsRemoved, 2)
        XCTAssertNil(viewModel.currentItem, "no item is current after finishing")
    }

    func testChecklistCoversEverySelectedItemWithState() async {
        let first = VMFixtures.item(name: "A", category: .applicationCaches, size: 100, risk: .safe)
        let second = VMFixtures.item(name: "B", category: .logs, size: 200, risk: .safe)
        let third = VMFixtures.item(name: "C", category: .trash, size: 300, risk: .safe, confirmationLevel: .destructive)
        let request = makeRequest(items: [first, second, third])
        let viewModel = makeViewModel(
            request: request,
            events: [
                .progress(CleanupProgress(
                    currentItem: third,
                    outcomes: [
                        VMFixtures.outcome(for: first, status: .removed, bytesFreed: 100),
                        VMFixtures.outcome(for: second, status: .failed, bytesFreed: 0, message: "locked"),
                    ],
                    bytesFreedSoFar: 100
                )),
            ],
            holdOpen: true
        )

        viewModel.run()
        let progressed = await waitUntil { viewModel.currentItem?.id == third.id }
        XCTAssertTrue(progressed)

        let rows = viewModel.checklist
        XCTAssertEqual(rows.count, 3, "one row per selected item")
        XCTAssertEqual(CleaningViewModel.accessibilitySummary(for: rows[0]), "Removed, 100 B freed")
        XCTAssertEqual(CleaningViewModel.accessibilitySummary(for: rows[1]), "Failed: locked")
        XCTAssertTrue(rows[2].isCurrent)
        XCTAssertEqual(CleaningViewModel.accessibilitySummary(for: rows[2]), "In progress")
        XCTAssertNil(rows[2].outcome)
    }

    func testFractionClampsToComplete() async {
        let item = VMFixtures.item(name: "Big", category: .applicationCaches, size: 1_000, risk: .safe)
        let request = makeRequest(items: [item])
        let viewModel = makeViewModel(
            request: request,
            events: [
                .progress(CleanupProgress(
                    currentItem: nil,
                    outcomes: [VMFixtures.outcome(for: item, status: .partial, bytesFreed: 5_000)],
                    bytesFreedSoFar: 5_000
                )),
            ],
            holdOpen: true
        )

        viewModel.run()
        _ = await waitUntil { viewModel.bytesFreedSoFar == 5_000 }
        XCTAssertEqual(viewModel.fraction, 1.0, accuracy: 0.0001, "over-reporting clamps, never overfills the bar")
    }

    func testCancelEndsInCancelledPhase() async {
        let item = VMFixtures.item(name: "A", category: .logs, size: 100, risk: .safe)
        let viewModel = makeViewModel(
            request: makeRequest(items: [item]),
            events: [],
            holdOpen: true
        )

        viewModel.run()
        let running = await waitUntil { viewModel.isRunning }
        XCTAssertTrue(running)
        viewModel.cancel()
        let cancelled = await waitUntil { viewModel.phase == .cancelled }
        XCTAssertTrue(cancelled, "view navigates back to Results on this")
    }

    func testZeroByteSelectionKeepsFractionAtZero() {
        let request = CleaningRequest(
            items: [],
            confirmed: [],
            destructiveConfirmed: false,
            selectedBytes: 0,
            scanResultID: nil
        )
        let viewModel = makeViewModel(request: request, events: [])
        XCTAssertEqual(viewModel.fraction, 0, "no division by zero on an empty batch")
        XCTAssertEqual(viewModel.progressLine, "0 B / 0 B")
    }

    /// Contract smoke: the frozen CleanupExecutor stub compiles and the same
    /// consumption loop the VM uses reaches its report.
    func testCleanupExecutorStubContract() async {
        let environment = ScanEnvironment(
            home: URL(fileURLWithPath: "/tmp/cleanora-ui-contract-home"),
            temporaryRoot: URL(fileURLWithPath: "/tmp/cleanora-ui-contract-temp")
        )
        let executor = CleanupExecutor(
            policy: .standard(home: environment.home, tempRoot: environment.temporaryRoot),
            logger: CleanupLogger(appDirs: AppDirectories(environment: environment)),
            environment: environment,
            diskInfo: DiskInfoProvider()
        )
        var events: [CleanupEvent] = []
        for await event in executor.run(items: [], confirmed: [], destructiveConfirmed: false) {
            events.append(event)
        }
        guard case .finished = events.last else {
            return XCTFail("expected a single .finished event, got \(events)")
        }
        XCTAssertEqual(events.count, 1)
    }
}
