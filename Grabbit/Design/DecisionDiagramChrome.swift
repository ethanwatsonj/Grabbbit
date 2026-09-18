//
//  DecisionDiagramChrome.swift
//  Grabbit
//
//  Shared flowchart chrome for DEBUG decision diagrams (Auto Organize, Gemini API).
//

import SwiftUI

#if DEBUG
enum DiagramTone {
    case signal, decision, success, empty

    var fill: Color {
        switch self {
        case .signal: return DesignTokens.Color.surface.swiftUI
        case .decision: return DesignTokens.Color.softControlFill.swiftUI
        case .success: return DesignTokens.Color.primary.swiftUI.opacity(0.12)
        case .empty: return DesignTokens.Color.surface.swiftUI
        }
    }

    var border: Color {
        switch self {
        case .signal: return DesignTokens.Color.border.swiftUI
        case .decision: return DesignTokens.Color.softControlBorder.swiftUI
        case .success: return DesignTokens.Color.primary.swiftUI.opacity(0.45)
        case .empty: return DesignTokens.Color.border.swiftUI
        }
    }

    var titleColor: Color {
        switch self {
        case .success: return DesignTokens.Color.primary.swiftUI
        case .empty: return DesignTokens.Color.textSecondary.swiftUI
        default: return DesignTokens.Color.textPrimary.swiftUI
        }
    }
}

struct DiagramLegendSwatch: View {
    let tone: DiagramTone
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(tone.fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(tone.border, lineWidth: 1)
                )
                .frame(width: 14, height: 14)
            Text(label)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
        }
    }
}

struct DiagramNode: View {
    let title: String
    let detail: String
    var tone: DiagramTone = .decision
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : DesignTokens.Spacing.xs) {
            Text(title)
                .font(.grabbit(compact ? .caption : .body))
                .fontWeight(.medium)
                .foregroundStyle(tone.titleColor)
            Text(detail)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, compact ? DesignTokens.Spacing.sm : DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(tone.fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(tone.border, lineWidth: 1)
        )
    }
}

struct DiagramArrow: View {
    var label: String? = nil

    var body: some View {
        VStack(spacing: 2) {
            if let label {
                Text(label)
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                    .padding(.top, 4)
            }
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                .padding(.vertical, 6)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}

struct DiagramNoteRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
            Text(text)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DiagramNotesCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            content()
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Color.surface.swiftUI)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Color.border.swiftUI, lineWidth: 1)
        )
    }
}
#endif
