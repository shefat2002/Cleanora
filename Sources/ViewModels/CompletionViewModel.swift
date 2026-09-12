import Foundation

/// Pure derivation over the measured cleanup report. Every number on the
/// Completion screen comes from `CleanupReport` (bytesFreed, itemsRemoved,
/// freedBytes(in:), freeSpaceAfter) — nothing is invented or estimated.
struct CompletionViewModel {
    struct CategoryRow: Identifiable, Equatable {
        let category: ScanCategory
        let bytes: Int64
        var id: String { category.rawValue }
    }

    let report: CleanupReport
    /// report.freeSpaceAfter when present; callers may substitute a fresh
    /// disk probe at construction time.
    let freeSpaceAfter: Int64?

    var bytesFreed: Int64 { report.bytesFreed }
    var itemsRemoved: Int { report.itemsRemoved }
    var partiallyRemoved: Int { report.partiallyRemoved }
    var failureCount: Int { report.failureCount }
    /// Free-space refusals and other protective skips arrive as `.skipped`
    /// outcomes with a producer message — never a crash, never silent.
    var skippedCount: Int {
        report.outcomes.filter { $0.status == .skipped }.count
    }
    /// True when the batch was refused/validated out entirely: nothing was
    /// touched, so the celebration must not run.
    var removedNothing: Bool {
        bytesFreed == 0 && itemsRemoved == 0 && partiallyRemoved == 0
    }
    var headline: String { "Your Mac is cleaner" }
    var freedLine: String { "\(bytesFreed.formattedByteCount) freed" }

    /// The first producer-supplied skip reason, or a calm fallback.
    static func refusalMessage(from outcomes: [ItemOutcome]) -> String? {
        guard outcomes.contains(where: { $0.status == .skipped }) else { return nil }
        if let message = outcomes.first(where: { $0.status == .skipped })?.message,
           !message.isEmpty {
            return message
        }
        return "Some items were skipped and left untouched."
    }

    var refusalLine: String? { Self.refusalMessage(from: report.outcomes) }

    var nothingRemovedTitle: String { "Nothing was removed" }

    var nothingRemovedMessage: String {
        refusalLine
            ?? failureLine
            ?? "Every item was left untouched — your files are exactly as they were."
    }

    var categoryRows: [CategoryRow] {
        ScanCategory.scanOrder.compactMap { category in
            let bytes = report.freedBytes(in: category)
            guard bytes > 0 else { return nil }
            return CategoryRow(category: category, bytes: bytes)
        }
    }

    var newFreeSpaceLine: String? {
        guard let freeSpaceAfter else { return nil }
        return "You now have \(freeSpaceAfter.formattedByteCount) available."
    }

    static func itemsRemovedLine(count: Int) -> String {
        switch count {
        case 0: return "No items removed"
        case 1: return "1 item removed"
        default: return "\(count) items removed"
        }
    }

    var itemsRemovedLine: String { Self.itemsRemovedLine(count: itemsRemoved) }

    static func failureLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 item couldn't be removed." : "\(count) items couldn't be removed."
    }

    var failureLine: String? { Self.failureLine(count: failureCount) }
}
