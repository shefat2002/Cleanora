import Foundation

/// Pure decision logic for refusing route changes while a scan or a clean is
/// in flight. The ⌘R/⌘1 menu commands (and the menu-bar panel) made
/// NavigationState.go reachable mid-flow for the first time; without this
/// policy ⌘1 mid-scan followed by ⌘R built a second ScanViewModel — the idle
/// guard is per-instance — and the two coordinators raced to scanDidFinish
/// (double history, double auto-clean), while ⌘1 mid-clean escaped the
/// non-dismissable cleaning screen and the orphaned run later teleported the
/// user to .completion.
///
/// The matrix encodes the app's two design intents:
/// - a CLEAN is non-dismissable by design (CleaningView has no cancel
///   chrome; the executor finishes every started cleanup), and
/// - a SCAN is cancellable but not abandonable: the running screen's only
///   exit is its in-screen Cancel, which stays on .scan — the VM's
///   .cancelled terminal releases the flight before that screen navigates.
enum NavigationPolicy {
    static func isBlocked(
        current: ScreenRoute,
        destination: ScreenRoute,
        isScanRunning: Bool,
        isCleanRunning: Bool
    ) -> Bool {
        if isCleanRunning {
            // The one transition left open is ENTERING .cleaning: every
            // clean is staged as beginCleaning → go(.cleaning), and that
            // handoff must not be refused by the very flag it just set. No
            // user-facing surface targets .cleaning, so no shortcut can
            // slip through the opening.
            return destination != .cleaning
        }
        if isScanRunning {
            // No second scan, ever: re-entering .scan builds a fresh view
            // model and two coordinators would race to scanDidFinish.
            if destination == .scan { return true }
            // Leaving .scan orphans the running scan; the in-screen Cancel
            // remains the exit and it navigates only after its terminal.
            if current == .scan { return true }
            // A background scheduled scan must not freeze ordinary
            // dashboard / settings / history browsing.
            return false
        }
        return false
    }
}
