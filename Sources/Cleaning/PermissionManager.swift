import Foundation
import os

public enum PermissionState: String, Equatable, Sendable {
    /// contentsOfDirectory succeeded.
    case allowed
    /// Enumeration was refused (Full Disk Access not granted / TCC denial).
    case permissionDenied
    /// The canary directory does not exist.
    case missing
}

public struct PermissionStatus: Equatable, Sendable {
    public let caches: PermissionState
    public let logs: PermissionState
    public let trash: PermissionState
    public let safari: PermissionState

    public init(
        caches: PermissionState,
        logs: PermissionState,
        trash: PermissionState,
        safari: PermissionState
    ) {
        self.caches = caches
        self.logs = logs
        self.trash = trash
        self.safari = safari
    }

    /// True only when every canary could actually be read.
    public var isComplete: Bool {
        [caches, logs, trash, safari].allSatisfy { $0 == .allowed }
    }

    /// Areas Cleanora cannot read today — the FDA banner's row list.
    public var deniedAreas: [String] {
        var areas: [String] = []
        if caches != .allowed { areas.append("Caches") }
        if logs != .allowed { areas.append("Logs") }
        if trash != .allowed { areas.append("Trash") }
        if safari != .allowed { areas.append("Safari") }
        return areas
    }
}

/// Read-only Full Disk Access canaries (task K-05). Probes use
/// contentsOfDirectory — TCC blocks enumeration, not stat, so
/// isReadableFile would report false confidence. The deep link stays behind
/// an injected closure: the Cleaning layer must stay UI-free, so the App
/// layer supplies the workspace-open call at construction.
public struct PermissionManager: Sendable {
    private static let log = Logger(subsystem: "com.cleanora.app", category: "permissions")

    public static let fullDiskAccessSettingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    public static var fullDiskAccessSettingsURL: URL? {
        URL(string: fullDiskAccessSettingsURLString)
    }

    private let home: URL
    private let openSettings: @Sendable () -> Void

    public init(home: URL, openSettings: @escaping @Sendable () -> Void) {
        self.home = home
        self.openSettings = openSettings
    }

    private var caches: URL {
        home.appendingPathComponent("Library/Caches", isDirectory: true)
    }

    private var logs: URL {
        home.appendingPathComponent("Library/Logs", isDirectory: true)
    }

    private var trash: URL {
        home.appendingPathComponent(".Trash", isDirectory: true)
    }

    private var safari: URL {
        home.appendingPathComponent("Library/Safari", isDirectory: true)
    }

    public func probe() -> PermissionStatus {
        PermissionStatus(
            caches: probeDirectory(caches, name: "Caches"),
            logs: probeDirectory(logs, name: "Logs"),
            trash: probeDirectory(trash, name: "Trash"),
            safari: probeDirectory(safari, name: "Safari")
        )
    }

    public func openFullDiskAccessSettings() {
        openSettings()
    }

    private func probeDirectory(_ url: URL, name: String) -> PermissionState {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .missing
        }
        do {
            _ = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: []
            )
            return .allowed
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoPermissionError {
                Self.log.notice("permission canary denied for \(name, privacy: .public)")
            } else {
                Self.log.notice(
                    "permission canary failed for \(name, privacy: .public): \(nsError.localizedDescription, privacy: .public)"
                )
            }
            return .permissionDenied
        }
    }
}
