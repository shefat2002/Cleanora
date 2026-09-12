import Foundation

/// Cleanora's own Application Support layout. Also the source of the paths
/// SafetyPolicy excludes from cleaning (invariant I10).
public struct AppDirectories: Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public init(environment: ScanEnvironment) {
        self.home = environment.home
    }

    public var applicationSupport: URL {
        home.appendingPathComponent("Library/Application Support/Cleanora", isDirectory: true)
    }

    /// Write-ahead cleanup logs live here; never a deletion target.
    public var logsDirectory: URL {
        applicationSupport.appendingPathComponent("Logs", isDirectory: true)
    }

    public var historyFile: URL {
        applicationSupport.appendingPathComponent("history.json")
    }

    public func cleanupLogFile(named name: String) -> URL {
        logsDirectory.appendingPathComponent(name)
    }
}
