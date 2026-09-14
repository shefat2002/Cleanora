import SwiftUI

/// Duplicate finder (M-04): strictly opt-in scope (folders the user adds),
/// one hunt at a time with cancel, grouped result cards (keeper = newest,
/// duplicates unchecked by default) and the shared confirmation sheet before
/// anything moves to Trash.
struct DuplicatesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: DuplicatesViewModel?
    @State private var confirmSheetVisible = false

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if viewModel == nil {
                viewModel = environment.duplicatesFinder()
            }
            if environment.takeDuplicatesReconciliation(), let report = environment.lastCleanupReport {
                viewModel?.reconcile(with: report) { url in
                    FileManager.default.fileExists(atPath: url.path)
                }
            }
        }
        .sheet(isPresented: $confirmSheetVisible) {
            if let viewModel {
                ConfirmCleanSheet(selection: viewModel) { request in
                    environment.markDuplicatesForReconciliation()
                    environment.beginCleaning(request)
                    environment.navigation.go(.cleaning)
                }
            }
        }
    }

    private func content(_ viewModel: DuplicatesViewModel) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 0) {
                scopeSection(viewModel)
                Divider()
                if viewModel.isScanning {
                    progressSection(viewModel)
                } else {
                    resultsSection(viewModel)
                }
            }
            Divider()
            SelectionSummaryBar(
                title: "Move to Trash",
                selectedBytes: viewModel.selectedBytes,
                selectedCount: viewModel.selectedCount,
                canClean: viewModel.canTrash
            ) {
                trashSelected(viewModel)
            }
        }
    }

    private var header: some View {
        VStack(spacing: Design.spacingXS) {
            HStack {
                Button {
                    environment.navigation.go(.dashboard)
                } label: {
                    Label("Dashboard", systemImage: "chevron.left")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to dashboard")
                Spacer()
            }
            .padding(.horizontal, Design.spacingL)
            Text("Duplicate Finder")
                .font(.title2.weight(.bold))
            Text("Pick the folders to search. Nothing is scanned or changed until you start, and duplicates are only moved to the Trash after you review them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Design.spacingL)
                .padding(.bottom, Design.spacingM)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Scope

    private func scopeSection(_ viewModel: DuplicatesViewModel) -> some View {
        VStack(alignment: .leading, spacing: Design.spacingS) {
            HStack {
                Text("Search folders")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.addFolderFromPicker()
                } label: {
                    Label("Add Folder…", systemImage: "plus.circle")
                }
                .disabled(viewModel.isScanning)
                .accessibilityHint("Choose a folder to search for duplicate files.")
            }

            if viewModel.scope.isEmpty {
                Text("No folders selected yet — the finder only searches folders you add here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.scope, id: \.standardizedFileURL.path) { url in
                    HStack(spacing: Design.spacingS) {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text(url.path)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Design.spacingS)
                        Button {
                            viewModel.removeScope(url)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.isScanning)
                        .help("Remove folder from the search")
                        .accessibilityLabel("Remove \(url.lastPathComponent) from the search")
                    }
                    .accessibilityElement(children: .contain)
                }
            }

            HStack(spacing: Design.spacingM) {
                if viewModel.isScanning {
                    Button("Cancel", action: viewModel.cancel)
                        .accessibilityLabel("Cancel duplicate search")
                        .accessibilityHint("Stops the search. Nothing is moved.")
                } else {
                    PrimaryActionButton(
                        title: "Find Duplicates",
                        systemImage: "magnifyingglass",
                        hint: viewModel.canScan
                            ? "Searches the selected folders for identical files. Nothing is moved."
                            : "Add at least one folder to search.",
                        isEnabled: viewModel.canScan
                    ) {
                        viewModel.find()
                    }
                    .controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Design.spacingXS)
        }
        .padding(Design.spacingM)
    }

    // MARK: - Progress / results

    private func progressSection(_ viewModel: DuplicatesViewModel) -> some View {
        VStack(spacing: Design.spacingM) {
            ProgressView()
                .controlSize(.regular)
            if let line = DuplicatesViewModel.progressLine(
                filesExamined: viewModel.filesExamined,
                groupsFound: viewModel.groupsFound
            ) {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Reading folders…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Design.spacingXL)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func resultsSection(_ viewModel: DuplicatesViewModel) -> some View {
        switch viewModel.phase {
        case .failed(let message):
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Search failed",
                message: message.isEmpty
                    ? "Something went wrong while comparing files. Nothing was changed."
                    : message,
                actionTitle: "Try Again"
            ) {
                viewModel.find()
            }
        case .cancelled:
            EmptyStateView(
                systemImage: "minus.circle",
                title: "Search cancelled",
                message: "The search stopped early, so results would be incomplete.",
                actionTitle: "Search Again"
            ) {
                viewModel.find()
            }
        case .finished where viewModel.cards.isEmpty && viewModel.isTruncated:
            // A truncated walk knows nothing for sure — never state a false
            // "none found" (reviewer finding 2).
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Search hit its limit",
                message: "The search stopped before finishing, so results are incomplete. Try a smaller folder or run it again."
            )
        case .finished where viewModel.cards.isEmpty:
            EmptyStateView(
                systemImage: "checkmark.seal",
                title: "No duplicates found",
                message: "The selected folders don't contain identical files above 1 MB."
            )
        case .idle where viewModel.scope.isEmpty:
            EmptyStateView(
                systemImage: "doc.on.doc",
                title: "Pick a folder to begin",
                message: "Cleanora only looks where you tell it to. Add a folder, then run the search."
            )
        default:
            cardsList(viewModel)
        }
    }

    private func cardsList(_ viewModel: DuplicatesViewModel) -> some View {
        ScrollView {
            LazyVStack(spacing: Design.spacingM) {
                if let line = viewModel.lastReconciliationLine {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(line)
                }
                if viewModel.phase == .finished {
                    if viewModel.isTruncated {
                        Text("The search hit its time or size limit — results may be incomplete.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("The search hit its time or size limit, results may be incomplete")
                    }
                    summaryLine(viewModel)
                }
                ForEach(viewModel.cards) { card in
                    cardView(viewModel, card: card)
                }
            }
            .padding(Design.spacingL)
            .frame(maxWidth: Design.contentWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func summaryLine(_ viewModel: DuplicatesViewModel) -> some View {
        Text(
            "\(ResultsViewModelSummary.countLine(viewModel.duplicateCount)) duplicate files in " +
                "\(ResultsViewModelSummary.countLine(viewModel.cards.count)) groups — " +
                "up to \(viewModel.wastedBytes.formattedByteCount) could be saved."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func cardView(
        _ viewModel: DuplicatesViewModel,
        card: DuplicatesViewModel.DuplicateCard
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.spacingM) {
                TriStateCheckButton(
                    state: card.selection,
                    label: "Select all duplicates in this group",
                    action: {
                        viewModel.setCardSelection(
                            card,
                            isSelected: DuplicatesViewModel.targetSelection(for: card.selection)
                        )
                    }
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.keeperURL.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Kept: \(card.keeperURL.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(card.keeperURL.path)
                }
                Spacer(minLength: Design.spacingS)
                Text("\(card.wastedBytes.formattedByteCount) wasted")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(Design.spacingM)
            .accessibilityElement(children: .contain)

            Divider().padding(.leading, Design.spacingM)

            VStack(spacing: 0) {
                ForEach(card.rows) { row in
                    fileRow(viewModel, row: row)
                    Divider()
                        .opacity(0.3)
                        .padding(.leading, Design.spacingL)
                }
            }
            .padding(.bottom, Design.spacingS)
        }
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: Design.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.cornerRadius)
                .strokeBorder(.quaternary)
        )
        .accessibilityElement(children: .contain)
    }

    private func fileRow(
        _ viewModel: DuplicatesViewModel,
        row: DuplicatesViewModel.FileRow
    ) -> some View {
        HStack(spacing: Design.spacingM) {
            if row.isKeeper {
                Label("Kept", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .frame(width: 70, alignment: .leading)
                    .accessibilityLabel("Keeper — newest copy, never removed")
            } else {
                Toggle(isOn: Binding(
                    get: { row.isSelected },
                    set: { viewModel.setSelection($0, forFile: row.url) }
                )) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("\(row.isSelected ? "Deselect" : "Select") \(row.url.lastPathComponent)")
                .accessibilityHint("Moves this copy to the Trash when you confirm.")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.url.path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = row.modificationDate {
                    Text("Modified \(DateFormatting.mediumDate(date))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .help(row.url.path)

            Spacer(minLength: Design.spacingS)

            if row.isKeeper {
                Text("Newest copy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(row.sizeBytes.formattedByteCount)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)

            Button {
                environment.revealInFinder(row.url)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(row.url.lastPathComponent) in Finder")
        }
        .padding(.horizontal, Design.spacingM)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    /// Same gate as every other review surface: the confirmation sheet is
    /// skipped only when both confirmation settings are off. Nothing here can
    /// be destructive (trash move, no Trash-emptying), so I6 is untouched.
    private func trashSelected(_ viewModel: DuplicatesViewModel) {
        if CleaningFlowPolicy.requiresConfirmation(
            confirmBeforeCleaning: environment.preferences.value.confirmBeforeCleaning,
            askBeforeDeleting: environment.preferences.value.askBeforeDeleting,
            items: viewModel.selectedItems
        ) {
            confirmSheetVisible = true
        } else {
            environment.markDuplicatesForReconciliation()
            environment.beginCleaning(AppEnvironment.cleaningRequest(
                for: viewModel.selectedItems,
                scanResultID: viewModel.sourceScanID
            ))
            environment.navigation.go(.cleaning)
        }
    }
}
