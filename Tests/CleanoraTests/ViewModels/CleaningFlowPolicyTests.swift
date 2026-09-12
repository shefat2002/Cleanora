import XCTest
@testable import Cleanora

/// P-13 decision logic: when the confirmation sheet may be skipped, and when
/// a finished scan may clean without asking. Both rules only lower friction
/// for non-destructive selections — the destructive cases are the point.
final class CleaningFlowPolicyTests: XCTestCase {
    private func safeItem(name: String = "cache", category: ScanCategory = .applicationCaches) -> CleanupItem {
        VMFixtures.item(name: name, category: category, size: 100, risk: .safe)
    }

    private func trashItem() -> CleanupItem {
        VMFixtures.item(
            name: "Trash",
            category: .trash,
            size: 100,
            risk: .safe,
            confirmationLevel: .destructive
        )
    }

    private func reviewItem() -> CleanupItem {
        VMFixtures.item(name: "Archive", category: .largeFiles, size: 100, risk: .review)
    }

    // MARK: requiresConfirmation

    func testConfirmationShownWhenBothTogglesOn() {
        XCTAssertTrue(CleaningFlowPolicy.requiresConfirmation(
            confirmBeforeCleaning: true, askBeforeDeleting: true, items: [safeItem()]
        ))
    }

    func testConfirmationStillShownWhenEitherToggleRemainsOn() {
        XCTAssertTrue(CleaningFlowPolicy.requiresConfirmation(
            confirmBeforeCleaning: true, askBeforeDeleting: false, items: [safeItem()]
        ))
        XCTAssertTrue(CleaningFlowPolicy.requiresConfirmation(
            confirmBeforeCleaning: false, askBeforeDeleting: true, items: [safeItem()]
        ))
    }

    func testConfirmationSkippedOnlyWhenBothTogglesOff() {
        XCTAssertFalse(CleaningFlowPolicy.requiresConfirmation(
            confirmBeforeCleaning: false, askBeforeDeleting: false, items: [safeItem()]
        ))
    }

    func testDestructiveSelectionAlwaysConfirmsEvenWithBothTogglesOff() {
        // I6: the settings toggles can never lower the destructive gate.
        for confirm in [true, false] {
            for ask in [true, false] {
                XCTAssertTrue(
                    CleaningFlowPolicy.requiresConfirmation(
                        confirmBeforeCleaning: confirm,
                        askBeforeDeleting: ask,
                        items: [safeItem(), trashItem()]
                    ),
                    "destructive selection must confirm (confirm=\(confirm), ask=\(ask))"
                )
            }
        }
    }

    func testDestructiveConfirmationLevelFlagAlsoCounts() {
        let flagged = VMFixtures.item(
            name: "Destructive",
            category: .logs,
            size: 10,
            risk: .safe,
            confirmationLevel: .destructive
        )
        XCTAssertTrue(CleaningFlowPolicy.requiresConfirmation(
            confirmBeforeCleaning: false, askBeforeDeleting: false, items: [flagged]
        ))
    }

    // MARK: autoCleanDecision

    func testAutoCleanDisabledShowsResultsWithoutFallbackReason() {
        let decision = CleaningFlowPolicy.autoCleanDecision(
            isEnabled: false,
            result: VMFixtures.scanResult(items: [safeItem()])
        )
        XCTAssertEqual(decision, .showResults(fallbackReason: nil))
    }

    func testAutoCleanEnabledBeginsWithPreselectedSafeItemsOnly() {
        let safe1 = safeItem(name: "cache1")
        let safe2 = safeItem(name: "cache2", category: .temporaryFiles)
        let review = reviewItem()
        let decision = CleaningFlowPolicy.autoCleanDecision(
            isEnabled: true,
            result: VMFixtures.scanResult(items: [safe1, safe2, review])
        )
        XCTAssertEqual(
            decision,
            .beginImmediately(items: [safe1, safe2]),
            "review items are never part of an auto-clean"
        )
    }

    func testAutoCleanWithTrashPresentFallsBackLoudly() {
        // Trash is preselected by design (risk .safe) — a non-empty Trash must
        // never be auto-emptied.
        let decision = CleaningFlowPolicy.autoCleanDecision(
            isEnabled: true,
            result: VMFixtures.scanResult(items: [safeItem(), trashItem()])
        )
        XCTAssertEqual(decision, .showResults(fallbackReason: CleaningFlowPolicy.destructiveFallbackReason))
    }

    func testAutoCleanWithNothingPreselectedFallsBackLoudly() {
        let decision = CleaningFlowPolicy.autoCleanDecision(
            isEnabled: true,
            result: VMFixtures.scanResult(items: [reviewItem()])
        )
        XCTAssertEqual(decision, .showResults(fallbackReason: CleaningFlowPolicy.nothingSafeFallbackReason))
    }

    func testAutoCleanFallbackReasonsAreNonEmpty() {
        XCTAssertFalse(CleaningFlowPolicy.destructiveFallbackReason.isEmpty)
        XCTAssertFalse(CleaningFlowPolicy.nothingSafeFallbackReason.isEmpty)
    }
}
