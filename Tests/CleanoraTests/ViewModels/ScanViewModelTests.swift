import XCTest
@testable import Cleanora

@MainActor
final class ScanViewModelTests: XCTestCase {
    private let appCachesKey = ScannerKey(id: .applicationCaches)
    private let logsKey = ScannerKey(id: .logs)

    func testProgressUpdatesAndFinishRoutesOnce() async {
        let progress = ScanProgress(states: [
            appCachesKey: .running(bytesScanned: 120, itemsFound: 2),
            logsKey: .completed(totalBytes: 80, itemCount: 1),
        ])
        let result = VMFixtures.scanResult(items: [
            VMFixtures.item(name: "A", category: .logs, size: 80, risk: .safe),
        ])
        let sink = ResultSink<ScanResult>()
        let viewModel = ScanViewModel(
            keys: [appCachesKey, logsKey],
            makeStream: { TestStreams.scan([.progress(progress), .finished(result)]) },
            onFinish: { sink.record($0) }
        )

        viewModel.start()
        let finished = await waitUntil { viewModel.phase == .finished }
        XCTAssertTrue(finished, "stream should reach .finished")
        XCTAssertEqual(viewModel.progress, progress)
        XCTAssertEqual(viewModel.discoveredBytes, 200)
        XCTAssertEqual(viewModel.overallFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sink.count, 1, "onFinish must fire exactly once")
        XCTAssertEqual(sink.outputs.first?.id, result.id)
    }

    func testCancelBreaksForAwaitAndReportsCancelledPhase() async {
        let progress = ScanProgress(states: [
            appCachesKey: .running(bytesScanned: 10, itemsFound: 0),
        ])
        let viewModel = ScanViewModel(
            keys: [appCachesKey],
            makeStream: {
                // Never finishes: consuming forever is what cancellation ends.
                TestStreams.scan([.progress(progress)], holdOpen: true)
            }
        )

        viewModel.start()
        let started = await waitUntil { viewModel.isRunning }
        XCTAssertTrue(started)
        viewModel.cancel()
        let cancelled = await waitUntil { viewModel.phase == .cancelled }
        XCTAssertTrue(cancelled, "cancel should end the loop with .cancelled")
    }

    func testFailedStreamSetsFailedPhase() async {
        let viewModel = ScanViewModel(
            keys: [appCachesKey],
            makeStream: { TestStreams.scan([.failed("disk gone")]) }
        )
        viewModel.start()
        let failed = await waitUntil { viewModel.phase == .failed("disk gone") }
        XCTAssertTrue(failed)
    }

    func testResetAllowsRestartAfterFailure() async {
        let viewModel = ScanViewModel(
            keys: [appCachesKey],
            makeStream: { TestStreams.scan([.failed("x")]) }
        )
        viewModel.start()
        let failed = await waitUntil { viewModel.phase == .failed("x") }
        XCTAssertTrue(failed, "stream should reach .failed before reset")
        viewModel.reset()
        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(viewModel.progress, ScanProgress())
    }

    func testPermissionDeniedMessageAppearsOnlyForPermissionSkips() {
        let denied = ScanProgress(states: [
            appCachesKey: .skipped(.permissionDenied("restricted")),
        ])
        XCTAssertEqual(
            ScanViewModel.permissionDeniedMessage(in: denied),
            "Full Disk Access not granted — some locations couldn't be scanned."
        )

        let clean = ScanProgress(states: [
            appCachesKey: .skipped(.pathNotFound("/missing")),
        ])
        XCTAssertNil(ScanViewModel.permissionDeniedMessage(in: clean))
    }

    func testSortedRowsOrderByCategoryThenLabel() {
        let trashB = ScannerKey(id: .trash, label: "b-trash")
        let trashA = ScannerKey(id: .trash, label: "a-trash")
        let keys = [trashB, ScannerKey(id: .applicationCaches), trashA, logsKey]
        let rows = ScanViewModel.sortedRows(progress: ScanProgress(), keys: keys)
        XCTAssertEqual(rows.map(\.key.label), ["Application Caches", "Old Logs", "a-trash", "b-trash"])
    }

    func testDetailTextsPerState() {
        XCTAssertNil(ScanViewModel.detailText(for: .pending))
        XCTAssertEqual(
            ScanViewModel.detailText(for: .running(bytesScanned: 1_500_000, itemsFound: 3)),
            "Scanning… 1.5 MB"
        )
        XCTAssertEqual(
            ScanViewModel.detailText(for: .completed(totalBytes: 8_400_000_000, itemCount: 5)),
            "8.4 GB across 5 items"
        )
        XCTAssertEqual(
            ScanViewModel.detailText(for: .skipped(.toolNotInstalled("Docker"))),
            "Skipped — Docker isn't installed"
        )
        XCTAssertEqual(
            ScanViewModel.detailText(for: .failed("nope")),
            "This check failed"
        )
    }

    /// Contract smoke: the real ScanCoordinator compiles against the frozen
    /// signature and its stream terminates with exactly one .finished update
    /// through the same consumption loop the VM uses.
    func testScanCoordinatorStreamContract() async {
        let environment = ScanEnvironment(
            home: URL(fileURLWithPath: "/tmp/cleanora-ui-contract-home"),
            temporaryRoot: URL(fileURLWithPath: "/tmp/cleanora-ui-contract-temp")
        )
        let coordinator = ScanCoordinator(
            scanners: [MockScanner(category: .logs, result: .produced([]))],
            environment: environment,
            options: ScanOptions(),
            diskInfo: DiskInfoProvider()
        )
        var updates: [ScanUpdate] = []
        for await update in coordinator.run() {
            updates.append(update)
        }
        guard case .finished = updates.last else {
            return XCTFail("stream must terminate with .finished, got \(updates.last.map(String.init(describing:)) ?? "nothing")")
        }
        let finishedCount = updates.filter {
            if case .finished = $0 { return true }
            return false
        }.count
        XCTAssertEqual(finishedCount, 1, "exactly one .finished per run")
    }
}
