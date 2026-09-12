import Foundation
import Observation

/// Tri-state checkbox state for a category or app group.
enum TriStateSelection: Equatable {
    case all
    case some
    case none
}

/// Owns the review of one scan result: category sections, app-name grouping
/// with the "Other" rollup, tri-state selection, and instant totals.
///
/// `result` is the single source of truth for selection; sections are pure
/// derivations rebuilt after every mutation, so totals are always consistent
/// with what would be cleaned.
@MainActor
@Observable
final class ResultsViewModel {
    struct AppGroup: Identifiable, Equatable {
        let name: String
        let items: [CleanupItem]
        /// Selecting a group means selecting exactly these items — the set
        /// survives the "Other" rollup, where membership is size-derived.
        let itemIDs: Set<UUID>
        var id: String { name }
        var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
        var selectedBytes: Int64 {
            items.filter(\.selected).reduce(0) { $0 + $1.size }
        }
    }

    struct Section: Identifiable, Equatable {
        let category: ScanCategory
        let items: [CleanupItem]
        /// Empty means the category renders as a flat item list.
        let groups: [AppGroup]
        var id: ScanCategory { category }
        var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
        var selectedBytes: Int64 {
            items.filter(\.selected).reduce(0) { $0 + $1.size }
        }
        var selection: TriStateSelection { ResultsViewModel.selectionState(of: items) }
        /// Category header shows the review badge only when nothing in the
        /// category is auto-selected — otherwise per-item badges carry it.
        var isReviewOnly: Bool {
            !items.isEmpty && items.allSatisfy { $0.riskLevel == .review }
        }
    }

    private(set) var result: ScanResult
    private(set) var sections: [Section]

    var foundBytes: Int64 { result.items.reduce(0) { $0 + $1.size } }
    var reviewBytes: Int64 {
        result.items.filter { $0.riskLevel == .review }.reduce(0) { $0 + $1.size }
    }
    var selectedBytes: Int64 { result.selectedBytes }
    var selectedCount: Int { result.selectedItems.count }
    var selectedItems: [CleanupItem] { result.selectedItems }
    var canClean: Bool { selectedBytes > 0 }
    var isEmpty: Bool { sections.isEmpty || foundBytes == 0 }
    /// Any selected item that cannot be undone: Trash contents or anything
    /// flagged destructive by its producer.
    var requiresDestructiveConfirmation: Bool {
        result.selectedItems.contains {
            $0.category == .trash || $0.confirmationLevel == .destructive
        }
    }

    init(result: ScanResult) {
        // Engine-side selection defaults are re-applied at the UI boundary
        // so a misbehaving producer can never pre-select review items
        // (`.review` is never preselected, invariant from the spec).
        let normalized = ScanResult(
            startedAt: result.startedAt,
            finishedAt: result.finishedAt,
            items: result.items.map { $0.withSelection($0.riskLevel.isPreselected) },
            summaries: result.summaries,
            freeSpaceBefore: result.freeSpaceBefore,
            scannerKeys: result.scannerKeys
        )
        self.result = normalized
        self.sections = Self.buildSections(for: normalized)
    }

    // MARK: - Selection mutations

    func setSelection(_ isSelected: Bool, itemID: UUID) {
        setSelection(isSelected, itemIDs: [itemID])
    }

    func setSelection(_ isSelected: Bool, itemIDs: Set<UUID>) {
        mutateItems { items in
            for index in items.indices where itemIDs.contains(items[index].id) {
                items[index].selected = isSelected
            }
        }
    }

    func setCategorySelection(_ category: ScanCategory, isSelected: Bool) {
        mutateItems { items in
            for index in items.indices where items[index].category == category {
                items[index].selected = isSelected
            }
        }
    }

    /// ScanResult.items is immutable; selection mutations rebuild the value.
    private func mutateItems(_ transform: (inout [CleanupItem]) -> Void) {
        var items = result.items
        transform(&items)
        result = ScanResult(
            id: result.id,
            startedAt: result.startedAt,
            finishedAt: result.finishedAt,
            items: items,
            summaries: result.summaries,
            freeSpaceBefore: result.freeSpaceBefore,
            scannerKeys: result.scannerKeys
        )
        rebuildSections()
    }

    private func rebuildSections() {
        sections = Self.buildSections(for: result)
    }

    // MARK: - Pure builders

    nonisolated static let otherGroupName = "Other"

    /// Sorted stable for display: safe before review, then size descending,
    /// then name. Sorting copies values, so the user's selection travels
    /// with each item untouched.
    nonisolated static func sortedItems(_ items: [CleanupItem]) -> [CleanupItem] {
        items.sorted {
            if $0.riskLevel != $1.riskLevel { return $0.riskLevel < $1.riskLevel }
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.name < $1.name
        }
    }

    /// One section per non-empty category, in spec order.
    nonisolated static func buildSections(for result: ScanResult) -> [Section] {
        ScanCategory.scanOrder.compactMap { category in
            let items = sortedItems(result.items(in: category))
            guard !items.isEmpty else { return nil }
            let groups = appGroups(for: items)
            // Two or more clusters justify a grouping level; one app owning
            // the whole category renders flat.
            return Section(category: category, items: items, groups: groups.count >= 2 ? groups : [])
        }
    }

    /// App-name grouping with the "Other" rollup: named clusters are sorted
    /// by size; any cluster under 5% of the category total — plus items
    /// without an app name — folds into "Other" (placed last) so the list
    /// stays scannable without hiding anything.
    nonisolated static func appGroups(for items: [CleanupItem], rollupFraction: Double = 0.05) -> [AppGroup] {
        guard !items.isEmpty else { return [] }

        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let threshold = Double(total) * rollupFraction

        let namedPairs = Dictionary(grouping: items.filter { $0.appName != nil }, by: \.appName!)
            .map { (name: $0.key, items: sortedItems($0.value)) }
            .sorted {
                if bytes(of: $0.items) != bytes(of: $1.items) {
                    return bytes(of: $0.items) > bytes(of: $1.items)
                }
                return $0.name < $1.name
            }

        var rolledUp = sortedItems(items.filter { $0.appName == nil })
        // A single app owning the category never rolls up; there is nothing
        // to declutter.
        if namedPairs.count > 1 {
            for pair in namedPairs where Double(bytes(of: pair.items)) < threshold {
                rolledUp.append(contentsOf: pair.items)
            }
        }
        let keptPairs = namedPairs.count > 1
            ? namedPairs.filter { Double(bytes(of: $0.items)) >= threshold }
            : namedPairs

        var groups = keptPairs.map { AppGroup(name: $0.name, items: $0.items, itemIDs: Set($0.items.map(\.id))) }
        if !rolledUp.isEmpty {
            groups.append(AppGroup(
                name: otherGroupName,
                items: sortedItems(rolledUp),
                itemIDs: Set(rolledUp.map(\.id))
            ))
        }
        return groups
    }

    nonisolated static func selectionState(of items: [CleanupItem]) -> TriStateSelection {
        if items.isEmpty { return .none }
        let selectedCount = items.filter(\.selected).count
        if selectedCount == items.count { return .all }
        return selectedCount == 0 ? .none : .some
    }

    /// Clicking a tri-state checkbox: `all` clears everything; `some` and
    /// `none` both select everything.
    nonisolated static func targetSelection(for state: TriStateSelection) -> Bool {
        state != .all
    }

    /// ConfirmCleanSheet grouping: selected items clustered by category in
    /// spec order, items sorted largest-first.
    nonisolated static func confirmGroups(
        for items: [CleanupItem]
    ) -> [(category: ScanCategory, items: [CleanupItem])] {
        ScanCategory.scanOrder.compactMap { category in
            let inCategory = sortedItems(items.filter { $0.category == category })
            return inCategory.isEmpty ? nil : (category, inCategory)
        }
    }

    private nonisolated static func bytes(of items: [CleanupItem]) -> Int64 {
        items.reduce(0) { $0 + $1.size }
    }
}
