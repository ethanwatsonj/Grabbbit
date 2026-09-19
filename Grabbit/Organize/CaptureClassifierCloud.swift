//
//  CaptureClassifierCloud.swift
//  Grabbit
//
//  BYOK Gemini vision path for Auto Organize. Used when the user connects an API
//  key in Settings and prefers Gemini over Apple FM — stronger than on-device
//  Foundation Models for project + name. Captures leave the Mac only when the
//  user runs Auto Organize with Gemini selected.
//

import AppKit
import Foundation
import os

enum CaptureClassifierCloud {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Grabbit",
        category: "CaptureClassifierCloud"
    )

    /// Prefer a current Flash model; fall back if the account/region lacks it.
    private static let modelCandidates = [
        "gemini-2.0-flash",
        "gemini-2.5-flash",
        "gemini-1.5-flash",
    ]

    /// True when a Gemini key is connected and Settings prefers Gemini over Apple FM.
    static var isAvailable: Bool {
        AIConnection.prefersEnhancedCloudOrganize
    }

    static func suggestRenameAndProject(
        image: NSImage,
        windowInfo: WindowSignature?,
        ocrText: String,
        existingProjects: [String] = []
    ) async -> RenameSuggestion? {
        guard let apiKey = try? AIConnection.geminiAPIKey(), !apiKey.isEmpty else {
            return nil
        }
        guard let jpeg = jpegBase64(from: image) else {
            logger.error("Gemini organize skipped: could not encode capture JPEG")
            return nil
        }

        let prompt = buildPrompt(
            windowInfo: windowInfo,
            ocrText: ocrText,
            existingProjects: existingProjects
        )

        for modelID in modelCandidates {
            if let suggestion = await requestSuggestion(
                modelID: modelID,
                apiKey: apiKey,
                prompt: prompt,
                jpegBase64: jpeg
            ) {
                return suggestion
            }
        }
        return nil
    }

    // MARK: - Request

    private static func requestSuggestion(
        modelID: String,
        apiKey: String,
        prompt: String,
        jpegBase64: String
    ) async -> RenameSuggestion? {
        let urlString =
            "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 45

        // Image first — Gemini vision guidance prefers media before the instruction text.
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": jpegBase64,
                            ],
                        ],
                        ["text": prompt],
                    ],
                ],
            ],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "OBJECT",
                    "properties": [
                        "suggestedName": [
                            "type": "STRING",
                            "description": "3–7 word filename from visible image content (not IDE Agents/Chat chrome)",
                        ],
                        "suggestedProject": [
                            "type": "STRING",
                            "description": "In-image brand when clear; else active tab or People for portraits. Match existing only if same product",
                        ],
                        "confidence": [
                            "type": "NUMBER",
                            "description": "Confidence from 0 to 1",
                        ],
                    ],
                    "required": ["suggestedName", "suggestedProject", "confidence"],
                ],
            ],
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return nil
            }
            guard (200...299).contains(http.statusCode) else {
                GeminiUsage.recordGenerateContentFailure(http: http, responseBody: data)
                let snippet = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(240) ?? ""
                logger.error(
                    "Gemini \(modelID, privacy: .public) HTTP \(http.statusCode): \(snippet, privacy: .public)"
                )
                return nil
            }
            guard let suggestion = parseSuggestion(from: data) else {
                logger.error("Gemini \(modelID, privacy: .public) returned unusable JSON")
                return nil
            }
            GeminiUsage.recordGenerateContentSuccess(http: http, responseBody: data)
            logger.info(
                "Gemini \(modelID, privacy: .public) project=\(suggestion.suggestedProject ?? "", privacy: .public) name=\(suggestion.suggestedName ?? "", privacy: .public)"
            )
            return suggestion
        } catch {
            logger.error(
                "Gemini \(modelID, privacy: .public) request failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Prompt / parse

    private static func buildPrompt(
        windowInfo: WindowSignature?,
        ocrText: String,
        existingProjects: [String]
    ) -> String {
        var lines: [String] = [
            """
            You help organize screenshots and screen recordings on macOS.
            Look at the attached image first. OCR below is only a secondary hint.
            Return JSON only with suggestedName, suggestedProject, and confidence.

            suggestedProject (when clear):
            - Name the product, client, brand, codebase, or workspace identity \
            visible IN THE IMAGE.
            - If the image shows a clear product brand (large logo, CLI welcome, \
            product name + version), that brand IS the project — even when \
            Captured app / Window title is Cursor, VS Code, Xcode, Terminal, or \
            another host IDE.
            - Prefer the ACTIVE / selected browser or app tab (filled, underlined, \
            or highlighted) when that tab names the pictured product. Ignore \
            inactive sibling tabs.
            - Example: tabs "Handwerkercenter" (active) and "Oslo Distr" (inactive) \
            → suggestedProject = "Handwerkercenter".
            - Match an existing project folder ONLY when it clearly names the same \
            product/workspace as the image. If unsure, propose a NEW name from the \
            image (e.g. Droid, Factory) or leave empty — never default to an \
            unrelated existing folder.
            - People / portraits: when the capture is a person, group, call or \
            meeting face, or a clear on-screen name overlay, suggest project \
            "People" (or match an existing people-related project if one fits \
            better). New folder names like "People" are allowed.
            - Never use sidebar/nav chrome (Back, Home, Settings) or in-app view \
            titles alone (Design, Parts, Requirements, Simulation) as the project.
            - Never use host IDE chrome (Agents, Chat Session, New Chat, editor \
            tabs) as the project when the pixels show a different product.

            suggestedName (filename, no extension):
            - Imagine renaming this screenshot in Finder after looking at it.
            - Describe what is VISIBLE in the image (content / how-to / panel), \
            not host IDE chrome (Agents, New Chat Session, editor tabs) when that \
            chrome is not the subject.
            - Write a short descriptive name: product/workspace context plus the \
            main panel, selection, or subject (about 3–7 words, Title Case).
            - People: use the visible person name, scene, or call context \
            (e.g. "Pam Ritzenthaler Video Call").
            - Good: "Handwerk Center Parts", "CLI Droid How To", \
            "Pam Ritzenthaler Video Call".
            - Bad: "Cursor Agents Chat Session", a single breadcrumb word like \
            "Extension", lone view titles ("Design", "Parts"), inactive tabs, or \
            the project name alone.
            - MUST differ from suggestedProject when both are filled. Never copy \
            only one OCR line.

            Example for a Handwerkercenter Parts screen:
            suggestedProject = "Handwerkercenter"
            suggestedName = "Handwerk Center Parts"

            Example for a face / name-overlay call capture:
            suggestedProject = "People"
            suggestedName = "Pam Ritzenthaler Video Call"

            Leave fields empty only when the capture is truly unusable (blank, \
            pure chrome, no readable subject). Clear people content is usable — \
            do not leave both empty. Never echo schema words.
            """,
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
            lines.append(
                "OCR by vertical band (secondary — trust the image over this):\n" +
                String(ocrText.prefix(3_000))
            )
        } else {
            lines.append("OCR text: (none detected)")
        }
        return lines.joined(separator: "\n")
    }

    private static func parseSuggestion(from data: Data) -> RenameSuggestion? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            return nil
        }

        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let jsonPayload: Data?
        if let direct = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: direct)) != nil {
            jsonPayload = direct
        } else if let extracted = extractJSONObject(from: trimmed) {
            jsonPayload = extracted
        } else {
            jsonPayload = nil
        }

        guard let payload = jsonPayload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            return nil
        }

        let project = sanitized(json["suggestedProject"] as? String)
        let name = sanitized(json["suggestedName"] as? String)
        // Allow rename-only when the filename is strong enough (e.g. people portraits).
        let strongRename = name.map(CaptureClassifier.isStrongOrganizeFilename) == true
        guard project != nil || strongRename else { return nil }

        let confidence: Double
        if let number = json["confidence"] as? Double {
            confidence = number
        } else if let number = json["confidence"] as? Int {
            confidence = Double(number)
        } else if let number = json["confidence"] as? NSNumber {
            confidence = number.doubleValue
        } else {
            confidence = 0.7
        }

        return RenameSuggestion(
            suggestedName: name,
            suggestedProject: project,
            confidence: min(max(confidence, 0), 1)
        )
    }

    private static func extractJSONObject(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(text[start...end]).data(using: .utf8)
    }

    private static let placeholderValues: Set<String> = [
        "filename", "file name", "name", "title", "suggestedname", "suggested name",
        "project", "suggestedproject", "suggested project", "folder", "product",
        "none", "null", "nil", "n/a", "na", "unknown", "untitled", "empty",
        "string", "undefined", "screenshot", "screen recording", "grabbit",
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

    private static func jpegBase64(from image: NSImage) -> String? {
        guard let cgImage = rasterCGImage(from: image) else { return nil }

        let longEdge = max(cgImage.width, cgImage.height)
        let maxEdge = longEdge > 1600 ? 1280 : longEdge
        let compression: CGFloat = longEdge > 1600 ? 0.72 : 0.82

        let scaled = scaledCGImage(cgImage, maxLongEdge: maxEdge) ?? cgImage
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
        else {
            return nil
        }
        return data.base64EncodedString()
    }

    private static func rasterCGImage(from image: NSImage) -> CGImage? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.cgImage
    }

    private static func scaledCGImage(_ image: CGImage, maxLongEdge: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let longest = max(width, height)
        guard longest > maxLongEdge, longest > 0 else { return image }

        let scale = CGFloat(maxLongEdge) / CGFloat(longest)
        let newWidth = max(1, Int((CGFloat(width) * scale).rounded()))
        let newHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }
}
