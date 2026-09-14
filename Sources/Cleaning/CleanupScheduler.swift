import Foundation
import os

/// Unattended, interval-based cleanup loop (M-02).
///
/// The scheduler owns only TIME and POLICY, never engines: scanning and
/// cleaning happen through the injected `scan`/`clean` closures, which the
/// App layer wires to ScanCoordinator and a safe-only CleanupExecutor run.
/// Every fire:
///
///  1. consumes the schedule slot (`lastScheduledRun = fire time`, persisted
///     BEFORE the scan so a crash mid-run cannot produce a catch-up storm),
///  2. runs the scan with the stored options and records it as finished
///     (last-scan file — also in notify-only mode),
///  3. cleans ONLY the preselected (`.safe`) non-destructive selection when
///     `scheduleAutoCleanSafeOnly` is on. Trash and `.destructive` items can
///     never be in that set (I4/I6); SafetyPolicy refuses them a third time
///     at the executor if anything upstream ever regresses.
///
/// Layering: Foundation/os only — the LaunchAgent/SMAppService path is
/// documented future work and stays out of this file.
@MainActor
@Observable
final class CleanupScheduler {
    private static let log = Logger(subsystem: "com.cleanora.app", category: "scheduler")

    typealias ScanClosure = @Sendable (ScanOptions) async -> ScanResult?
    typealias CleanClosure = @Sendable (ScanResult) async -> Void
    typealias SleepClosure = @Sendable (TimeInterval) async throws -> Void
    typealias NowClosure = @Sendable () -> Date

    private let environment: ScanEnvironment
    private let preferences: PreferencesStore
    private let history: ScanHistoryStore
    private let diskInfo: DiskInfoProvider
    private let scan: ScanClosure
    private let clean: CleanClosure
    private let sleep: SleepClosure
    private let now: NowClosure

    /// True while the loop is alive (between `start()` and `stop()`).
    private(set) var isRunning = false
    /// Next scheduled fire, exposed for the menu bar / settings row.
    private(set) var nextRun: Date?
    /// True between handing the selection to the clean closure and its return.
    private(set) var isCleaning = false

    private var loopTask: Task<Void, Never>?
    /// Bumps on every start/stop so a cancelled loop's exit path can't clobber
    /// the state of a loop started after it.
    private var generation = 0

    init(
        environment: ScanEnvironment,
        preferences: PreferencesStore,
        history: ScanHistoryStore,
        diskInfo: DiskInfoProvider,
        scan: @escaping ScanClosure,
        clean: @escaping CleanClosure,
        sleeper: @escaping SleepClosure = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping NowClosure = { Date() }
    ) {
        self.environment = environment
        self.preferences = preferences
        self.history = history
        self.diskInfo = diskInfo
        self.scan = scan
        self.clean = clean
        self.sleep = sleeper
        self.now = now
    }

    /// Begins the loop. No-op when the schedule is disabled or already
    /// running. `nextRun` is `lastScheduledRun + interval` — a not-yet-due
    /// previous run resumes its original cadence, an overdue one produces
    /// exactly ONE catch-up fire inside the loop, and a nil one starts the
    /// first interval from now.
    func start() {
        guard !isRunning else { return }
        guard preferences.value.scheduleEnabled else {
            Self.log.notice("schedule disabled; not starting")
            return
        }
        isRunning = true
        generation += 1
        switch preferences.value.lastScheduledRun {
        case .none:
            nextRun = now().addingTimeInterval(preferences.value.scheduleInterval)
        case .some(let last):
            nextRun = last.addingTimeInterval(preferences.value.scheduleInterval)
        }
        Self.log.notice(
            "scheduler started for \(self.environment.home.path, privacy: .public); next run in \(self.nextRun.map { $0.timeIntervalSince(self.now()) } ?? 0, privacy: .public)s"
        )
        loopTask = Task { await self.runLoop(generation: generation) }
    }

    /// Cancels the loop. A parked sleep wakes cancelled and the loop exits
    /// without firing. Safe to call when not running.
    func stop() {
        generation += 1
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        nextRun = nil
    }

    // MARK: - Loop

    private func runLoop(generation myGeneration: Int) async {
        // At most one catch-up per start: a schedule missed while the app was
        // closed is honored once, then the cadence resyncs from the fire time
        // instead of replaying every missed period.
        if let target = nextRun, now() >= target {
            await fire(at: now())
            nextRun = now().addingTimeInterval(preferences.value.scheduleInterval)
        }

        while !Task.isCancelled {
            guard preferences.value.scheduleEnabled else { break }
            guard let target = nextRun else { break }
            let delay = max(0, target.timeIntervalSince(now()))
            do {
                try await sleep(delay)
            } catch {
                break // cancelled (or the sleeper ended) — leave quietly
            }
            guard !Task.isCancelled else { break }
            await fire(at: now())
            nextRun = now().addingTimeInterval(preferences.value.scheduleInterval)
        }

        // Only the current generation owns the running-state teardown; a
        // stale loop cancelled by stop() (or superseded by start()) must not
        // reset the replacement's state.
        guard myGeneration == generation else { return }
        isRunning = false
        nextRun = nil
    }

    private func fire(at date: Date) async {
        preferences.update { $0.lastScheduledRun = date }
        if let freeBytes = diskInfo.availableBytes() {
            Self.log.notice(
                "scheduled cleanup firing; \(freeBytes) bytes free"
            )
        } else {
            Self.log.notice("scheduled cleanup firing; free space unavailable")
        }

        let options = preferences.value.scanOptions
        guard let result = await scan(options) else {
            Self.log.error("scheduled scan failed; skipping this cycle's clean")
            return
        }
        // "Scan finished" record — written even in notify-only mode so the
        // dashboard reflects what the scheduled scan saw.
        history.saveLastScan(result)

        guard preferences.value.scheduleAutoCleanSafeOnly else {
            Self.log.notice("scheduled scan finished; auto-clean is off, nothing deleted")
            return
        }
        let selection = Self.scheduledCleanSelection(in: result)
        guard !selection.isEmpty else {
            Self.log.notice(
                "scheduled scan finished; nothing preselected is safe to clean unattended"
            )
            return
        }
        isCleaning = true
        defer { isCleaning = false }
        await clean(Self.markingSelection(selection, on: result))
        Self.log.notice("scheduled clean finished; \(selection.count) items requested")
    }

    // MARK: - Selection policy

    /// What a scheduled run may clean: items the scan selected that are
    /// preselected (`.safe`) AND not destructive. Mirrors
    /// CleaningFlowPolicy.isDestructive (ViewModels cannot be imported
    /// downward): Trash and `.destructive` items always keep a human in the
    /// loop.
    static func scheduledCleanSelection(in result: ScanResult) -> Set<UUID> {
        Set(
            result.items
                .filter { $0.selected && $0.riskLevel.isPreselected && !isDestructive($0) }
                .map(\.id)
        )
    }

    private static func isDestructive(_ item: CleanupItem) -> Bool {
        item.category == .trash || item.confirmationLevel == .destructive
    }

    /// The result handed to the clean closure: unchanged identity, but with
    /// EXACTLY the scheduled selection marked selected, so the App-side
    /// wiring can derive the executor's confirmed set from `selectedItems`.
    static func markingSelection(_ ids: Set<UUID>, on result: ScanResult) -> ScanResult {
        ScanResult(
            id: result.id,
            startedAt: result.startedAt,
            finishedAt: result.finishedAt,
            items: result.items.map { $0.withSelection(ids.contains($0.id)) },
            summaries: result.summaries,
            freeSpaceBefore: result.freeSpaceBefore,
            scannerKeys: result.scannerKeys
        )
    }
}
