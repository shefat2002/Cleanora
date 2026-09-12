import Charts
import SwiftUI

/// P-10: one part-to-whole bar — cleanable junk per category (accent), the
/// rest of the used space (gray), and free space (light gray).
///
/// Not color-only, by construction: every mark announces label + value to
/// VoiceOver, the chart carries a one-line spoken summary, and the identity
/// of each segment is restated as text in the legend row and the category
/// list below the bar. Junk segments step the single accent hue by opacity
/// in fixed spec order — one hue family, light→dark, never a generated
/// palette.
struct DiskUsageChartView: View {
    let segments: [DashboardViewModel.DiskSegment]
    let summaryLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingS) {
            bar
            legend
        }
        .accessibilityElement(children: .contain)
    }

    // The mark builder is extracted: the inline Chart closure was too much
    // for the type checker in one expression.
    private var bar: some View {
        Chart {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                segmentMark(index: index, segment: segment)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Disk usage")
        .accessibilityValue(summaryLine ?? "No disk information available")
    }

    private func segmentMark(
        index: Int,
        segment: DashboardViewModel.DiskSegment
    ) -> some ChartContent {
        // One categorical y for all marks: Charts stacks them along the byte
        // axis in ForEach order (junk → used → free).
        let mark = BarMark(
            x: .value("Bytes", segment.bytes),
            y: .value("Disk", "Disk"),
            width: .fixed(24)
        )
        return mark
            .foregroundStyle(color(for: segment, index: index))
            .accessibilityLabel(segment.label)
            .accessibilityValue("\(segment.bytes.formattedByteCount)")
    }

    /// Text legend — color alone never carries identity.
    private var legend: some View {
        HStack(spacing: Design.spacingM) {
            legendChip(color: Color.accentColor, text: "Cleanable")
            legendChip(color: usedColor, text: "Used")
            legendChip(color: freeColor, text: "Free")
            if let summaryLine {
                Spacer(minLength: Design.spacingS)
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption2)
    }

    private func legendChip(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHidden(true) // spoken via the chart summary instead
    }

    // MARK: - Segment colors

    private var usedColor: Color { Color(nsColor: .systemGray) }
    private var freeColor: Color { Color(nsColor: .systemGray).opacity(0.25) }

    /// Junk steps the accent from solid down to 0.4 in category order; used
    /// and free are neutrals. Steps are fixed so a category keeps its step
    /// even when the scan changes the set.
    private func color(for segment: DashboardViewModel.DiskSegment, index: Int) -> Color {
        switch segment.kind {
        case .junk:
            return Color.accentColor.opacity(max(0.4, 1.0 - 0.15 * Double(index)))
        case .otherUsed:
            return usedColor
        case .free:
            return freeColor
        }
    }
}
