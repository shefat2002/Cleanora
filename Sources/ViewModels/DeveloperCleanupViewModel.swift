import Foundation
import Observation

/// Owns the Developer Cleanup review (spec §12): scan items with category
/// `.developerData` grouped into tool families — Xcode (DerivedData,
/// Archives, Device Support), Node (npm, Yarn), Python (pip), Homebrew,
/// Docker.
///
/// Every row is review-style: nothing is preselected, ever — producer
/// selection is re-normalized at init the way ResultsViewModel does it.
/// Docker rows lead with their reason text (the prune note), never a bare
/// path, because Docker data is explained rather than blindly removed.
@MainActor
@Observable
final class DeveloperCleanupViewModel {
    struct Row: Identifiable, Equatable {
        let item: CleanupItem
        /// True for Docker-family rows: the reason line renders prominently
        /// under the name instead of hiding behind the info button.
        let isReasonProminent: Bool
        var id: UUID { item.id }
    }

    struct ToolGroup: Identifiable, Equatable {
        let name: String
        let rows: [Row]
        var id: String { name }
        var bytes: Int64 { rows.reduce(0) { $0 + $1.item.size } }
        var selectedBytes: Int64 {
            rows.filter(\.item.selected).reduce(0) { $0 + $1.item.size }
        }
        var selection: TriStateSelection {
            ResultsViewModel.selectionState(of: rows.map(\.item))
        }
    }

    nonisolated static let xcodeGroupName = "Xcode"
    nonisolated static let nodeGroupName = "Node"
    nonisolated static let pythonGroupName = "Python"
    nonisolated static let homebrewGroupName = "Homebrew"
    nonisolated static let dockerGroupName = "Docker"
    nonisolated static let otherGroupName = "Other"

    private(set) var result: ScanResult
    private(set) var groups: [ToolGroup]

    var foundBytes: Int64 { result.items.reduce(0) { $0 + $1.size } }
    var selectedBytes: Int64 { result.selectedBytes }
    var selectedCount: Int { result.selectedItems.count }
    var selectedItems: [CleanupItem] { result.selectedItems }
    var canClean: Bool { selectedBytes > 0 }
    var isEmpty: Bool { result.items.isEmpty }
    var requiresDestructiveConfirmation: Bool {
        result.selectedItems.contains(where: CleaningFlowPolicy.isDestructive)
    }
    var sourceScanID: UUID { result.id }

    init(result: ScanResult) {
        // Nothing preselected (spec §12): developer data is regenerable but
        // rebuilds can be slow, so the user opts into every row.
        let developerItems = result.items
            .filter { $0.category == .developerData }
            .map { $0.withSelection(false) }
        let normalized = ScanResult(
            id: result.id,
            startedAt: result.startedAt,
            finishedAt: result.finishedAt,
            items: developerItems,
            summaries: result.summaries,
            freeSpaceBefore: result.freeSpaceBefore,
            scannerKeys: result.scannerKeys
        )
        self.result = normalized
        self.groups = Self.buildGroups(for: normalized)
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

    func setGroupSelection(_ group: ToolGroup, isSelected: Bool) {
        setSelection(isSelected, itemIDs: Set(group.rows.map(\.id)))
    }

    /// ScanResult.items is immutable; selection mutations rebuild the value
    /// and re-derive the groups so totals can never drift from selection.
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
        groups = Self.buildGroups(for: result)
    }

    // MARK: - Pure builders

    /// Spec §12 layout: keyword matching over the producer's appName, name
    /// and path, so npm/Yarn land in Node and an unrecognized tool still gets
    /// its own group instead of disappearing.
    nonisolated static func toolName(for item: CleanupItem) -> String {
        let haystack = [item.appName ?? "", item.name, item.path.path]
            .joined(separator: " ")
            .lowercased()

        if haystack.contains("xcode") || haystack.contains("deriveddata")
            || haystack.contains("devicesupport") || haystack.contains("coresimulator") {
            return xcodeGroupName
        }
        if haystack.contains("homebrew") || haystack.contains("brew") { return homebrewGroupName }
        if haystack.contains("npm") || haystack.contains("node") || haystack.contains("yarn") {
            return nodeGroupName
        }
        if haystack.contains("pip") || haystack.contains("python") { return pythonGroupName }
        if haystack.contains("docker") { return dockerGroupName }
        return item.appName ?? otherGroupName
    }

    /// Display order: spec §12's tool families first, then anything custom,
    /// alphabetically.
    nonisolated static func sortRank(for toolName: String) -> Int {
        let order = [xcodeGroupName, nodeGroupName, pythonGroupName, homebrewGroupName, dockerGroupName]
        if let index = order.firstIndex(of: toolName) { return index }
        return order.count
    }

    /// Docker rows carry an explanation (the prune note) that must lead the
    /// row — a bare "Docker.raw" path explains nothing.
    nonisolated static func isReasonProminent(for item: CleanupItem) -> Bool {
        toolName(for: item) == dockerGroupName
    }

    nonisolated static func buildGroups(for result: ScanResult) -> [ToolGroup] {
        let byTool = Dictionary(grouping: result.items) { toolName(for: $0) }
        return byTool
            .map { name, items in
                let rows = items
                    .sorted {
                        if $0.size != $1.size { return $0.size > $1.size }
                        return $0.name < $1.name
                    }
                    .map { Row(item: $0, isReasonProminent: isReasonProminent(for: $0)) }
                return ToolGroup(name: name, rows: rows)
            }
            .sorted {
                let rankA = sortRank(for: $0.name)
                let rankB = sortRank(for: $1.name)
                if rankA != rankB { return rankA < rankB }
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.name < $1.name
            }
    }
}

extension DeveloperCleanupViewModel: CleaningSelectionProviding {}
