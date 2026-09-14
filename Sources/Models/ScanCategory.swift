import Foundation

public enum ScanCategory: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case applicationCaches
    case browserCaches
    case temporaryFiles
    case logs
    case trash
    case developerData      // Phase 2
    case largeFiles         // Phase 2
    case appLeftovers       // Phase 3 — uninstaller flow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .applicationCaches: return "Application Caches"
        case .browserCaches: return "Browser Caches"
        case .temporaryFiles: return "Temporary Files"
        case .logs: return "Old Logs"
        case .trash: return "Trash"
        case .developerData: return "Developer Data"
        case .largeFiles: return "Large Files"
        case .appLeftovers: return "App Leftovers"
        }
    }

    public var symbolName: String {
        switch self {
        case .applicationCaches: return "shippingbox"
        case .browserCaches: return "globe"
        case .temporaryFiles: return "clock.arrow.circlepath"
        case .logs: return "doc.text"
        case .trash: return "trash"
        case .developerData: return "hammer"
        case .largeFiles: return "doc.badge.gearshape"
        case .appLeftovers: return "shippingbox.and.arrow.backward"
        }
    }

    /// Long-form copy shown by WhyInfoSheet — single source so every surface
    /// renders identical text.
    public var whyText: String { SafetyCopy.why(for: self) }

    /// Emptying the Trash is irreversible; it needs a stronger confirmation
    /// than a cache wipe.
    public var requiresElevatedConfirmation: Bool { self == .trash }

    public var sortOrder: Int {
        switch self {
        case .applicationCaches: return 0
        case .browserCaches: return 1
        case .temporaryFiles: return 2
        case .logs: return 3
        case .trash: return 4
        case .developerData: return 5
        case .largeFiles: return 6
        case .appLeftovers: return 7
        }
    }

    public static var scanOrder: [ScanCategory] {
        allCases.sorted { $0.sortOrder < $1.sortOrder }
    }

    public static var phaseOne: [ScanCategory] {
        [.applicationCaches, .browserCaches, .temporaryFiles, .logs, .trash]
    }
}
