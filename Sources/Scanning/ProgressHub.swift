import Foundation

/// O-01 — coalesces concurrent per-scanner state updates into `ScanProgress`
/// snapshots and throttles emission to at most one per `minimumInterval`
/// (100 ms by default → ≤10 snapshots/second), so a chatty scanner can never
/// flood the UI. The final state is always flushed.
actor ProgressHub {
    private var states: [ScannerKey: ScannerState]
    private var lastEmit: ContinuousClock.Instant
    private var dirty = false
    private let minimumInterval: Duration

    init(
        initialStates: [ScannerKey: ScannerState] = [:],
        minimumInterval: Duration = .milliseconds(100)
    ) {
        self.states = initialStates
        self.minimumInterval = minimumInterval
        self.lastEmit = ContinuousClock.now
    }

    /// Emits the initial snapshot unconditionally (the UI renders all progress
    /// rows immediately) and starts the throttle window.
    func begin(emit: @Sendable (ScanProgress) -> Void) {
        lastEmit = ContinuousClock.now
        dirty = false
        emit(snapshot())
    }

    /// Records an update and emits a snapshot only when the throttle window
    /// allows; otherwise the change is coalesced into the next emission.
    func record(
        _ key: ScannerKey,
        _ state: ScannerState,
        emit: @Sendable (ScanProgress) -> Void
    ) {
        states[key] = state
        guard ContinuousClock.now - lastEmit >= minimumInterval else {
            dirty = true
            return
        }
        lastEmit = ContinuousClock.now
        dirty = false
        emit(snapshot())
    }

    /// Final emission — never throttled away, so the last states always land.
    func flush(emit: @Sendable (ScanProgress) -> Void) {
        lastEmit = ContinuousClock.now
        dirty = false
        emit(snapshot())
    }

    func currentStates() -> [ScannerKey: ScannerState] {
        states
    }

    private func snapshot() -> ScanProgress {
        ScanProgress(states: states)
    }
}
