import Foundation

/// The testability seam: every path a scanner touches is derived from an
/// injected environment. No scanner may construct filesystem roots directly
/// (no `homeDirectoryForCurrentUser`, no `~` expansion). FileManager is
/// thread-safe for the enumeration calls made here; it is not stored, so the
/// environment stays a plain Sendable value.
public struct ScanEnvironment: Sendable {
    public let home: URL
    public let temporaryRoot: URL
    /// M-06 test seam: replaces the system applications root. Nil = default.
    private let applicationsOverride: URL?

    /// The machine-wide applications folder. It is a SYSTEM location, not
    /// home-derived, so it cannot live in the derived-accessors family above
    /// — the override exists so engine tests never touch the real folder.
    public static let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    public init(home: URL, temporaryRoot: URL, applicationsOverride: URL? = nil) {
        self.home = home
        self.temporaryRoot = temporaryRoot
        self.applicationsOverride = applicationsOverride
    }

    /// Supports the CLEANORA_FIXTURE_HOME QA seam: points the whole engine
    /// at a fixture tree so dangerous flows are exercised without real data.
    /// Refuses non-existent or root-level homes so the seam can't silently
    /// re-aim the allowlist at real system paths.
    public static func live() -> ScanEnvironment {
        if let fixtureHome = ProcessInfo.processInfo.environment["CLEANORA_FIXTURE_HOME"] {
            let home = URL(fileURLWithPath: fixtureHome, isDirectory: true)
            let fm = FileManager.default
            let exists = (try? fm.attributesOfItem(atPath: home.path)) != nil
            let isBareRoot = home.path == "/" || home.standardizedFileURL.pathComponents.count <= 1
            guard exists, !isBareRoot else {
                fatalError(
                    "CLEANORA_FIXTURE_HOME must point to an existing fixture directory, got: \(fixtureHome)"
                )
            }
            return ScanEnvironment(
                home: home,
                temporaryRoot: home.appendingPathComponent("tmp"),
                // The fixture seam re-aims the WHOLE engine at the fixture
                // tree, the applications inventory included — QA must never
                // see the machine's real /Applications while in fixture mode.
                applicationsOverride: home.appendingPathComponent("Applications", isDirectory: true)
            )
        }
        return ScanEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            temporaryRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        )
    }

    public var caches: URL { home.appendingPathComponent("Library/Caches", isDirectory: true) }
    public var logs: URL { home.appendingPathComponent("Library/Logs", isDirectory: true) }
    public var diagnosticReports: URL {
        home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }
    public var applicationSupport: URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
    }
    public var trash: URL { home.appendingPathComponent(".Trash", isDirectory: true) }

    /// M-06: the per-user applications folder, alongside the system-wide
    /// `applications` root.
    public var userApplications: URL {
        home.appendingPathComponent("Applications", isDirectory: true)
    }
    /// M-06: the applications root the inventory scans — the injected
    /// override when one is set, the system folder otherwise.
    public var applications: URL { applicationsOverride ?? Self.systemApplications }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func readable(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }
}
