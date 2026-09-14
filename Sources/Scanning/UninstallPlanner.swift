import Foundation

/// M-06 — plans what removing one application would touch.
///
/// The plan is the app bundle itself plus every related file found by bundle
/// ID under the environment home: caches, preferences, Application Support
/// (by name OR bundle ID), the sandbox container, saved application state,
/// HTTP storages and WebKit data. Every item is `.review` +
/// `.moveToTrash` (recoverable, never preselected) and carries
/// `.appLeftovers` — the flow is informational until the user opts in.
///
/// Honesty note, deliberate: several planned locations (Preferences, the
/// sandbox Containers, /Applications itself) sit OUTSIDE the deletion gate's
/// allowed roots, and the gate will refuse them at cleanup time. They are
/// planned anyway so the user sees the complete footprint; the refusal is
/// real and must be rendered as such, not worked around.
///
/// Whether the app is currently running is a UI concern
/// (`NSRunningApplication`), not an engine one — the planner never probes
/// the process table.
public enum UninstallPlanner {
    public static func plan(for app: InstalledApp, environment: ScanEnvironment) -> [CleanupItem] {
        let home = environment.home
        var items: [CleanupItem] = []
        var seenCanonicalPaths = Set<String>()

        func appendIfNew(_ item: CleanupItem) {
            let canonical = PathNormalizer.canonicalized(item.path).path
            guard seenCanonicalPaths.insert(canonical).inserted else { return }
            items.append(item)
        }

        // The application bundle itself leads the plan.
        appendIfNew(CleanupItem(
            name: app.name,
            appName: app.name,
            category: .appLeftovers,
            path: app.url,
            size: app.bundleSize,
            fileCount: nil,
            riskLevel: .review,
            reason: "The application itself. Moving it to the Trash removes the program; the related files listed below it stay until you remove them too.",
            deletionMethod: .moveToTrash
        ))

        guard let bundleID = app.bundleID, !bundleID.isEmpty else {
            // Without a bundle ID only the name-matched support folder can be
            // correlated — everything else would be a guess.
            if let support = existingTree(
                environment.applicationSupport.appendingPathComponent(app.name),
                environment: environment
            ) {
                appendIfNew(supportItem(support, appName: app.name))
            }
            return items
        }

        if let caches = existingTree(
            environment.caches.appendingPathComponent(bundleID),
            environment: environment
        ) {
            let (bytes, fileCount) = TreeMeasurement.measure(caches)
            appendIfNew(CleanupItem(
                name: caches.lastPathComponent,
                appName: app.name,
                category: .appLeftovers,
                path: caches,
                size: bytes,
                fileCount: fileCount,
                riskLevel: .review,
                reason: "\(app.name)'s cache folder. Regenerated on demand while the app was installed, and unused once it is gone.",
                deletionMethod: .moveToTrash
            ))
        }

        let preferences = home.appendingPathComponent(
            "Library/Preferences/\(bundleID).plist", isDirectory: false
        )
        if environment.exists(preferences) {
            appendIfNew(CleanupItem(
                name: preferences.lastPathComponent,
                appName: app.name,
                category: .appLeftovers,
                path: preferences,
                size: TreeMeasurement.measure(preferences).bytes,
                fileCount: 1,
                riskLevel: .review,
                reason: "\(app.name)'s settings file. Removing it means the app starts fresh if you ever reinstall it.",
                deletionMethod: .moveToTrash
            ))
        }

        // Application Support keeps both spellings: some apps use their name,
        // some their bundle ID, a few use both.
        for folder in [app.name, bundleID] where !folder.isEmpty {
            if let support = existingTree(
                environment.applicationSupport.appendingPathComponent(folder),
                environment: environment
            ) {
                appendIfNew(supportItem(support, appName: app.name))
            }
        }

        if let containers = existingTree(
            home.appendingPathComponent("Library/Containers/\(bundleID)"),
            environment: environment
        ) {
            let (bytes, fileCount) = TreeMeasurement.measure(containers)
            appendIfNew(CleanupItem(
                name: containers.lastPathComponent,
                appName: app.name,
                category: .appLeftovers,
                path: containers,
                size: bytes,
                fileCount: fileCount,
                riskLevel: .review,
                reason: "The sandbox container where \(app.name) kept its data. Cleanora lists it for transparency, but its safety gate never deletes inside Containers — remove it manually if you are sure you no longer need it.",
                deletionMethod: .moveToTrash
            ))
        }

        let savedStateRoot = home.appendingPathComponent("Library/Saved Application State")
        for match in matches(in: savedStateRoot, prefix: "\(bundleID).", environment: environment) {
            let (bytes, fileCount) = TreeMeasurement.measure(match)
            appendIfNew(CleanupItem(
                name: match.lastPathComponent,
                appName: app.name,
                category: .appLeftovers,
                path: match,
                size: bytes,
                fileCount: fileCount,
                riskLevel: .review,
                reason: "Saved window state from \(app.name)'s last sessions. Left behind after uninstalling; safe to remove.",
                deletionMethod: .moveToTrash
            ))
        }

        let httpStoragesRoot = home.appendingPathComponent("Library/HTTPStorages")
        for match in matches(in: httpStoragesRoot, prefix: bundleID, environment: environment) {
            let (bytes, fileCount) = TreeMeasurement.measure(match)
            appendIfNew(CleanupItem(
                name: match.lastPathComponent,
                appName: app.name,
                category: .appLeftovers,
                path: match,
                size: bytes,
                fileCount: fileCount,
                riskLevel: .review,
                reason: "Networking storage (cookies and caches) recorded for \(app.name). Unused once the app is removed.",
                deletionMethod: .moveToTrash
            ))
        }

        if let webkit = existingTree(
            home.appendingPathComponent("Library/WebKit/\(bundleID)"),
            environment: environment
        ) {
            let (bytes, fileCount) = TreeMeasurement.measure(webkit)
            appendIfNew(CleanupItem(
                name: webkit.lastPathComponent,
                appName: app.name,
                category: .appLeftovers,
                path: webkit,
                size: bytes,
                fileCount: fileCount,
                riskLevel: .review,
                reason: "\(app.name)'s website data (stored by the system WebKit framework). Left behind after uninstalling; safe to remove.",
                deletionMethod: .moveToTrash
            ))
        }

        return items
    }

    // MARK: - Helpers

    /// An existing directory-or-file location, returned only when it is
    /// readable — missing files are simply skipped.
    private static func existingTree(
        _ url: URL,
        environment: ScanEnvironment
    ) -> URL? {
        guard environment.exists(url), environment.readable(url) else { return nil }
        return url
    }

    /// Children of `root` whose name starts with `prefix` — the Saved
    /// Application State (`<bundleID>.savedState`) and HTTPStorages
    /// (`<bundleID>`, `<bundleID>.binarycookies`) conventions.
    private static func matches(
        in root: URL,
        prefix: String,
        environment: ScanEnvironment
    ) -> [URL] {
        guard environment.exists(root), environment.readable(root) else { return [] }
        return ((try? FileSystemWalker().children(of: root)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func supportItem(_ url: URL, appName: String) -> CleanupItem {
        let (bytes, fileCount) = TreeMeasurement.measure(url)
        return CleanupItem(
            name: url.lastPathComponent,
            appName: appName,
            category: .appLeftovers,
            path: url,
            size: bytes,
            fileCount: fileCount,
            riskLevel: .review,
            reason: "Support files and data \(appName) stored outside its bundle. Check for anything you still need — this folder can hold user-created content.",
                deletionMethod: .moveToTrash
        )
    }
}
