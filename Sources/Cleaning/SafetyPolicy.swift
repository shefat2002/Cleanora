import Foundation

/// The ONLY gate to deletion. CleanupExecutor must call `validate` for every
/// item immediately before removing it. Paths are canonicalized (symlinks
/// resolved, `/tmp` ↔ `/private/tmp` collapsed) before every comparison.
public struct SafetyPolicy: Sendable {
    public enum Violation: Error, Equatable, Sendable {
        case outsideAllowedRoots(String)
        case blockedPath(String)
        case blockedFragment(String)
        case neverRiskNotAllowed(String)
        case itemNotSelected(String)
        case missingConfirmation(String)
        case destructiveWithoutExplicitConfirm(String)
        case symlinkLeafNotAllowed(String)
    }

    /// Canonicalized at init.
    private let allowedRoots: [String]
    /// Subtrees forbidden even if an allowed root contains them.
    private let excludedRoots: [String]
    private let blockedPaths: [String]
    private let blockedPathFragments: [String]

    public init(
        allowedRoots: [URL],
        blockedPaths: [URL],
        blockedPathFragments: [String],
        excludedRoots: [URL] = []
    ) {
        self.allowedRoots = allowedRoots.map { Self.canonicalized($0).path }
        self.excludedRoots = excludedRoots.map { Self.canonicalized($0).path }
        self.blockedPaths = blockedPaths.map { Self.canonicalized($0).path }
        self.blockedPathFragments = blockedPathFragments
    }

    public static func standard(home: URL, tempRoot: URL) -> SafetyPolicy {
        let appDirs = AppDirectories(home: home)
        return SafetyPolicy(
            allowedRoots: [
                home.appendingPathComponent("Library/Caches", isDirectory: true),
                home.appendingPathComponent("Library/Logs", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/CrashReporter", isDirectory: true),
                tempRoot,
                // Shared temp root — TempScanner only reports user-owned
                // entries, but every entry it produces must validate here.
                URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                home.appendingPathComponent(".Trash", isDirectory: true),
                home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true),
                home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true),
                home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true),
                home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true),
                home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true),
                home.appendingPathComponent(".npm/_cacache", isDirectory: true),
                home.appendingPathComponent("Library/Caches/pip", isDirectory: true),
                home.appendingPathComponent("Library/Caches/Yarn", isDirectory: true),
                home.appendingPathComponent(".yarn/berry/cache", isDirectory: true),
            ],
            blockedPaths: [
                home.appendingPathComponent("Library/Keychains", isDirectory: true),
                home.appendingPathComponent("Library/Mail", isDirectory: true),
                home.appendingPathComponent("Library/Messages", isDirectory: true),
                home.appendingPathComponent("Library/Safari", isDirectory: true),
                home.appendingPathComponent("Library/Metadata", isDirectory: true),
                home.appendingPathComponent("Library/Preferences", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/MobileSync", isDirectory: true),
                home.appendingPathComponent("Library/Mobile Documents", isDirectory: true),
                home.appendingPathComponent("Desktop", isDirectory: true),
                home.appendingPathComponent("Documents", isDirectory: true),
                home.appendingPathComponent("Downloads", isDirectory: true),
                home.appendingPathComponent("Pictures", isDirectory: true),
                home.appendingPathComponent("Music", isDirectory: true),
                home.appendingPathComponent("Movies", isDirectory: true),
                home.appendingPathComponent("Public", isDirectory: true),
                // I10: Cleanora's own Application Support subtree is never a target.
                appDirs.applicationSupport,
            ],
            blockedPathFragments: [
                "Mobile Documents", "Keychains", "MobileSync",
                "iCloud Drive", "com.apple.LaunchServices",
            ],
            // I10: even if some future allowed root overlaps Cleanora's own
            // Application Support subtree, it stays forbidden.
            excludedRoots: [appDirs.applicationSupport]
        )
    }

    /// Resolves symlinks and standardizes so `/tmp/x` and `/private/tmp/x`
    /// compare equal and no `..` survives.
    public func canonicalized(_ url: URL) -> URL {
        Self.canonicalized(url)
    }

    /// realpath()-based canonicalization. Unlike URL.resolvingSymlinksInPath,
    /// this follows top-level symlinks such as /tmp → /private/tmp. Falls
    /// back to resolving the deepest existing ancestor for not-yet-existing
    /// tails (deletion happens after validation, but the tail may be gone).
    static func canonicalized(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL.path
        var buffer = [CChar](repeating: 0, count: 4096)
        if realpath(standardized, &buffer) != nil {
            return URL(fileURLWithPath: String(cString: buffer))
        }

        var suffix: [String] = []
        var probe = URL(fileURLWithPath: standardized)
        while probe.path != "/" && FileManager.default.fileExists(atPath: probe.path) == false {
            suffix.insert(probe.lastPathComponent, at: 0)
            probe = probe.deletingLastPathComponent()
        }
        if realpath(probe.path, &buffer) != nil {
            let real = String(cString: buffer).hasSuffix("/")
                ? String(String(cString: buffer).dropLast())
                : String(cString: buffer)
            return URL(fileURLWithPath: suffix.isEmpty ? real : real + "/" + suffix.joined(separator: "/"))
        }
        return URL(fileURLWithPath: standardized)
    }

    public func validate(
        _ item: CleanupItem,
        confirmed: Set<UUID>,
        destructiveConfirmed: Bool = false
    ) throws {
        // Relative paths resolve against a mutable CWD — never accept them.
        // URL.path normalizes relative input to a leading slash, so use
        // relativePath, which preserves the original form.
        let rawPath = item.path.relativePath
        guard rawPath.hasPrefix("/") else {
            throw Violation.outsideAllowedRoots(rawPath)
        }
        let path = canonicalized(item.path).path

        // Excluded subtrees are forbidden unconditionally — check before the
        // allowlist so a future allowlist overlap can never re-open them.
        if excludedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            throw Violation.blockedPath(path)
        }
        guard allowedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw Violation.outsideAllowedRoots(path)
        }
        if blockedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            throw Violation.blockedPath(path)
        }
        if let fragment = blockedPathFragments.first(where: { path.contains($0) }) {
            throw Violation.blockedFragment(fragment)
        }
        // Symlink-leaf gate (Phase 2 backlog fix): when the validated path's
        // own leaf is a symlink that canonicalization could not resolve — the
        // classic case being a DANGLING link inside an allowed root, which
        // canonicalizes to the link path itself — refuse to hard-delete it.
        // Trashing the link is always safe and recoverable (I7: the target is
        // never touched), so `.trashDirectory` stays allowed. Live links
        // resolve to their target above and never reach this check.
        if item.deletionMethod != .trashDirectory,
           (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            throw Violation.symlinkLeafNotAllowed(path)
        }
        // Defense in depth: CleanupItem's inits (memberwise + Codable) already
        // forbid `.never` (I1).
        guard item.riskLevel != .never else {
            throw Violation.neverRiskNotAllowed(path)
        }
        // Permanent deletion is legal only for auto-selected, regenerable
        // data. Anything the user must review first gets the recoverable
        // trash path.
        if item.deletionMethod == .removeContents && item.riskLevel != .safe {
            throw Violation.neverRiskNotAllowed(path)
        }
        guard item.selected else {
            throw Violation.itemNotSelected(path)
        }
        guard confirmed.contains(item.id) else {
            throw Violation.missingConfirmation(path)
        }
        // I6: Trash emptying needs its own explicit user gesture, not the
        // batch confirmation. A Trash-category item that skipped the
        // `.destructive` marking is rejected outright — the gate never
        // trusts the producer's default.
        if item.category == .trash && item.confirmationLevel != .destructive {
            throw Violation.destructiveWithoutExplicitConfirm(path)
        }
        if item.confirmationLevel == .destructive && !destructiveConfirmed {
            throw Violation.destructiveWithoutExplicitConfirm(path)
        }
    }
}
