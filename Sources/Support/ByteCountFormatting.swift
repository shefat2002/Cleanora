import Foundation

/// Human byte formatting, decimal SI units ("5.8 GB"), matching the spec's
/// headline numbers. Deterministic across locales: bytes without decimals,
/// everything above one decimal, negatives clamped to zero.
extension Int64 {
    var formattedByteCount: String {
        let bytes = Swift.max(0, self)
        let kilo = 1_000.0
        let value = Double(bytes)

        if bytes < 1_000 {
            return "\(bytes) B"
        }
        if value < kilo * kilo {
            return String(format: "%.1f KB", value / kilo)
        }
        if value < kilo * kilo * kilo {
            return String(format: "%.1f MB", value / (kilo * kilo))
        }
        if value < kilo * kilo * kilo * kilo {
            return String(format: "%.1f GB", value / (kilo * kilo * kilo))
        }
        return String(format: "%.1f TB", value / (kilo * kilo * kilo * kilo))
    }
}
