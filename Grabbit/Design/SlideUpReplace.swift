//
//  SlideUpReplace.swift
//  Grabbit
//
//  Restrained slide-up text replace for Auto Organize accept handoff.
//  Old value exits upward; new value enters from below — not a crude fade.
//

import SwiftUI

/// Shared timing for suggestion accept value replace (filename / project).
enum DesignMotion {
    /// Value replace duration — short, ease, no bounce.
    static let suggestionAcceptDuration: TimeInterval = 0.28
    /// Reduced-motion fallback.
    static let suggestionAcceptReducedDuration: TimeInterval = 0.12
    /// Sleep before committing filesystem rename/move so the transition can finish.
    static var suggestionAcceptSettlingNanoseconds: UInt64 {
        UInt64(suggestionAcceptDuration * 1_000_000_000)
    }

    static func suggestionAccept(reduceMotion: Bool) -> Animation {
        if reduceMotion {
            return .easeOut(duration: suggestionAcceptReducedDuration)
        }
        return .easeInOut(duration: suggestionAcceptDuration)
    }

    /// Insert from below / remove upward — reads as the new string replacing the old.
    static func slideUpReplace(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }
}

/// Single-line label that slides up when `text` changes.
struct SlideUpReplacingText: View {
    let text: String
    var font: Font = .grabbit(.caption)
    var color: Color = DesignTokens.Color.textPrimary.swiftUI
    var lineLimit: Int = 1
    var truncationMode: Text.TruncationMode = .middle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
            .truncationMode(truncationMode)
            .id(text)
            .transition(DesignMotion.slideUpReplace(reduceMotion: reduceMotion))
    }
}

/// Clipped slot so outgoing/incoming glyphs don’t spill; animates on `value`.
struct SlideUpReplaceSlot<Content: View>: View {
    let value: String
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            content()
                .id(value)
                .transition(DesignMotion.slideUpReplace(reduceMotion: reduceMotion))
        }
        .animation(DesignMotion.suggestionAccept(reduceMotion: reduceMotion), value: value)
        .clipped()
    }
}
