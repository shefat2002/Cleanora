import Foundation

/// The testability seam: every path a scanner touches is derived from an
/// injected environment. No scanner may construct filesystem roots directly
/// (no `homeDirectoryForCurrentUser`, no `~` expansion). FileManager is
/// thread-safe for the enumeration calls made here; it is not stored, so the
/// environment stays a plain Sendable value.
public struct ScanEnvironment: Sendable {
    public let home: URL
    public let temporaryRoot: URL

    public init(home: URL, temporaryRoot: URL) {
        self.home = home
        self.temporaryRoot = temporaryRoot
    }

    /// Supports the CLEANORA_FIXTURE_HOME QA seam: points the whole engine
    /// at a fixture tree so dangerous flows are exercised without real data.
    public static func live() -> ScanEnvironment {
        if let fixtureHome = ProcessInfo.processInfo.environment["CLEANORA_FIXTURE_HOME"] {
            let home = URL(fileURLWithPath: fixtureHome, isDirectory: true)
            return ScanEnvironment(home: home, temporaryRoot: home.appendingPathComponent("tmp"))
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

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func readable(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }
}
