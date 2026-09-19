//
//  GeminiAPIOrganizeDiagramView.swift
//  Grabbit
//
//  DEBUG diagram of BYOK Gemini key storage, prompting, and Auto Organize handling.
//

import SwiftUI

#if DEBUG
struct GeminiAPIOrganizeDiagramView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxl) {
                header
                legend
                keyFlow
                requestFlow
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
            Text("Gemini API · Connect AI")
                .font(.grabbit(.panelTitle))
                .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
            Text("How Grabbit stores your Gemini key, builds the vision prompt, and only sends a capture when you run Auto Organize.")
                .font(.grabbit(.body))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            DiagramLegendSwatch(tone: .signal, label: "Local / key")
            DiagramLegendSwatch(tone: .decision, label: "Decision")
            DiagramLegendSwatch(tone: .success, label: "Cloud call")
            DiagramLegendSwatch(tone: .empty, label: "No upload")
        }
    }

    // MARK: - Key storage

    private var keyFlow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Key storage")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)

            VStack(spacing: 0) {
                DiagramNode(
                    title: "1. Settings → Connect AI",
                    detail: "User pastes a Gemini API key from Google AI Studio into the SecureField and taps Save.",
                    tone: .decision
                )
                DiagramArrow()

                DiagramNode(
                    title: "2. Keychain only",
                    detail: "AIConnection writes the trimmed key to Keychain (service ewew.design.Grabbit.ai, account geminiAPIKey). Never UserDefaults, never logs, never bundled.",
                    tone: .signal
                )
                DiagramArrow()

                DiagramNode(
                    title: "3. Connected state",
                    detail: "isCloudConnected is true when Keychain returns a non-empty key. UI shows Connected / Disconnect plus an Apple FM ↔ Gemini provider control whenever Apple FM is available or Gemini is connected (Gemini stays locked until a key is saved). Disconnect deletes the Keychain item; provider preference stays in UserDefaults.",
                    tone: .signal
                )
                DiagramArrow(label: "key stays on device until Auto Organize")

                DiagramNode(
                    title: "Idle · no network",
                    detail: "Saving or disconnecting the key does not call Google. Captures stay on the Mac until the user runs Auto Organize while connected.",
                    tone: .empty
                )
            }
        }
    }

    // MARK: - Request / prompt

    private var requestFlow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Auto Organize request")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)

            VStack(spacing: 0) {
                DiagramNode(
                    title: "4. User taps Auto Organize",
                    detail: "CaptureClassifier uses Gemini only when a key is connected and Settings prefers Gemini; otherwise Apple Intelligence FM, then OCR/rules.",
                    tone: .decision
                )
                DiagramArrow()

                DiagramNode(
                    title: "5. Pack local signals",
                    detail: "JPEG of the capture (image first) + banded Vision OCR + window title / resolved project / existing folder names as secondary hints.",
                    tone: .signal
                )
                DiagramArrow()

                DiagramNode(
                    title: "6. Build the prompt",
                    detail: "Instruct Gemini: project = active product/tab (not inactive siblings); filename = short description of what the file shows that MUST differ from the project (e.g. Handwerkercenter + Handwerk Center Parts). Prefer matching an existing folder when clear.",
                    tone: .decision
                )
                DiagramArrow()

                DiagramNode(
                    title: "7. POST generateContent",
                    detail: "HTTPS to generativelanguage.googleapis.com for gemini-2.0-flash (then 2.5 / 1.5 fallbacks). Header x-goog-api-key = Keychain key. Body: inline JPEG + prompt. responseMimeType JSON with suggestedName, suggestedProject, confidence.",
                    tone: .success
                )
                DiagramArrow(label: "parse + sanitize")

                DiagramNode(
                    title: "8. Accept or fall through",
                    detail: "Drop placeholders and chrome labels. Reject a filename that merely echoes the project; fall back to upper/body OCR scene phrase. If the HTTP call fails or project is empty → Apple Intelligence → deterministic rules.",
                    tone: .decision
                )
                DiagramArrow()

                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    DiagramNode(
                        title: "Present suggestion",
                        detail: "Rename + project row. User accepts, edits, or dismisses — never auto-applied.",
                        tone: .success,
                        compact: true
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    DiagramNode(
                        title: "No usable project",
                        detail: "Show empty / try again. Key stays in Keychain; nothing is moved.",
                        tone: .empty,
                        compact: true
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    // MARK: - Notes

    private var notes: some View {
        DiagramNotesCard(title: "Invariants") {
            DiagramNoteRow(text: "BYOK — Grabbit never ships or proxies a Google key; yours is used only on your Mac.")
            DiagramNoteRow(text: "Upload boundary — the capture image leaves the device only on Auto Organize while Connected.")
            DiagramNoteRow(text: "Prompt priority — look at pixels first; OCR is labeled secondary so inactive tabs don’t win.")
            DiagramNoteRow(text: "Filename ≠ project — duplicate names are rejected so scene text can surface.")
            DiagramNoteRow(text: "Failures are silent to the UI but logged under CaptureClassifierCloud for Console debugging.")
        }
    }
}
#endif
