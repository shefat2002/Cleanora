import Foundation
import Observation

/// Drives the duplicate finder (M-04). Scope is strictly opt-in: the user
/// adds folders through the injected FolderPicker and the scan never touches
/// default roots. Results are grouped cards — keeper (newest file) plus
/// duplicate rows, all unchecked by default — and "Move to Trash" builds
/// CleanupItems for exactly the checked files and runs them through the same
/// confirmation sheet + executor path as every other review.
///
/// Label limitation (documented in the phase report): CleanupItem requires a
/// ScanCategory, and no category means "duplicate file", so trashed
/// duplicates are constructed with category `.largeFiles` (the only category
/// whose safety carve-out admits arbitrary in-home paths) and reason
/// "Duplicate of <keeper>", which is what the confirmation sheet and history
/// will label them.
@MainActor
@Observable
final class DuplicatesViewModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case cancelled
        case failed(String)
    }

    /// One file inside a duplicate group. The keeper row renders without a
    /// checkbox — it is the file the group keeps, never deletable.
    struct FileRow: Identifiable, Equatable {
        let url: URL
        let sizeBytes: Int64
        let modificationDate: Date?
        let isKeeper: Bool
        var isSelected: Bool
        var id: URL { url }
    }

    /// One duplicate group card.
    struct DuplicateCard: Identifiable, Equatable {
        let id: UUID
        let keeperURL: URL
        let wastedBytes: Int64
        var rows: [FileRow]
        var selectedRows: [FileRow] { rows.filter(\.isSelected) }
        var selectedBytes: Int64 { selectedRows.reduce(0) { $0 + $1.sizeBytes } }
        /// Tri-state over the deletable rows only — the keeper never counts.
        var selection: TriStateSelection { DuplicatesViewModel.selectionState(of: rows) }
    }

    /// Engine seam: the exact DuplicateScanner call, injected so tests never
    /// hash real files. `onProgress` carries the engine's full progress
    /// struct, including the truncation flag (a budget/cap-cut walk must not
    /// be reported as a definitive "no duplicates").
    typealias FindDuplicates = @Sendable (
        _ scope: [URL],
        _ options: DuplicateOptions,
        _ onProgress: @escaping @Sendable (DuplicateProgress) -> Void
    ) async throws -> [DuplicateGroup]

    /// Bounds for the duplicate hunt: the engine's 1 MB floor plus a wider
    /// candidate cap and a two-minute budget — the engine returns a partial
    /// result when the budget runs out, never a truncated promise.
    nonisolated static let scanOptions = DuplicateOptions(
        minimumFileSize: 1_000_000,
        fileLimit: 5_000,
        timeBudget: 120
    )

    private(set) var scope: [URL] = []
    private(set) var phase: Phase = .idle
    private(set) var cards: [DuplicateCard] = []
    private(set) var filesExamined = 0
    private(set) var groupsFound = 0
    /// Set when the engine reports the walk was cut short (candidate cap or
    /// time budget) — the UI must then hedge its "no duplicates" copy.
    private(set) var isTruncated = false

    var isScanning: Bool { phase == .scanning }
    var canScan: Bool { !scope.isEmpty && !isScanning }
    var wastedBytes: Int64 { cards.reduce(0) { $0 + $1.wastedBytes } }
    var duplicateCount: Int { cards.reduce(0) { $0 + $1.rows.count } }
    var selectedBytes: Int64 { cards.reduce(0) { $0 + $1.selectedBytes } }
    var selectedCount: Int { cards.reduce(0) { $0 + $1.selectedRows.count } }
    var selectedItems: [CleanupItem] { Self.cleanupItems(for: cards) }
    var canTrash: Bool { selectedBytes > 0 }
    var requiresDestructiveConfirmation: Bool { false }
    var sourceScanID: UUID { sessionID }

    private let sessionID = UUID()
    private let findDuplicates: FindDuplicates
    private let pickFolder: @MainActor () -> URL?
    private let fileSize: (URL) -> Int64?
    private let modificationDate: (URL) -> Date?
    private var task: Task<Void, Never>?

    init(
        findDuplicates: @escaping FindDuplicates,
        pickFolder: @escaping @MainActor () -> URL?,
        fileSize: @escaping (URL) -> Int64? = DuplicatesViewModel.defaultFileSize,
        modificationDate: @escaping (URL) -> Date? = ResultsViewModel.defaultModificationDate
    ) {
        self.findDuplicates = findDuplicates
        self.pickFolder = pickFolder
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }

    convenience init(environment: AppEnvironment) {
        // Captures value copies (scanner + picker + environment value), NOT
        // the environment object, so AppEnvironment can cache this view
        // model across the cleaning round trip without a retain cycle.
        let scanner = DuplicateScanner()
        let picker = environment.folderPicker
        let scanEnvironment = environment.scanEnvironment
        self.init(
            findDuplicates: { scope, options, onProgress in
                try await scanner.findDuplicates(
                    in: scope,
                    options: options,
                    environment: scanEnvironment,
                    onProgress: onProgress
                )
            },
            pickFolder: { picker.pickDirectory() }
        )
    }

    // MARK: - Scope

    /// Adds a folder the user picked. Already-covered scopes are ignored —
    /// a folder inside another scoped folder finds nothing new.
    func addFolderFromPicker() {
        guard let url = pickFolder() else { return }
        addScope(url)
    }

    func addScope(_ url: URL) {
        let standardized = url.standardizedFileURL
        let contained = scope.contains { existing in
            let existingPath = existing.standardizedFileURL.path
            let newPath = standardized.path
            return existingPath == newPath
                || newPath.hasPrefix(existingPath + "/")
                || existingPath.hasPrefix(newPath + "/")
        }
        guard !contained else { return }
        scope.append(standardized)
    }

    func removeScope(_ url: URL) {
        scope.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
    }

    // MARK: - Scan flow

    func find() {
        guard canScan else { return }
        phase = .scanning
        cards = []
        filesExamined = 0
        groupsFound = 0
        isTruncated = false
        let scope = self.scope
        let options = Self.scanOptions
        task = Task { [weak self, findDuplicates = self.findDuplicates, fileSize = self.fileSize, modificationDate = self.modificationDate] in
            let progress: @Sendable (DuplicateProgress) -> Void = { update in
                Task { @MainActor in
                    self?.applyProgress(update)
                }
            }
            guard let self else { return }
            do {
                let groups = try await findDuplicates(scope, options, progress)
                guard !Task.isCancelled else {
                    self.phase = .cancelled
                    return
                }
                self.cards = Self.buildCards(
                    for: groups,
                    fileSize: fileSize,
                    modificationDate: modificationDate
                )
                self.phase = .finished
            } catch is CancellationError {
                self.phase = .cancelled
            } catch {
                self.phase = .failed(Self.failureMessage(for: error))
            }
        }
    }

    /// Cancels discovery; already-found groups are discarded (a partial hunt
    /// would silently under-report duplicates). The engine's time-budget
    /// partial results are different: they arrive as a normal return.
    func cancel() {
        task?.cancel()
    }

    private func applyProgress(_ progress: DuplicateProgress) {
        // Progress hops through a Task and may arrive out of order — clamp so
        // the counters never run backwards. Truncation only ever latches ON.
        filesExamined = max(filesExamined, progress.filesExamined)
        groupsFound = max(groupsFound, progress.duplicateGroupsFound)
        isTruncated = isTruncated || progress.truncated
    }

    // MARK: - Selection

    func setSelection(_ isSelected: Bool, forFile url: URL) {
        mutateRows { row in
            if row.url == url, !row.isKeeper {
                row.isSelected = isSelected
            }
        }
    }

    func setCardSelection(_ card: DuplicateCard, isSelected: Bool) {
        let targets = Set(card.rows.filter { !$0.isKeeper }.map(\.url))
        mutateRows { row in
            if targets.contains(row.url) {
                row.isSelected = isSelected
            }
        }
    }

    private func mutateRows(_ transform: (inout FileRow) -> Void) {
        for cardIndex in cards.indices {
            for rowIndex in cards[cardIndex].rows.indices {
                transform(&cards[cardIndex].rows[rowIndex])
            }
        }
    }

    /// After a cleanup triggered from this screen: drop files the run actually
    /// removed, count what the safety gate refused so the screen can say so.
    func reconcile(with report: CleanupReport, fileExists: (URL) -> Bool) {
        let outcome = Self.reconciling(cards: cards, report: report, fileExists: fileExists)
        cards = outcome.cards
        lastReconciliationLine = Self.reconciliationLine(
            removed: outcome.removedCount,
            refused: outcome.refusedMessages.count,
            freedBytes: outcome.freedBytes,
            refusedMessages: outcome.refusedMessages
        )
    }

    /// One-line status after a trash run from this screen; nil when the run
    /// touched nothing this screen offered.
    private(set) var lastReconciliationLine: String?

    // MARK: - Pure builders

    /// Tri-state over the deletable rows only (keepers excluded).
    nonisolated static func selectionState(of rows: [FileRow]) -> TriStateSelection {
        let selectable = rows.filter { !$0.isKeeper }
        guard !selectable.isEmpty else { return .none }
        let selected = selectable.filter(\.isSelected).count
        if selected == selectable.count { return .all }
        return selected == 0 ? .none : .some
    }

    /// Clicking a tri-state checkbox: `all` clears; `some`/`none` select all.
    nonisolated static func targetSelection(for state: TriStateSelection) -> Bool {
        state != .all
    }

    /// Builds the display cards from engine output. The engine's contract
    /// makes `files[0]` the keeper (newest, ties broken by path), so the UI
    /// trusts it instead of re-stating files — only sizes and dates are
    /// probed here (one stat per file, bounded by the group).
    nonisolated static func buildCards(
        for groups: [DuplicateGroup],
        fileSize: (URL) -> Int64?,
        modificationDate: (URL) -> Date?
    ) -> [DuplicateCard] {
        groups.compactMap { group -> DuplicateCard? in
            guard let keeper = group.files.first, group.files.count >= 2 else { return nil }
            let rows = group.files
                .sorted { lhs, rhs in
                    // Keeper leads; the rest newest-first for scanability.
                    if lhs == keeper { return true }
                    if rhs == keeper { return false }
                    let lhsDate = modificationDate(lhs) ?? .distantPast
                    let rhsDate = modificationDate(rhs) ?? .distantPast
                    if lhsDate != rhsDate { return lhsDate > rhsDate }
                    return lhs.path < rhs.path
                }
                .map { url in
                    FileRow(
                        url: url,
                        sizeBytes: fileSize(url) ?? 0,
                        modificationDate: modificationDate(url),
                        isKeeper: url == keeper,
                        isSelected: false
                    )
                }
            return DuplicateCard(
                id: UUID(),
                keeperURL: keeper,
                wastedBytes: group.totalWastedBytes,
                rows: rows
            )
        }
        .sorted { $0.wastedBytes > $1.wastedBytes }
    }

    /// The CleanupItems for every checked duplicate: `.review` risk, the
    /// recoverable trash method, and the honest "Duplicate of <keeper>"
    /// reason. Category `.largeFiles` is the documented label limitation.
    nonisolated static func cleanupItems(for cards: [DuplicateCard]) -> [CleanupItem] {
        cards.flatMap { card in
            card.selectedRows.map { row in
                CleanupItem(
                    name: row.url.lastPathComponent,
                    category: .largeFiles,
                    path: row.url,
                    size: row.sizeBytes,
                    riskLevel: .review,
                    selected: true,
                    reason: "Duplicate of \(card.keeperURL.lastPathComponent)",
                    deletionMethod: .moveToTrash
                )
            }
        }
    }

    struct Reconciliation: Equatable {
        var cards: [DuplicateCard]
        var removedCount: Int
        var refusedMessages: [String]
        var freedBytes: Int64
    }

    /// Drops checked files the run removed (gone from disk), prunes groups
    /// that fell below two files, and collects refusal messages verbatim.
    nonisolated static func reconciling(
        cards: [DuplicateCard],
        report: CleanupReport,
        fileExists: (URL) -> Bool
    ) -> Reconciliation {
        let removedPaths = Set(
            report.outcomes.filter { $0.status == .removed }.map(\.path)
        )
        let refused = report.outcomes.filter {
            ($0.status == .skipped || $0.status == .failed) && !($0.message ?? "").isEmpty
        }
        var removedCount = 0
        var freed = Int64(0)
        let rebuilt = cards.compactMap { card -> DuplicateCard? in
            let rows = card.rows.filter { row in
                if row.isSelected, removedPaths.contains(row.url.path) {
                    removedCount += 1
                    return false
                }
                // Untouched rows stay only if still on disk.
                return !removedPaths.contains(row.url.path) || fileExists(row.url)
            }
            guard rows.count >= 2 else { return nil }
            return DuplicateCard(
                id: card.id,
                keeperURL: card.keeperURL,
                wastedBytes: card.wastedBytes,
                rows: rows
            )
        }
        for outcome in report.outcomes where removedPaths.contains(outcome.path) {
            freed += outcome.bytesFreed
        }
        return Reconciliation(
            cards: rebuilt,
            removedCount: removedCount,
            refusedMessages: refused.map { $0.message ?? "" },
            freedBytes: freed
        )
    }

    /// Post-run status line: what moved, what was refused, nothing hidden.
    nonisolated static func reconciliationLine(
        removed: Int,
        refused: Int,
        freedBytes: Int64,
        refusedMessages: [String]
    ) -> String? {
        guard removed > 0 || refused > 0 else { return nil }
        var parts: [String] = []
        if removed > 0 {
            parts.append(
                "\(ResultsViewModelSummary.countLine(removed)) moved to Trash, " +
                    "\(freedBytes.formattedByteCount) freed"
            )
        }
        if refused > 0 {
            parts.append("\(refused) refused by the safety gate")
        }
        return parts.joined(separator: " — ") + "."
    }

    /// Progress line while hashing; nil before the walk has reported.
    nonisolated static func progressLine(filesExamined: Int, groupsFound: Int) -> String? {
        guard filesExamined > 0 else { return nil }
        if groupsFound > 0 {
            return "Checked \(filesExamined) files — \(groupsFound) groups found so far…"
        }
        return "Checked \(filesExamined) files…"
    }

    /// Scan failures are shaped for people, never raw exception strings: a
    /// permission problem says what fixes it; anything else says what happened
    /// and that nothing was touched.
    nonisolated static func failureMessage(for error: Error) -> String {
        let permissionDenied =
            (error as? CocoaError)?.code == .fileReadNoPermission
            || (error as? POSIXError)?.code == .EACCES
        if permissionDenied {
            return "Cleanora couldn't read one of the selected folders. Grant Full Disk Access in System Settings and try again."
        }
        return "The search couldn't finish. Nothing was changed — try again, or pick a different folder."
    }

    nonisolated static func defaultFileSize(for url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? Int64
        return size
    }
}

extension DuplicatesViewModel: CleaningSelectionProviding {}
