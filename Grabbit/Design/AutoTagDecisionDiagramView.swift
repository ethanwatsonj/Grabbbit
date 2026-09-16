//
//  AutoTagDecisionDiagramView.swift
//  Grabbit
//
//  DEBUG diagram of how Capture Library Auto Organize picks filename / project.
//

import SwiftUI

#if DEBUG
struct AutoTagDecisionDiagramView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxl) {
                header
                legend
                flowchart
                notes
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(DesignTokens.Color.background.swiftUI)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Auto Organize Decisions")
                .font(.grabbit(.panelTitle))
                .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
            Text("How Capture Library turns a screenshot into a suggested filename and project — suggest only, never auto-apply.")
                .font(.grabbit(.body))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            LegendSwatch(tone: .signal, label: "Input signal")
            LegendSwatch(tone: .decision, label: "Decision")
            LegendSwatch(tone: .success, label: "Suggestion")
            LegendSwatch(tone: .empty, label: "No suggestion")
        }
    }

    // MARK: - Flow

    private var flowchart: some View {
        VStack(spacing: 0) {
            DiagramNode(
                title: "1. Auto Organize",
                detail: "User taps Auto Organize on one or more library captures (batch, concurrency capped at 3).",
                tone: .decision
            )
            DiagramArrow()

            DiagramNode(
                title: "2. Gather signals",
                detail: "Full capture image + window signature from snip time (dominant app, window title, resolved project).",
                tone: .signal
            )
            DiagramArrow()

            DiagramNode(
                title: "3. OCR (banded)",
                detail: "Accurate Vision OCR, top → bottom, labeled TOP_CHROME / UPPER / BODY / FOOTER so tab chrome beats page body.",
                tone: .signal
            )
            DiagramArrow()

            DiagramNode(
                title: "4. Foundation Models available?",
                detail: "On-device content-tagging model. If unavailable, skip straight to step 6.",
                tone: .decision
            )
            DiagramArrow(label: "when available")

            DiagramNode(
                title: "5. LLM suggest",
                detail: "Asks for filename + project. Project is required. Schema echoes (filename / project) and empty guesses are discarded.",
                tone: .decision
            )
            DiagramArrow(label: "has a real project?")

            HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                outcomeColumn(
                    title: "Yes → present",
                    detail: "Show rename + project. User accepts, edits, or dismisses. Done.",
                    tone: .success
                )
                outcomeColumn(
                    title: "No → continue",
                    detail: "LLM unclear or placeholders only. Fall through to deterministic rules.",
                    tone: .decision
                )
            }

            DiagramArrow(label: "deterministic fallbacks · first hit wins")

            DiagramNode(
                title: "6a. Mapping cache",
                detail: "Prior confirmed destination for this window signature.",
                tone: .decision,
                compact: true
            )
            DiagramArrow(label: "miss")
            DiagramNode(
                title: "6b. Resolved project",
                detail: "Workspace / repo / tab project from browser URL, open document, or title.",
                tone: .decision,
                compact: true
            )
            DiagramArrow(label: "miss")
            DiagramNode(
                title: "6c. Rules",
                detail: "Dominant app + window-title parse + OCR heading. Prefer tab/project over bare app when clear.",
                tone: .decision,
                compact: true
            )
            DiagramArrow(label: "any hit?")

            HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                outcomeColumn(
                    title: "Yes → rename + project",
                    detail: "Present rename + project from rules. Still user-confirmed.",
                    tone: .success
                )
                outcomeColumn(
                    title: "No → nothing",
                    detail: "Return nil. Loading ends with no suggestion row — never blank placeholders.",
                    tone: .empty
                )
            }
        }
    }

    private func outcomeColumn(title: String, detail: String, tone: DiagramTone) -> some View {
        DiagramNode(title: title, detail: detail, tone: tone, compact: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Invariants")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            NoteRow(text: "Batch evaluator → triage only. Nothing renames or moves itself.")
            NoteRow(text: "A suggestion is shown only when hasProject is true.")
            NoteRow(text: "Accept All commits suggestions with confidence ≥ 0.7.")
            NoteRow(text: "Second Auto Organize click while loading cancels the in-flight batch.")
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

// MARK: - Pieces

private enum DiagramTone {
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

private struct LegendSwatch: View {
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

private struct DiagramNode: View {
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

private struct DiagramArrow: View {
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

private struct NoteRow: View {
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
#endif
