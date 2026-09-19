import SwiftUI

/// Muted label with a light sheen sweeping across — Cursor-like generating placeholder.
struct CursorStyleShimmerText: View {
    let text: String
    var font: Font = .grabbit(.caption)
    var baseColor: Color = DesignTokens.Color.textTertiary.swiftUI
    var highlightColor: Color = DesignTokens.Color.textSecondary.swiftUI
    var lineLimit: Int? = nil
    var truncationMode: Text.TruncationMode = .tail
    /// Overrides VoiceOver; defaults to `text`.
    var voiceOverLabel: String? = nil

    private static let cycle: TimeInterval = 1.7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = CGFloat(
                context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
            )
            // Sweep from just left of the glyph to just past the right edge.
            let center = phase * 1.6 - 0.3

            Text(text)
                .font(font)
                .foregroundStyle(baseColor)
                .lineLimit(lineLimit)
                .truncationMode(truncationMode)
                .overlay {
                    Text(text)
                        .font(font)
                        .foregroundStyle(highlightColor)
                        .lineLimit(lineLimit)
                        .truncationMode(truncationMode)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white.opacity(0.35), location: 0.35),
                                    .init(color: .white, location: 0.5),
                                    .init(color: .white.opacity(0.35), location: 0.65),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: UnitPoint(x: center - 0.45, y: 0.5),
                                endPoint: UnitPoint(x: center + 0.45, y: 0.5)
                            )
                        }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel ?? text)
    }
}
