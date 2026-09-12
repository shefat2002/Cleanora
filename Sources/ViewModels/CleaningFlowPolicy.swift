import Foundation

/// Pure decision logic for the two "clean without asking" surfaces (P-13):
/// when the confirmation sheet may be skipped, and when a finished scan may
/// start cleaning on its own. Both rules only ever LOWER friction for
/// non-destructive selections; anything irreversible always keeps the sheet.
///
/// Every fallback is returned with a reason so the UI can state out loud why
/// it did not act — safety fallbacks are never silent.
enum CleaningFlowPolicy {
    /// An item whose removal cannot be undone: Trash contents or anything its
    /// producer flagged destructive. Single source for the confirm sheet, the
    /// auto-clean fallback, and the Results footer.
    static func isDestructive(_ item: CleanupItem) -> Bool {
        item.category == .trash || item.confirmationLevel == .destructive
    }

    /// ConfirmCleanSheet is skipped only when the user turned off BOTH
    /// confirmation settings, and never when anything destructive is
    /// selected — the settings toggles cannot lower the I6 gate.
    static func requiresConfirmation(
        confirmBeforeCleaning: Bool,
        askBeforeDeleting: Bool,
        items: [CleanupItem]
    ) -> Bool {
        if items.contains(where: isDestructive) { return true }
        return confirmBeforeCleaning || askBeforeDeleting
    }

    enum AutoCleanDecision: Equatable {
        /// Begin cleaning right away, without the sheet: the selection is
        /// exactly the preselected safe set and contains nothing destructive.
        case beginImmediately(items: [CleanupItem])
        /// Show Results. `fallbackReason` is non-nil when the user asked for
        /// auto-clean but the selection made it unsafe — the screen says so.
        case showResults(fallbackReason: String?)
    }

    static let nothingSafeFallbackReason =
        "Auto-clean didn't run — nothing was selected automatically."
    static let destructiveFallbackReason =
        "Auto-clean didn't run — the selection includes items that can't be undone. Review them below."

    /// "Automatically clean safe items": after a scan, clean the preselected
    /// set without asking — unless that set is empty or contains anything
    /// destructive (Trash is preselected by design, so a non-empty Trash
    /// always falls back to the normal review flow).
    static func autoCleanDecision(isEnabled: Bool, result: ScanResult) -> AutoCleanDecision {
        guard isEnabled else { return .showResults(fallbackReason: nil) }
        let preselected = result.items.filter { $0.riskLevel.isPreselected && $0.selected }
        guard !preselected.isEmpty else {
            return .showResults(fallbackReason: nothingSafeFallbackReason)
        }
        guard !preselected.contains(where: isDestructive) else {
            return .showResults(fallbackReason: destructiveFallbackReason)
        }
        return .beginImmediately(items: preselected)
    }
}
