//
//  CaptureClassifierLLM.swift
//  Grabbit
//
//  On-device Foundation Models inference for Auto Organize (rename + project).
//  Prefer pixel input when the SDK exposes multimodal attachments; otherwise feed
//  spatially banded OCR (top chrome first) as the visual proxy.
//

import AppKit
import Foundation
import FoundationModels

@Generable
private struct LLMRenameAndProjectResult {
    @Guide(description: """
        3–7 word filename describing what the screenshot shows IN THE PIXELS, \
        as if renaming it in Finder: product/workspace context plus the main \
        panel, selection, or subject. Prefer visible content (e.g. CLI Droid \
        How To) over host IDE chrome (Agents, Chat Session, New Chat, editor \
        tabs) when that chrome is not the subject. People / portraits: use the \
        visible person name, scene, or call context (e.g. Pam Ritzenthaler Video \
        Call). Good: Handwerk Center Parts, Pam Ritzenthaler Video Call. Bad: \
        Cursor Agents Chat Session, Extension, Design, or the project name alone. \
        MUST differ from suggestedProject when both are filled. Empty only when \
        truly unusable. \
        Never output filename, name, or title.
        """)
    var suggestedName: String

    @Guide(description: """
        Project or folder name for organizing this capture. Prefer a clear \
        in-image product brand (large logo, CLI welcome, product + version) even \
        when Captured app / Window title is Cursor, VS Code, or another host IDE. \
        Otherwise prefer the ACTIVE / selected browser or app tab. Match an \
        existing project name ONLY when it clearly names the same product/workspace \
        as the image; if unsure, propose a new name from the image or leave empty \
        — never pick an unrelated existing folder. Example: active tab \
        Handwerkercenter with inactive Oslo Distr → Handwerkercenter. People / \
        portraits: when the capture is a person, group, call or meeting face, or \
        a clear name overlay, suggest People (or match an existing people-related \
        project if one fits better). NOT inactive tabs, breadcrumbs, sidebar nav, \
        IDE Agents/Chat chrome, or view titles alone. Empty only when truly \
        unusable — clear people content should use People. Never output the word \
        project.
        """)
    var suggestedProject: String

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

    /// Content-tagging use case fits rename/project labeling better than general chat.
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
            Auto Organize means suggesting a filename and a project folder.
            Treat the capture as a UI screenshot when chrome is present. Prefer the \
            ACTIVE / selected tab or workspace in the top chrome over inactive sibling \
            tabs, page body, sidebars, and selected list rows — unless the image shows \
            a clear in-image product brand (large logo, CLI welcome, product name + \
            version); then that brand wins even if Captured app / Window title is \
            Cursor, VS Code, Terminal, or another host IDE.
            Never use sidebar or chrome labels such as Back, Home, Menu, Close, Settings, \
            Introduction, Search, Design, or Parts as the project.
            Never use host IDE Agents / Chat Session / New Chat chrome as the project \
            or filename when the pixels show a different product.
            Leave fields empty only when the capture is truly unusable (blank, pure \
            chrome, no readable subject). Clear people / portrait / name-overlay \
            content is usable — suggest project "People" (or a better-matching \
            existing project) and a descriptive filename. Never echo schema words \
            (filename, project, name).
            Read signals carefully, in priority order:
            1) Project — in-image brand when clear; else active tab / product / \
            brand / client / codebase, or "People" for person / group / call-face / \
            name-overlay captures. Match an existing project name ONLY when it \
            clearly names the same product/workspace as the image; otherwise propose \
            a new name or leave empty — never default to an unrelated folder. Host \
            "Resolved project signal" / "Captured app" are secondary when labeled as \
            host IDE chrome. Do not use inactive tabs, breadcrumbs, sidebar nav, or \
            view titles alone.
            2) Filename — rename from visible content (what a human sees in the \
            pixels), about 3–7 words (product/context + panel or subject; for people \
            use visible name + scene/call context). Good: Handwerk Center Parts, CLI \
            Droid How To, Pam Ritzenthaler Video Call. Bad: Cursor Agents Chat \
            Session, Extension, Design, or copying the project alone. A strong \
            filename alone is still useful when project stays empty.
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
                suggest that project plus a DIFFERENT filename that describes the scene \
                (not a copy of the project). Prefer in-image brand over host IDE chrome \
                when they conflict. Prefer the active tab for the project when it names \
                the pictured product. Match an existing project folder ONLY if it is the \
                same product/workspace; otherwise propose a new name or leave empty. \
                For person / portrait / call-face / name-overlay captures, use \
                project "People" (or a better existing match) and a descriptive \
                person-name filename. A strong filename alone is still useful when \
                the project stays empty. Leave every field empty only when the \
                capture is truly unusable.
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
                text from the image. Prefer a clear in-image product brand over host \
                IDE chrome. Prefer the ACTIVE tab for the project when it names the \
                pictured product. For person / portrait / call-face / name-overlay \
                captures, use project "People" (or a better existing match). Filename \
                must be a 3–7 word description of what the file shows (content, not \
                Agents/Chat chrome), never a single breadcrumb word like Extension. \
                Fill fields whenever the capture is usable; leave empty only when \
                truly unusable.
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

        lines.append(contentsOf: CaptureClassifier.organizePromptHostMetadataLines(
            windowInfo: windowInfo,
            ocrText: ocrText
        ))
        if !existingProjects.isEmpty {
            lines.append(
                "Existing project folders (optional — match ONLY if the same product/workspace as the image; otherwise propose a new name or leave empty): " +
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
        let name = sanitized(result.suggestedName)
        // Allow rename-only when the filename is strong enough (e.g. people portraits).
        let strongRename = name.map(CaptureClassifier.isStrongOrganizeFilename) == true
        guard project != nil || strongRename else { return nil }

        return RenameSuggestion(
            suggestedName: name,
            suggestedProject: project,
            confidence: min(max(result.confidence, 0), 1)
        )
    }

    /// Schema / placeholder echoes the model sometimes emits when uncertain.
    private static let placeholderValues: Set<String> = [
        "filename", "file name", "name", "title", "suggestedname", "suggested name",
        "project", "suggestedproject", "suggested project", "folder", "product",
        "none", "null", "nil", "n/a", "na", "unknown", "untitled", "empty",
        "string", "undefined", "screenshot", "screen recording", "grabbit",
        // Nav / chrome — mirrored from CaptureClassifier so LLM echoes never surface.
        "back", "home", "menu", "close", "cancel", "done", "next", "previous",
        "search", "share", "edit", "more", "settings", "account", "profile",
        "sign in", "log in", "login", "signin", "skip", "continue", "ok", "okay",
        "yes", "no", "introduction", "overview", "contents", "sidebar", "navigation",
        "design", "parts", "requirements", "versions", "simulation", "materials",
        "extension", "extensions",
    ]

    private static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if placeholderValues.contains(trimmed.lowercased()) { return nil }
        if CaptureClassifier.isRejectedOrganizeLabel(trimmed) { return nil }
        let invalid = CharacterSet(charactersIn: ":/\\")
        let cleaned = trimmed
            .components(separatedBy: invalid)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        guard !cleaned.isEmpty else { return nil }
        if placeholderValues.contains(cleaned.lowercased()) { return nil }
        if CaptureClassifier.isRejectedOrganizeLabel(cleaned) { return nil }
        return String(cleaned.prefix(120))
    }
}
