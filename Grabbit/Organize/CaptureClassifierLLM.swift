//
//  CaptureClassifierLLM.swift
//  Grabbit
//
//  On-device Foundation Models inference for rename / project / tag suggestions.
//  Prefer pixel input when the SDK exposes multimodal attachments; otherwise feed
//  spatially banded OCR (top chrome first) as the visual proxy.
//

import AppKit
import Foundation
import FoundationModels

@Generable
private struct LLMRenameAndProjectResult {
    @Guide(description: """
        Short descriptive filename without extension. Prefer the active workspace, \
        site, product, or browser/app tab name from the top chrome — not page titles \
        (Design, Parts, Settings), breadcrumbs, or selected tree/list items. Expand \
        compound product names into readable Title Case \
        (e.g. Handwerkercenter → Handwerk Center). \
        Empty string when unclear. Never output the words filename, name, or title.
        """)
    var suggestedName: String

    @Guide(description: """
        Required project or folder name for organizing this capture. Prefer matching an \
        existing project name when one fits. Use the product, codebase, client, brand, \
        or captured app identity from the screenshot — NOT in-app breadcrumbs, page paths \
        (e.g. Extension to North-West › High Performance), or view titles. \
        Empty string when the project cannot be determined. Never output the word project.
        """)
    var suggestedProject: String

    @Guide(description: """
        Optional product flow or screen name (e.g. Checkout, Onboarding, Settings). \
        Empty string when unclear. Never output the word flow.
        """)
    var suggestedFlow: String

    @Guide(description: "Confidence from 0 to 1")
    var confidence: Double
}

enum CaptureClassifierLLM {
    /// Batch evaluate → triage only. Never auto-apply without a user accept.
    static let evaluationMode = "batchEvaluator"

    static var isAvailable: Bool {
        switch taggingModel.availability {
        case .available:
            return true
        case .unavailable:
            return false
        }
    }

    /// Content-tagging use case fits rename/project/flow labeling better than general chat.
    private static var taggingModel: SystemLanguageModel {
        SystemLanguageModel(useCase: .contentTagging)
    }

    static func suggestRenameAndProject(
        image: NSImage,
        windowInfo: WindowSignature?,
        ocrText: String,
        existingProjects: [String] = []
    ) async -> RenameSuggestion? {
        guard isAvailable else { return nil }

        let instructions = """
            You help organize screenshots and screen recordings on macOS for a design annotation app.
            Treat the capture as a UI screenshot: weight top chrome (tabs, title bars, \
            workspace names) over page body, sidebars, and selected list rows.
            Only suggest when you can name a real project from the screenshot and/or \
            captured app. If the project is unclear, leave every field as an empty string \
            — do not guess, and never echo schema words (filename, project, flow, name).
            Read signals carefully, in priority order:
            1) Project (required) — product, brand, client, codebase, or captured app \
            identity. Prefer an existing project name when one clearly matches. Prefer \
            "Resolved project signal" / "Captured app" metadata when they fit. Do not use \
            breadcrumbs or in-page navigation paths.
            2) Filename — active tab / workspace / product name in the top bar. \
            Expand glued compound words into Title Case. Do not use page headings, \
            breadcrumbs, sidebar labels, or selected list rows.
            3) Flow — optional screen or journey label (Parts, Design, Checkout). Empty when unclear.
            Do not invent UI component tags.
            """

        let metadata = promptMetadata(
            image: image,
            windowInfo: windowInfo,
            ocrText: ocrText,
            existingProjects: existingProjects
        )

        do {
            if let multimodal = await respondMultimodalIfAvailable(
                image: image,
                instructions: instructions,
                metadata: metadata
            ) {
                return multimodal
            }

            guard !Task.isCancelled else { return nil }

            let session = LanguageModelSession(model: taggingModel, instructions: instructions)
            let response = try await session.respond(generating: LLMRenameAndProjectResult.self) {
                """
                \(metadata)

                If you can determine the project from the screenshot or captured app, \
                suggest that project plus a short descriptive filename and optional flow. \
                Otherwise return empty strings for every field.
                """
            }
            guard !Task.isCancelled else { return nil }
            return suggestion(from: response.content)
        } catch {
            return nil
        }
    }

    // MARK: - Multimodal (macOS 27+ / SDK with Attachment + OCRTool)

    /// When Foundation Models exposes image attachments + Vision OCRTool, prefer pixels.
    /// Compiles as a no-op on macOS 26 SDKs that lack those types.
    private static func respondMultimodalIfAvailable(
        image: NSImage,
        instructions: String,
        metadata: String
    ) async -> RenameSuggestion? {
        #if GRABBIT_FM_MULTIMODAL
        guard #available(macOS 27.0, *) else { return nil }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let session = LanguageModelSession(
            model: taggingModel,
            tools: [OCRTool()],
            instructions: instructions
        )

        do {
            let response = try await session.respond(generating: LLMRenameAndProjectResult.self) {
                """
                \(metadata)

                Inspect the attached screenshot. Use OCRTool when you need readable \
                text from the image. Prefer visible top chrome over body copy. \
                Only fill fields when the project is clear from the image or app metadata; \
                otherwise leave every field empty.
                """
                Attachment(cgImage)
                    .label("capture")
            }
            return suggestion(from: response.content)
        } catch {
            return nil
        }
        #else
        _ = image
        _ = instructions
        _ = metadata
        return nil
        #endif
    }

    // MARK: - Prompt helpers

    private static func promptMetadata(
        image: NSImage,
        windowInfo: WindowSignature?,
        ocrText: String,
        existingProjects: [String]
    ) -> String {
        var lines: [String] = [
            "Screenshot signals (UI chrome first). Image size: " +
            "\(Int(image.size.width))×\(Int(image.size.height)) px"
        ]

        if let windowTitle = windowInfo?.windowTitle, !windowTitle.isEmpty {
            lines.append("Window title: \(windowTitle)")
        }
        if let project = windowInfo?.resolvedProjectName, !project.isEmpty {
            lines.append("Resolved project signal: \(project)")
        }
        if let app = windowInfo?.dominantAppName ?? windowInfo?.bundleID, !app.isEmpty {
            lines.append("Captured app: \(app)")
        }
        if !existingProjects.isEmpty {
            lines.append(
                "Existing project folders (prefer matching one when appropriate): " +
                existingProjects.prefix(40).joined(separator: ", ")
            )
        }
        if !ocrText.isEmpty {
            lines.append("OCR by vertical band (top → bottom):\n\(ocrText.prefix(3_000))")
        } else {
            lines.append("OCR text: (none detected)")
        }
        return lines.joined(separator: "\n")
    }

    private static func suggestion(from result: LLMRenameAndProjectResult) -> RenameSuggestion? {
        let project = sanitized(result.suggestedProject)
        // Never surface a suggestion until a real project is known.
        guard let project else { return nil }

        let name = sanitized(result.suggestedName)
        let flow = sanitized(result.suggestedFlow)

        return RenameSuggestion(
            suggestedName: name,
            suggestedProject: project,
            suggestedFlow: flow,
            confidence: min(max(result.confidence, 0), 1)
        )
    }

    /// Schema / placeholder echoes the model sometimes emits when uncertain.
    private static let placeholderValues: Set<String> = [
        "filename", "file name", "name", "title", "suggestedname", "suggested name",
        "project", "suggestedproject", "suggested project", "folder", "product",
        "flow", "suggestedflow", "suggested flow", "screen", "tag",
        "none", "null", "nil", "n/a", "na", "unknown", "untitled", "empty",
        "string", "undefined", "screenshot", "screen recording", "grabbit",
    ]

    private static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if placeholderValues.contains(trimmed.lowercased()) { return nil }
        let invalid = CharacterSet(charactersIn: ":/\\")
        let cleaned = trimmed
            .components(separatedBy: invalid)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        guard !cleaned.isEmpty else { return nil }
        if placeholderValues.contains(cleaned.lowercased()) { return nil }
        return String(cleaned.prefix(120))
    }
}
