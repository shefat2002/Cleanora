import Foundation
import XCTest
@testable import Cleanora

/// Shared fixtures and stream builders for ViewModel tests. Streams are
/// hand-built so tests drive the frozen engine contracts directly, exactly
/// like the real coordinators will.
enum VMFixtures {
    static func item(
        name: String,
        category: ScanCategory,
        size: Int64,
        risk: RiskLevel,
        appName: String? = nil,
        selected: Bool? = nil,
        confirmationLevel: CleanupItem.ConfirmationLevel = .standard,
        deletionMethod: DeletionMethod = .trashDirectory
    ) -> CleanupItem {
        CleanupItem(
            name: name,
            appName: appName,
            category: category,
            path: URL(fileURLWithPath: "/tmp/cleanora-vm-tests/\(name)"),
            size: size,
            riskLevel: risk,
            selected: selected,
            reason: "Fixture reason for \(name)",
            deletionMethod: deletionMethod,
            confirmationLevel: confirmationLevel
        )
    }

    static func scanResult(
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        items: [CleanupItem]
    ) -> ScanResult {
        ScanResult(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(5),
            items: items
        )
    }

    static func outcome(
        for item: CleanupItem,
        status: ItemOutcome.Status,
        bytesFreed: Int64,
        message: String? = nil
    ) -> ItemOutcome {
        ItemOutcome(
            itemID: item.id,
            name: item.name,
            category: item.category,
            path: item.path.path,
            status: status,
            bytesFreed: bytesFreed,
            message: message
        )
    }

    static func historyEntry(
        date: Date,
        bytesFreed: Int64 = 1_000_000_000,
        itemsRemoved: Int = 3,
        categories: [CleanupHistoryEntry.CategoryTotal] = []
    ) -> CleanupHistoryEntry {
        CleanupHistoryEntry(
            id: UUID(),
            date: date,
            bytesFreed: bytesFreed,
            itemsRemoved: itemsRemoved,
            duration: 12,
            categoryTotals: categories,
            appVersion: "0.1.0"
        )
    }

    /// Deterministic clock for date-formatting tests: 2026-09-12 10:42 GMT.
    static let gregorianGMT: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }()
    static let posixLocale = Locale(identifier: "en_US_POSIX")
    static let fixedNow: Date = gregorianGMT.date(
        from: DateComponents(year: 2026, month: 9, day: 12, hour: 10, minute: 42)
    )!
}

/// Hand-built streams mirroring the frozen engine contracts.
enum TestStreams {
    static func scan(_ updates: [ScanUpdate], holdOpen: Bool = false) -> AsyncStream<ScanUpdate> {
        AsyncStream { continuation in
            for update in updates { continuation.yield(update) }
            if !holdOpen { continuation.finish() }
        }
    }

    static func cleanup(_ events: [CleanupEvent], holdOpen: Bool = false) -> AsyncStream<CleanupEvent> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            if !holdOpen { continuation.finish() }
        }
    }
}

/// Collects onFinish callbacks; also usable as a plain counter.
@MainActor
final class ResultSink<Output> {
    private(set) var outputs: [Output] = []
    var count: Int { outputs.count }

    func record(_ output: Output) {
        outputs.append(output)
    }
}

extension XCTestCase {
    /// VMs apply stream updates on the main actor; tests run there too, so a
    /// short polling loop replaces fragile expectations.
    @MainActor
    func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
