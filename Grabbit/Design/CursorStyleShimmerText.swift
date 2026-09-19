import SwiftUI

/// Cursor-like generating sheen. Apply to an existing label/field so idle and
/// loading share one renderer (no AppKit ↔ SwiftUI swap that shifts glyphs).
struct CursorStyleShimmerModifier: ViewModifier {
    var isActive: Bool
    var highlightColor: Color = DesignTokens.Color.textPrimary.swiftUI
    /// Overrides VoiceOver while shimmering; `nil` leaves accessibility unchanged.
    var voiceOverLabel: String? = nil

    private static let cycle: TimeInterval = 1.7

    func body(content: Content) -> some View {
        content
            .compositingGroup()
            .overlay {
                if isActive {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let phase = CGFloat(
                            context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
                        )
                        // Sweep from just left of the glyph to just past the right edge.
                        let center = phase * 1.6 - 0.3

                        Rectangle()
                            .fill(highlightColor)
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
                            .blendMode(.sourceAtop)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .modifier(ShimmerAccessibilityModifier(isActive: isActive, label: voiceOverLabel))
    }
}

private struct ShimmerAccessibilityModifier: ViewModifier {
    var isActive: Bool
    var label: String?

    func body(content: Content) -> some View {
        if isActive, let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            content
        }
    }
}

extension View {
    /// Soft sheen while Auto Organize runs — keeps the underlying view’s metrics.
    func cursorStyleShimmer(
        isActive: Bool,
        highlightColor: Color = DesignTokens.Color.textPrimary.swiftUI,
        voiceOverLabel: String? = nil
    ) -> some View {
        modifier(
            CursorStyleShimmerModifier(
                isActive: isActive,
                highlightColor: highlightColor,
                voiceOverLabel: voiceOverLabel
            )
        )
    }
}

/// Convenience for pure SwiftUI `Text` call sites (multi-select, demos).
/// Layout is always a single `Text`; shimmer is overlay-only.
struct CursorStyleShimmerText: View {
    let text: String
    var isShimmering: Bool = true
    var font: Font = .grabbit(.caption)
    var baseColor: Color = DesignTokens.Color.textTertiary.swiftUI
    var highlightColor: Color = DesignTokens.Color.textSecondary.swiftUI
    /// Color when `isShimmering` is false. Defaults to `highlightColor` (idle primary).
    var idleColor: Color? = nil
    var lineLimit: Int? = nil
    var truncationMode: Text.TruncationMode = .tail
    var voiceOverLabel: String? = nil

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(isShimmering ? baseColor : (idleColor ?? highlightColor))
            .lineLimit(lineLimit)
            .truncationMode(truncationMode)
            .cursorStyleShimmer(
                isActive: isShimmering,
                highlightColor: highlightColor,
                voiceOverLabel: isShimmering ? voiceOverLabel : nil
            )
    }
}
