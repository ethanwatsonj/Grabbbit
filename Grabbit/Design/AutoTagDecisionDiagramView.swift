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
            DiagramLegendSwatch(tone: .signal, label: "Input signal")
            DiagramLegendSwatch(tone: .decision, label: "Decision")
            DiagramLegendSwatch(tone: .success, label: "Suggestion")
            DiagramLegendSwatch(tone: .empty, label: "No suggestion")
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
                title: "4. Gemini connected?",
                detail: "Settings → Connect AI (BYOK). If a Gemini key is saved, call vision first with the capture image; Apple Intelligence is next; OCR rules last.",
                tone: .decision
            )
            DiagramArrow(label: "when connected")

            DiagramNode(
                title: "5. Cloud / on-device suggest",
                detail: "Asks for filename (what’s on screen) + project (active product/tab). Schema echoes and empty guesses are discarded. AI proposals are not overwritten by OCR chrome.",
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
                    detail: "Cloud/on-device unclear or placeholders only. Fall through to deterministic rules.",
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
        DiagramNotesCard(title: "Invariants") {
            DiagramNoteRow(text: "Batch evaluator → triage only. Nothing renames or moves itself.")
            DiagramNoteRow(text: "A suggestion is shown only when hasProject is true.")
            DiagramNoteRow(text: "Accept All commits suggestions with confidence ≥ 0.7.")
            DiagramNoteRow(text: "Second Auto Organize click while loading cancels the in-flight batch.")
        }
    }
}
#endif
