//
//  CaptureClassifier.swift
//  Grabbit
//
//  Auto-Organize classification: proposes filename + project for a capture.
//  Order: preferred AI (Gemini when connected+selected, else Apple Intelligence FM)
//  → remaining AI fallback → deterministic OCR / app / mapping-cache rules.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Vision

// MARK: - Data model

struct RenameSuggestion: Equatable {
    let suggestedName: String?
    let suggestedProject: String?
    let confidence: Double

    init(
        suggestedName: String?,
        suggestedProject: String?,
        confidence: Double
    ) {
        self.suggestedName = suggestedName
        self.suggestedProject = suggestedProject
        self.confidence = confidence
    }

    var hasRename: Bool {
        guard let suggestedName else { return false }
        return !suggestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasProject: Bool {
        guard let suggestedProject else { return false }
        return !suggestedProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasTags: Bool {
        hasProject
    }
}

struct CaptureSuggestionRequest: Sendable {
    let entry: CaptureEntry
    let image: NSImage
    let windowInfo: WindowSignature?
}

struct CaptureDestination: Codable, Equatable {
    enum Source: String, Codable {
        case windowMetadata
        case ocr
        case localLLM
    }

    let productFolder: String
    let subfolder: String?
    let confidence: Double
    let source: Source
}

struct WindowSignature: Codable, Hashable {
    let bundleID: String?
    let windowTitle: String?
    /// Bundle ID of the app occupying the most capture-rect area (region / full-screen).
    let dominantAppBundleID: String?
    /// Human-readable name for `dominantAppBundleID`.
    let dominantAppName: String?
    /// Project, workspace, or repo name resolved from the dominant app's browser tab URL,
    /// open document, or window title (in that priority order).
    let resolvedProjectName: String?

    init(
        bundleID: String?,
        windowTitle: String?,
        dominantAppBundleID: String? = nil,
        dominantAppName: String? = nil,
        resolvedProjectName: String? = nil
    ) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.dominantAppBundleID = dominantAppBundleID
        self.dominantAppName = dominantAppName
        self.resolvedProjectName = resolvedProjectName
    }

    /// Cache keys intentionally ignore dominant-app / project enrichment so confirmed mappings stay stable.
    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
        hasher.combine(windowTitle)
    }

    static func == (lhs: WindowSignature, rhs: WindowSignature) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.windowTitle == rhs.windowTitle
    }
}

// MARK: - Window geometry snapshot

struct SnapshottedWindow: Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let frame: CGRect
    let title: String?
    /// Position in `CGWindowListCopyWindowInfo` order — lower is more frontmost.
    let stackIndex: Int
}

struct WindowGeometrySnapshot: Sendable {
    let windows: [SnapshottedWindow]
}

struct DominantAppInfo: Sendable {
    let bundleID: String
    let pid: pid_t
    let windowTitle: String?
}

/// Frontmost-app metadata plus an on-screen window snapshot, captured before Grabbit UI takes focus.
struct EarlyCaptureSignals: Sendable {
    let bundleID: String?
    let windowTitle: String?
    let windowSnapshot: WindowGeometrySnapshot
}

// MARK: - Mapping cache (stub)

/// Persists confirmed app/window → folder mappings so future captures short-circuit
/// inference. Written when the user accepts an Auto Organize / project move in Capture Library.
final class CaptureDestinationMappingCache {
    static let shared = CaptureDestinationMappingCache()

    private struct StoredMapping: Codable {
        let bundleID: String?
        let windowTitle: String?
        let productFolder: String
        let subfolder: String?
        let confidence: Double
        let source: CaptureDestination.Source
    }

    private let storageDirectory: URL
    private let manifestURL: URL
    private var mappings: [WindowSignature: CaptureDestination] = [:]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let grabbitRoot = appSupport.appendingPathComponent("Grabbit", isDirectory: true)
        let legacyRoot = appSupport.appendingPathComponent("Snipsnap", isDirectory: true)
        // CaptureHistory also migrates this root; no-op if already moved.
        if FileManager.default.fileExists(atPath: legacyRoot.path),
           !FileManager.default.fileExists(atPath: grabbitRoot.path) {
            try? FileManager.default.moveItem(at: legacyRoot, to: grabbitRoot)
        }
        storageDirectory = grabbitRoot.appendingPathComponent("auto-organize", isDirectory: true)
        manifestURL = storageDirectory.appendingPathComponent("mappings.json")
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        loadFromDisk()
    }

    func destination(for signature: WindowSignature) -> CaptureDestination? {
        mappings[signature]
    }

    /// Capture Library calls this after the user accepts a project suggestion or move.
    func confirm(signature: WindowSignature, destination: CaptureDestination) {
        mappings[signature] = destination
        persist()
    }

    func remove(signature: WindowSignature) {
        guard mappings.removeValue(forKey: signature) != nil else { return }
        persist()
    }

    /// Rewrites cached destinations when the user renames a project folder.
    func renameProductFolder(from oldName: String, to newName: String) {
        var didChange = false
        for (signature, destination) in mappings {
            guard destination.productFolder.caseInsensitiveCompare(oldName) == .orderedSame else {
                continue
            }
            mappings[signature] = CaptureDestination(
                productFolder: newName,
                subfolder: destination.subfolder,
                confidence: destination.confidence,
                source: destination.source
            )
            didChange = true
        }
        if didChange {
            persist()
        }
    }

    // MARK: - Persistence (matches CaptureHistory manifest pattern)

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: manifestURL),
              let stored = try? JSONDecoder().decode([StoredMapping].self, from: data) else {
            return
        }

        mappings = Dictionary(
            uniqueKeysWithValues: stored.map { entry in
                let signature = WindowSignature(bundleID: entry.bundleID, windowTitle: entry.windowTitle)
                let destination = CaptureDestination(
                    productFolder: entry.productFolder,
                    subfolder: entry.subfolder,
                    confidence: entry.confidence,
                    source: entry.source
                )
                return (signature, destination)
            }
        )
    }

    private func persist() {
        let stored = mappings.map { signature, destination in
            StoredMapping(
                bundleID: signature.bundleID,
                windowTitle: signature.windowTitle,
                productFolder: destination.productFolder,
                subfolder: destination.subfolder,
                confidence: destination.confidence,
                source: destination.source
            )
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}

// MARK: - Classifier

enum CaptureClassifier {
    private static let minimumConfidence = 0.5

    /// Frontmost app/window plus on-screen geometry snapshot — call before Grabbit UI takes focus.
    static func gatherEarlyCaptureSignals() -> EarlyCaptureSignals {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        let windowTitle = focusedWindowTitle(pid: app?.processIdentifier)
        let snapshot = snapshotOnScreenWindows()
        return EarlyCaptureSignals(bundleID: bundleID, windowTitle: windowTitle, windowSnapshot: snapshot)
    }

    /// Enriches early signals with dominant-app overlap and project resolution once the capture rect is known.
    static func completeWindowSignature(from early: EarlyCaptureSignals, captureRect: CGRect?) -> WindowSignature {
        let dominant = captureRect.flatMap { dominantApp(in: $0, snapshot: early.windowSnapshot) }
        let dominantName = dominant.flatMap { resolveAppName(bundleID: $0.bundleID) }
        let projectName = dominant.flatMap {
            resolveProjectName(
                pid: $0.pid,
                bundleID: $0.bundleID,
                windowTitle: $0.windowTitle,
                productName: dominantName
            )
        }

        return WindowSignature(
            bundleID: early.bundleID,
            windowTitle: early.windowTitle,
            dominantAppBundleID: dominant?.bundleID,
            dominantAppName: dominantName,
            resolvedProjectName: projectName
        )
    }

    /// Library inline suggestion: rename file + project folder.
    /// Falls back to the deterministic chain when Foundation Models is unavailable
    /// (still suggests rename + project when signals are strong enough).
    static func suggestRenameAndProject(for request: CaptureSuggestionRequest) async -> RenameSuggestion? {
        let work = Task.detached(priority: .utility) {
            await suggestRenameAndProjectImpl(request: request)
        }
        return await withTaskCancellationHandler {
            let result = await work.value
            guard !Task.isCancelled else { return nil }
            return result
        } onCancel: {
            work.cancel()
        }
    }

    static func imageForClassification(from entry: CaptureEntry) -> NSImage? {
        switch entry.item {
        case .screenshot:
            return CaptureHistory.shared.fullImage(for: entry.id)
        case .recording(_, let thumbnail):
            return thumbnail
        }
    }

    // MARK: - Pipeline

    private static func suggestRenameAndProjectImpl(request: CaptureSuggestionRequest) async -> RenameSuggestion? {
        guard !Task.isCancelled else { return nil }

        let signature = request.windowInfo ?? WindowSignature(bundleID: nil, windowTitle: nil)
        // Accurate + spatially sorted OCR so top chrome (tabs/workspace) beats page body.
        let ocrText = await recognizeText(in: request.image, accurate: true)
        guard !Task.isCancelled else { return nil }

        let existingProjects = CaptureLibraryOrganizer.existingProjectNames()
        let contentSubject = imageSubjectPhrase(windowInfo: signature, ocrText: ocrText)
        // Body/upper OCR for filenames — never tab chrome (that belongs in project).
        let sceneSubject = extractScenePhrase(from: ocrText)

        // Preferred provider first. Gemini only when connected and selected in Settings;
        // otherwise (or when Apple FM is selected) try on-device Foundation Models.
        let preferCloud = CaptureClassifierCloud.isAvailable
        if preferCloud {
            if let cloud = await CaptureClassifierCloud.suggestRenameAndProject(
                image: request.image,
                windowInfo: request.windowInfo,
                ocrText: ocrText,
                existingProjects: existingProjects
            ), cloud.hasProject || cloud.hasRename {
                return finalizeSuggestion(
                    proposedProject: cloud.suggestedProject,
                    proposedName: cloud.suggestedName,
                    contentSubject: contentSubject,
                    sceneSubject: sceneSubject,
                    windowInfo: signature,
                    ocrText: ocrText,
                    existingProjects: existingProjects,
                    entry: request.entry,
                    confidence: cloud.confidence,
                    preferAIProposal: true
                )
            }
            guard !Task.isCancelled else { return nil }
        }

        // Free on-device Apple Intelligence when available (primary when Gemini is
        // disconnected or Settings prefers Apple FM; fallback when Gemini fails).
        if CaptureClassifierLLM.isAvailable {
            if let llm = await CaptureClassifierLLM.suggestRenameAndProject(
                image: request.image,
                windowInfo: request.windowInfo,
                ocrText: ocrText,
                existingProjects: existingProjects
            ), llm.hasProject || llm.hasRename {
                return finalizeSuggestion(
                    proposedProject: llm.suggestedProject,
                    proposedName: llm.suggestedName,
                    contentSubject: contentSubject,
                    sceneSubject: sceneSubject,
                    windowInfo: signature,
                    ocrText: ocrText,
                    existingProjects: existingProjects,
                    entry: request.entry,
                    confidence: llm.confidence,
                    preferAIProposal: true
                )
            }
            guard !Task.isCancelled else { return nil }
        }

        // Deterministic path — only surface once a project is known from
        // mapping cache, resolved workspace, or OCR/title/app rules.
        // Skip a sticky cache hit when OCR shows a different product brand
        // (e.g. Cursor Agents title cached as "Designer Portfolios" on a DROID shot).
        if let cached = CaptureDestinationMappingCache.shared.destination(for: signature),
           !cachedProjectConflictsWithOCR(productFolder: cached.productFolder, ocrText: ocrText) {
            return finalizeSuggestion(
                proposedProject: cached.productFolder,
                proposedName: sceneSubject ?? contentSubject,
                contentSubject: contentSubject,
                sceneSubject: sceneSubject,
                windowInfo: signature,
                ocrText: ocrText,
                existingProjects: existingProjects,
                entry: request.entry,
                confidence: cached.confidence
            )
        }

        if let project = signature.resolvedProjectName.flatMap({ sanitizedFolderName($0) }) {
            return finalizeSuggestion(
                proposedProject: project,
                proposedName: sceneSubject ?? contentSubject,
                contentSubject: contentSubject,
                sceneSubject: sceneSubject,
                windowInfo: signature,
                ocrText: ocrText,
                existingProjects: existingProjects,
                entry: request.entry,
                confidence: 0.8
            )
        }

        if let ruleResult = classifyWithRules(windowInfo: signature, ocrText: ocrText) {
            return finalizeSuggestion(
                proposedProject: ruleResult.productFolder,
                proposedName: sceneSubject ?? contentSubject,
                contentSubject: contentSubject,
                sceneSubject: sceneSubject,
                windowInfo: signature,
                ocrText: ocrText,
                existingProjects: existingProjects,
                entry: request.entry,
                confidence: ruleResult.confidence
            )
        }

        // Still unclear — finish with no suggestion rather than presenting
        // empty filename / project placeholders.
        return nil
    }

    /// Reconcile project against existing folders, build an image-true unique filename.
    /// When `preferAIProposal` is true (Gemini / Apple Intelligence), keep the model’s
    /// project and only remap onto an existing folder — don’t let OCR chrome win.
    /// Filenames that merely echo the project are rejected in favor of a scene phrase.
    private static func finalizeSuggestion(
        proposedProject: String?,
        proposedName: String?,
        contentSubject: String?,
        sceneSubject: String?,
        windowInfo: WindowSignature,
        ocrText: String,
        existingProjects: [String],
        entry: CaptureEntry,
        confidence: Double,
        preferAIProposal: Bool = false
    ) -> RenameSuggestion? {
        let candidates: [String]
        if preferAIProposal {
            candidates = proposedProject.flatMap { sanitizedFolderName($0) }.map { [$0] } ?? []
        } else {
            candidates = projectCandidates(windowInfo: windowInfo, ocrText: ocrText, seed: proposedProject)
        }
        guard let project = reconcileProject(
            proposed: proposedProject,
            candidates: candidates,
            existingProjects: existingProjects
        ) else {
            // Rename-only: surface a strong filename even when project stays empty
            // (e.g. people portraits before People is inferred).
            return renameOnlySuggestion(
                proposedName: proposedName,
                sceneSubject: sceneSubject,
                contentSubject: preferAIProposal ? nil : contentSubject,
                entry: entry,
                confidence: confidence
            )
        }

        let subject = preferredFilenameSubject(
            proposedName: proposedName,
            sceneSubject: sceneSubject,
            contentSubject: preferAIProposal ? nil : contentSubject,
            project: project
        )
        let uniqueName = subject.flatMap {
            uniqueCaptureBaseName(
                subject: $0,
                project: project,
                currentName: entry.displayName,
                excluding: entry.id
            )
        }

        return RenameSuggestion(
            suggestedName: uniqueName,
            suggestedProject: project,
            confidence: confidence
        )
    }

    /// Filename-only suggestion when project reconciliation yields nothing.
    private static func renameOnlySuggestion(
        proposedName: String?,
        sceneSubject: String?,
        contentSubject: String?,
        entry: CaptureEntry,
        confidence: Double
    ) -> RenameSuggestion? {
        let subject = preferredFilenameSubject(
            proposedName: proposedName,
            sceneSubject: sceneSubject,
            contentSubject: contentSubject,
            project: ""
        )
        guard let subject, isStrongOrganizeFilename(subject) else { return nil }
        let uniqueName = uniqueCaptureBaseName(
            subject: subject,
            project: "",
            currentName: entry.displayName,
            excluding: entry.id
        )
        guard let uniqueName else { return nil }
        return RenameSuggestion(
            suggestedName: uniqueName,
            suggestedProject: nil,
            confidence: confidence
        )
    }

    /// Subject visible in the capture — prefer tab / workspace chrome over in-page view titles.
    /// When the window title is IDE chrome (Agents / Chat Session / New Chat), prefer OCR.
    private static func imageSubjectPhrase(windowInfo: WindowSignature, ocrText: String) -> String? {
        let ocrHeading = extractHeading(from: ocrText)
            .flatMap { sanitizedFolderName($0) }
            .flatMap { isRejectedOrganizeLabel($0) ? nil : $0 }

        if let title = windowInfo.windowTitle, isIDEChromeWindowTitle(title), let ocrHeading {
            return ocrHeading
        }

        let product = resolveProductFolder(from: windowInfo)
        if let title = windowInfo.windowTitle,
           !isIDEChromeWindowTitle(title),
           let parsed = parseWindowTitle(
               title,
               productHint: product,
               bundleID: windowInfo.dominantAppBundleID ?? windowInfo.bundleID
           ),
           !isRejectedOrganizeLabel(parsed),
           let sanitized = sanitizedFolderName(parsed) {
            return sanitized
        }

        if let project = windowInfo.resolvedProjectName.flatMap({ sanitizedFolderName($0) }),
           !isRejectedOrganizeLabel(project) {
            return project
        }

        return ocrHeading
    }

    /// On-screen scene for filenames: upper/body OCR, not tab chrome.
    /// Prefer concrete multi-word labels (Carousel Ports) over breadcrumb stubs
    /// truncated from lines like "Extension to North-West > High Performance".
    private static func extractScenePhrase(from ocrText: String) -> String? {
        let bands = parseOCRBands(ocrText)
        let pools = [bands.upperContent, bands.body, bands.unbanded]
        for pool in pools {
            if let phrase = firstGoodScenePhrase(in: pool) {
                return phrase
            }
        }
        return nil
    }

    /// Scene-oriented pick: multi-word first; never a lone breadcrumb fragment.
    private static func firstGoodScenePhrase(in lines: [String]) -> String? {
        var bestMulti: (phrase: String, score: Double)?

        for line in lines {
            let cleaned = sceneLineForFilename(line)
            guard let cleaned, isPlausibleHeadingLine(cleaned) else { continue }
            guard let extracted = productPhraseDetails(from: cleaned, maxWords: 6) else { continue }
            let phrase = extracted.phrase
            let wordCount = phrase.split(whereSeparator: { $0.isWhitespace }).count
            guard wordCount >= 2, !isWeakFilenameSuggestion(phrase) else { continue }

            let score = Double(min(cleaned.count, 100))
                + (wordCount >= 3 ? 20 : 0)
                + (extracted.fromHeadline ? 5 : 15) // prefer concrete list labels over truncated headlines
            if bestMulti == nil || score > bestMulti!.score {
                bestMulti = (phrase, score)
            }
        }
        return bestMulti?.phrase
    }

    /// Drop breadcrumb tails after ">" and trim path noise for filename OCR.
    private static func sceneLineForFilename(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: ">") {
            // Prefer the most specific breadcrumb segment when present.
            let parts = text
                .components(separatedBy: ">")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            text = parts.last ?? text
        }
        // Skip lines that are only a preposition-led fragment after truncation risk.
        return text.isEmpty ? nil : text
    }

    private static func preferredFilenameSubject(
        proposedName: String?,
        sceneSubject: String?,
        contentSubject: String?,
        project: String
    ) -> String? {
        if let proposed = proposedName.flatMap({ sanitizedFolderName($0) }),
           isStrongFilenameSuggestion(proposed, project: project) {
            return proposed
        }
        if let scene = sceneSubject.flatMap({ sanitizedFolderName($0) }),
           isStrongFilenameSuggestion(scene, project: project) {
            return enrichedSceneFilename(scene: scene, project: project)
        }
        // Weak AI/OCR crumbs (e.g. "Extension") — still try to compose a usable name.
        if let scene = sceneSubject.flatMap({ sanitizedFolderName($0) }),
           !filenameEchoesProject(scene, project: project),
           !isRejectedOrganizeLabel(scene) {
            let enriched = enrichedSceneFilename(scene: scene, project: project)
            if isStrongFilenameSuggestion(enriched, project: project) {
                return enriched
            }
        }
        if let content = contentSubject.flatMap({ sanitizedFolderName($0) }),
           isStrongFilenameSuggestion(content, project: project) {
            return content
        }
        // Last resort: readable project + best non-echo scene token if we have one.
        if let scene = sceneSubject.flatMap({ sanitizedFolderName($0) }),
           !filenameEchoesProject(scene, project: project),
           !isRejectedOrganizeLabel(scene),
           let readable = readableProjectPhrase(project) {
            let combined = sanitizedFolderName("\(readable) \(scene)")
            if let combined, isStrongFilenameSuggestion(combined, project: project) {
                return combined
            }
        }
        return nil
    }

    private static func isStrongFilenameSuggestion(_ name: String, project: String) -> Bool {
        guard !isRejectedOrganizeLabel(name) else { return false }
        guard !filenameEchoesProject(name, project: project) else { return false }
        guard !isWeakFilenameSuggestion(name) else { return false }
        return true
    }

    /// Single breadcrumb/view words that look like OCR crumbs, not Finder renames.
    private static let weakFilenameLabels: Set<String> = [
        "extension", "extensions", "north", "west", "east", "south",
        "high", "performance", "low", "draft", "final", "copy", "new",
        "untitled", "image", "photo", "capture", "screen", "window",
        "orange", "blue", "red", "green", "yellow", "black", "white",
        "ports", "port", "point", "points", "item", "items", "row", "rows",
        "panel", "page", "section", "tab", "view", "mode",
    ]

    /// Media tokens that are fine inside a descriptive people/scene rename
    /// (e.g. "Pam Ritzenthaler Photo") but weak alone or as an all-media phrase.
    private static let softMediaFilenameTokens: Set<String> = [
        "photo", "image", "portrait", "picture",
    ]

    /// Shared with Cloud / LLM sanitize so rename-only suggestions can pass.
    static func isStrongOrganizeFilename(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isRejectedOrganizeLabel(trimmed) else { return false }
        return !isWeakFilenameSuggestion(trimmed)
    }

    private static func isWeakFilenameSuggestion(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        if weakFilenameLabels.contains(lower) { return true }
        if isRejectedOrganizeLabel(trimmed) { return true }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        if words.count < 2 { return true }

        let lowers = words.map { $0.lowercased() }
        let chromeCount = lowers.filter { chromeNavLabels.contains($0) }.count
        if chromeCount == words.count { return true }

        // Soft media tokens ("photo", "image") don't doom a descriptive rename
        // when other words carry meaning — keep blocking chrome/nav-only phrases.
        let descriptiveCount = lowers.filter {
            !weakFilenameLabels.contains($0)
                && !chromeNavLabels.contains($0)
                && !softMediaFilenameTokens.contains($0)
        }.count
        if descriptiveCount >= 1 { return false }

        // All tokens are weak and/or soft media (e.g. "Image Photo", "Photo Capture").
        return true
    }

    /// True when the filename is just the project (or a trivial rewrite of it).
    private static func filenameEchoesProject(_ name: String, project: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !p.isEmpty else { return false }
        if n.caseInsensitiveCompare(p) == .orderedSame { return true }

        let nCompact = n.lowercased().filter { $0.isLetter || $0.isNumber }
        let pCompact = p.lowercased().filter { $0.isLetter || $0.isNumber }
        if !nCompact.isEmpty, nCompact == pCompact { return true }

        let nTokens = significantTokens(n)
        let pTokens = significantTokens(p)
        if !nTokens.isEmpty, nTokens == pTokens { return true }
        return false
    }

    /// Prefer a scene phrase; if it doesn't already mention the project, optionally
    /// prefix a short readable project form for names like "Handwerk Center Parts".
    private static func enrichedSceneFilename(scene: String, project: String) -> String {
        let sceneTokens = significantTokens(scene)
        let projectTokens = significantTokens(project)
        if !projectTokens.isEmpty, !sceneTokens.isDisjoint(with: projectTokens) {
            return scene
        }
        // Keep scene alone when it's already multi-word / specific enough.
        let wordCount = scene.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount >= 3 {
            return scene
        }
        guard let readableProject = readableProjectPhrase(project) else {
            return scene
        }
        let combined = "\(readableProject) \(scene)"
        return sanitizedFolderName(combined) ?? scene
    }

    /// Expand glued compounds lightly for readable filename prefixes.
    private static func readableProjectPhrase(_ project: String) -> String? {
        let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(where: { $0.isWhitespace }) {
            return sanitizedFolderName(trimmed)
        }
        // Handwerkercenter → Handwerk Center when a camel/compound boundary is obvious.
        if let split = splitCompoundProductName(trimmed) {
            return sanitizedFolderName(split)
        }
        return sanitizedFolderName(trimmed)
    }

    private static func splitCompoundProductName(_ raw: String) -> String? {
        // Insert spaces before capitals inside CamelCase.
        var result = ""
        let chars = Array(raw)
        for (index, char) in chars.enumerated() {
            if index > 0, char.isUppercase, chars[index - 1].isLowercase {
                result.append(" ")
            }
            result.append(char)
        }
        if result != raw, result.contains(where: { $0.isWhitespace }) {
            return result
        }
        // Heuristic for all-lowercase compounds ending in center/studio/lab/app.
        let lower = raw.lowercased()
        let suffixes = ["center", "centre", "studio", "lab", "labs", "app", "apps"]
        for suffix in suffixes where lower.count > suffix.count + 3 && lower.hasSuffix(suffix) {
            let head = String(raw.dropLast(suffix.count))
            let tail = String(raw.suffix(suffix.count))
            let titledTail = tail.prefix(1).uppercased() + tail.dropFirst().lowercased()
            let titledHead = head.prefix(1).uppercased() + head.dropFirst()
            return "\(titledHead) \(titledTail)"
        }
        return nil
    }

    /// Prefer an existing related folder; otherwise create from the best content candidate.
    private static func reconcileProject(
        proposed: String?,
        candidates: [String],
        existingProjects: [String]
    ) -> String? {
        var ordered: [String] = []
        if let proposed = proposed.flatMap({ sanitizedFolderName($0) }),
           !isRejectedOrganizeLabel(proposed) {
            ordered.append(proposed)
        }
        for candidate in candidates where !ordered.contains(where: {
            $0.caseInsensitiveCompare(candidate) == .orderedSame
        }) {
            ordered.append(candidate)
        }

        var bestExisting: (name: String, score: Double)?
        for candidate in ordered {
            if let match = bestExistingProjectMatch(for: candidate, in: existingProjects) {
                if bestExisting == nil || match.score > bestExisting!.score {
                    bestExisting = match
                }
            }
        }
        if let bestExisting, bestExisting.score >= projectMatchThreshold {
            return bestExisting.name
        }

        return ordered.first
    }

    private static func projectCandidates(
        windowInfo: WindowSignature,
        ocrText: String,
        seed: String?
    ) -> [String] {
        var result: [String] = []
        func append(_ raw: String?) {
            guard let name = raw.flatMap({ sanitizedFolderName($0) }),
                  !isRejectedOrganizeLabel(name),
                  !result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                return
            }
            result.append(name)
        }

        append(seed)
        append(windowInfo.resolvedProjectName)

        let product = resolveProductFolder(from: windowInfo)
        if let title = windowInfo.windowTitle,
           let parsed = parseWindowTitle(
               title,
               productHint: product,
               bundleID: windowInfo.dominantAppBundleID ?? windowInfo.bundleID
           ) {
            append(parsed)
        }
        // OCR heading last — often a view title (Design, Parts) rather than the product.
        append(extractHeading(from: ocrText))
        // App name last — only when no stronger content signal exists.
        if result.isEmpty {
            append(product)
        }
        return result
    }

    private static let projectMatchThreshold = 0.75

    private static func bestExistingProjectMatch(
        for candidate: String,
        in existingProjects: [String]
    ) -> (name: String, score: Double)? {
        var best: (name: String, score: Double)?
        for existing in existingProjects {
            let score = projectMatchScore(candidate, existing: existing)
            guard score >= projectMatchThreshold else { continue }
            if best == nil || score > best!.score {
                best = (existing, score)
            }
        }
        return best
    }

    private static let matchTokenStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "for", "to", "in", "on", "at",
        "app", "apps", "page", "site", "web", "www",
    ]

    private static func significantTokens(_ name: String) -> Set<String> {
        let parts = name.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { token in
                token.count >= 2
                    && !matchTokenStopwords.contains(token)
                    && !chromeNavLabels.contains(token)
            }
        return Set(parts)
    }

    private static func projectMatchScore(_ candidate: String, existing: String) -> Double {
        let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !e.isEmpty else { return 0 }
        if c.caseInsensitiveCompare(e) == .orderedSame { return 1.0 }

        let shorter = min(c.count, e.count)
        let longer = max(c.count, e.count)
        if shorter >= 4,
           e.localizedCaseInsensitiveContains(c) || c.localizedCaseInsensitiveContains(e) {
            return 0.72 + 0.25 * (Double(shorter) / Double(longer))
        }

        let ct = significantTokens(c)
        let et = significantTokens(e)
        guard !ct.isEmpty, !et.isEmpty else { return 0 }
        let overlap = ct.intersection(et)
        guard !overlap.isEmpty else { return 0 }
        let ratio = Double(overlap.count) / Double(max(ct.count, et.count))
        if overlap.contains(where: { $0.count >= 4 }) || overlap.count >= 2 {
            return 0.55 + 0.4 * ratio
        }
        return 0
    }

    /// Make the subject unique among captures already in the project folder.
    private static func uniqueCaptureBaseName(
        subject: String,
        project: String,
        currentName: String,
        excluding captureID: UUID
    ) -> String? {
        guard let base = sanitizedFolderName(subject), !base.isEmpty else { return nil }
        let siblings = CaptureLibraryOrganizer.siblingBaseNames(
            inProject: project,
            excluding: captureID
        )
        let unique = nextUniqueBaseName(base, among: siblings)
        if filenameMatchesCurrent(unique, currentName: currentName) {
            return nil
        }
        return unique
    }

    private static func nextUniqueBaseName(_ base: String, among siblings: [String]) -> String {
        let taken = Set(siblings.map { $0.lowercased() })
        if !taken.contains(base.lowercased()) {
            return base
        }

        let thumbnailPrefix = "\(base) thumbnail"
        let hasThumbnailFamily = siblings.contains {
            $0.localizedCaseInsensitiveCompare(thumbnailPrefix) == .orderedSame
                || $0.lowercased().hasPrefix(thumbnailPrefix.lowercased() + " ")
        }
        if hasThumbnailFamily {
            if !taken.contains(thumbnailPrefix.lowercased()) {
                return thumbnailPrefix
            }
            var n = 2
            while taken.contains("\(thumbnailPrefix) \(n)".lowercased()) {
                n += 1
            }
            return "\(thumbnailPrefix) \(n)"
        }

        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) {
            n += 1
        }
        return "\(base) \(n)"
    }

    private static func filenameMatchesCurrent(_ suggested: String, currentName: String) -> Bool {
        let suggestedBase = (suggested as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBase = (currentName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suggestedBase.caseInsensitiveCompare(currentBase) == .orderedSame
    }

    /// Shared with the LLM sanitize path so nav chrome never surfaces.
    static func isRejectedOrganizeLabel(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        if genericWindowTitles.contains(lower) || chromeNavLabels.contains(lower) {
            return true
        }
        return false
    }

    // MARK: - Brand-over-IDE helpers (shared with Cloud / LLM prompts)

    /// Host IDE / editor bundles where window chrome often isn't the capture subject.
    private static let ideHostBundleIDs: Set<String> = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.sublimetext.4",
    ]

    private static let ideHostNameTokens: Set<String> = [
        "cursor", "vscode", "code", "xcode", "intellij", "pycharm", "webstorm",
        "sublime", "jetbrains", "terminal", "iterm",
    ]

    /// Window titles that describe IDE Agents/Chat UI rather than the pictured product.
    private static let ideChromeTitleMarkers: [String] = [
        "agents", "agent", "chat session", "new chat", "new agent",
        "composer", "copilot chat", "inline chat",
    ]

    static func isIDEHost(windowInfo: WindowSignature?) -> Bool {
        guard let windowInfo else { return false }
        for candidate in [windowInfo.dominantAppBundleID, windowInfo.bundleID].compactMap({ $0 }) {
            if ideHostBundleIDs.contains(candidate) { return true }
            if candidate.hasPrefix("com.jetbrains.") { return true }
        }
        let name = (windowInfo.dominantAppName ?? "").lowercased()
        guard !name.isEmpty else { return false }
        let knownNames: [String] = [
            "cursor", "vs code", "visual studio code", "xcode",
            "intellij", "intellij idea", "pycharm", "webstorm", "sublime text",
        ]
        return knownNames.contains { name == $0 || name.hasPrefix($0) }
    }

    static func isIDEChromeWindowTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return ideChromeTitleMarkers.contains { lower.contains($0) }
    }

    /// True when an IDE hosts the capture but OCR shows a different product brand.
    static func shouldDemoteHostChromeMetadata(windowInfo: WindowSignature?, ocrText: String) -> Bool {
        guard isIDEHost(windowInfo: windowInfo), !ocrText.isEmpty else { return false }
        let brands = strongOCRBrandTokens(from: ocrText)
        guard !brands.isEmpty else { return false }
        // Demote when OCR brand tokens aren't just the IDE's own name.
        return !brands.isSubset(of: ideHostNameTokens)
    }

    /// Labeled Window title / Captured app / Resolved project lines for Cloud + LLM prompts.
    static func organizePromptHostMetadataLines(
        windowInfo: WindowSignature?,
        ocrText: String
    ) -> [String] {
        guard let windowInfo else { return [] }
        let demote = shouldDemoteHostChromeMetadata(windowInfo: windowInfo, ocrText: ocrText)
        var lines: [String] = []
        if let windowTitle = windowInfo.windowTitle, !windowTitle.isEmpty {
            if demote {
                lines.append(
                    "Window title (host IDE chrome, secondary — not the image subject): \(windowTitle)"
                )
            } else {
                lines.append("Window title: \(windowTitle)")
            }
        }
        if let project = windowInfo.resolvedProjectName, !project.isEmpty {
            if demote {
                lines.append(
                    "Resolved project signal (host IDE, secondary): \(project)"
                )
            } else {
                lines.append("Resolved project signal: \(project)")
            }
        }
        if let app = windowInfo.dominantAppName ?? windowInfo.bundleID, !app.isEmpty {
            if demote {
                lines.append(
                    "Captured app (host IDE chrome, secondary — prefer in-image brand): \(app)"
                )
            } else {
                lines.append("Captured app: \(app)")
            }
        }
        return lines
    }

    /// Skip a cached project when OCR brand tokens clearly conflict with it.
    static func cachedProjectConflictsWithOCR(productFolder: String, ocrText: String) -> Bool {
        let brands = strongOCRBrandTokens(from: ocrText)
        guard !brands.isEmpty else { return false }
        let cached = significantTokens(productFolder)
        if cached.isEmpty { return false }
        if !brands.isDisjoint(with: cached) { return false }
        // Substring soft-match (e.g. "Droid" vs "DROID CLI") — no conflict.
        for brand in brands where brand.count >= 4 {
            if productFolder.localizedCaseInsensitiveContains(brand) { return false }
            for token in cached where token.count >= 4 {
                if brand.contains(token) || token.contains(brand) { return false }
            }
        }
        return true
    }

    /// Product-like tokens from OCR (large logos, CLI welcome, versioned product names).
    private static func strongOCRBrandTokens(from ocrText: String) -> Set<String> {
        guard !ocrText.isEmpty else { return [] }
        var tokens = Set<String>()
        if let heading = extractHeading(from: ocrText) {
            tokens.formUnion(significantTokens(heading))
        }
        let bands = parseOCRBands(ocrText)
        let pools = bands.topChrome.prefix(8) + bands.upperContent.prefix(12) + bands.body.prefix(8)
        for line in pools {
            if let phrase = productPhraseDetails(from: line)?.phrase {
                tokens.formUnion(significantTokens(phrase))
            }
        }
        return tokens.filter { token in
            token.count >= 3 && !ideHostNameTokens.contains(token) && !chromeNavLabels.contains(token)
        }
    }

    // MARK: - Window metadata (synchronous)

    private static func snapshotOnScreenWindows() -> WindowGeometrySnapshot {
        let grabbitBundleID = Bundle.main.bundleIdentifier
        let grabbitPID = ProcessInfo.processInfo.processIdentifier

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return WindowGeometrySnapshot(windows: [])
        }

        var windows: [SnapshottedWindow] = []
        windows.reserveCapacity(list.count)

        for (index, info) in list.enumerated() {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32 else { continue }
            if pid == grabbitPID { continue }

            let bundleID = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
            if bundleID == grabbitBundleID { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"],
                  width > 1, height > 1 else {
                continue
            }

            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }

            let windowID = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            let title = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTitle = title?.isEmpty == false ? title : nil
            let cgBounds = CGRect(x: x, y: y, width: width, height: height)

            windows.append(
                SnapshottedWindow(
                    windowID: windowID,
                    pid: pid_t(pid),
                    bundleID: bundleID,
                    frame: screenFrame(fromCGWindowBounds: cgBounds),
                    title: normalizedTitle,
                    stackIndex: index
                )
            )
        }

        return WindowGeometrySnapshot(windows: windows)
    }

    /// `CGWindowListCopyWindowInfo` bounds use a top-left screen origin; AppKit capture rects use bottom-left.
    private static func screenFrame(fromCGWindowBounds cgBounds: CGRect) -> CGRect {
        let globalMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? 0
        return CGRect(
            x: cgBounds.origin.x,
            y: globalMaxY - cgBounds.origin.y - cgBounds.height,
            width: cgBounds.width,
            height: cgBounds.height
        )
    }

    private static func dominantApp(in captureRect: CGRect, snapshot: WindowGeometrySnapshot) -> DominantAppInfo? {
        guard captureRect.width > 0, captureRect.height > 0 else { return nil }

        var areaByBundle: [String: CGFloat] = [:]
        var bestStackByBundle: [String: Int] = [:]
        var bestWindowByBundle: [String: SnapshottedWindow] = [:]

        for window in snapshot.windows {
            guard let bundleID = window.bundleID else { continue }
            let area = intersectionArea(window.frame, captureRect)
            guard area > 0 else { continue }

            areaByBundle[bundleID, default: 0] += area

            let existingBest = bestWindowByBundle[bundleID]
            let existingArea = existingBest.map { intersectionArea($0.frame, captureRect) } ?? 0
            if area > existingArea || (area == existingArea && window.stackIndex < (existingBest?.stackIndex ?? .max)) {
                bestWindowByBundle[bundleID] = window
            }

            if let currentStack = bestStackByBundle[bundleID] {
                bestStackByBundle[bundleID] = min(currentStack, window.stackIndex)
            } else {
                bestStackByBundle[bundleID] = window.stackIndex
            }
        }

        guard let dominantBundle = areaByBundle.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let lhsStack = bestStackByBundle[lhs.key] ?? Int.max
            let rhsStack = bestStackByBundle[rhs.key] ?? Int.max
            return lhsStack > rhsStack
        })?.key,
              let representative = bestWindowByBundle[dominantBundle] else {
            return nil
        }

        return DominantAppInfo(
            bundleID: dominantBundle,
            pid: representative.pid,
            windowTitle: representative.title ?? focusedWindowTitle(pid: representative.pid)
        )
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func resolveAppName(bundleID: String) -> String? {
        if let known = knownAppFolders[bundleID] {
            return known
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?
            .localizedName
            .flatMap { sanitizedFolderName($0) }
    }

    private static func resolveProjectName(
        pid: pid_t,
        bundleID: String,
        windowTitle: String?,
        productName: String?
    ) -> String? {
        if isSupportedBrowser(bundleID: bundleID),
           let browserProject = resolveBrowserProjectName(bundleID: bundleID) {
            return sanitizedFolderName(browserProject)
        }

        if let documentURL = documentURL(pid: pid),
           let project = projectNameFromDocumentURL(documentURL) {
            return sanitizedFolderName(project)
        }

        if let title = windowTitle,
           let parsed = parseWindowTitle(title, productHint: productName, bundleID: bundleID),
           !isGenericTitle(parsed) {
            return sanitizedFolderName(parsed)
        }

        return nil
    }

    // MARK: - Browser tab resolution (AppleScript)

    /// Chromium-family browsers share Chrome's "active tab of front window" AppleScript
    /// dictionary. Keyed by bundle ID → the app name AppleScript needs in `tell application`.
    private static let chromiumBrowserAppNames: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
    ]

    private static func isSupportedBrowser(bundleID: String) -> Bool {
        bundleID == "com.apple.Safari" || chromiumBrowserAppNames[bundleID] != nil
    }

    /// Asks the frontmost browser for its active tab's URL via Apple Events and turns
    /// that into a project name (site + repo/workspace slug where one exists). Fails
    /// silently (returns nil) if Automation permission hasn't been granted yet or the
    /// browser doesn't answer — callers fall back to window-title parsing in that case.
    private static func resolveBrowserProjectName(bundleID: String) -> String? {
        let urlString: String?
        if bundleID == "com.apple.Safari" {
            urlString = runAppleScript(#"tell application "Safari" to return URL of front document"#)
        } else if let appName = chromiumBrowserAppNames[bundleID] {
            urlString = runAppleScript(#"tell application "\#(appName)" to return URL of active tab of front window"#)
        } else {
            urlString = nil
        }

        guard let urlString, !urlString.isEmpty,
              let url = URL(string: urlString),
              let host = url.host, !host.isEmpty else {
            return nil
        }

        return projectName(fromHost: host, path: url.path)
    }

    private static func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else { return nil }
        return result.stringValue
    }

    /// Friendly display names for common multi-tenant sites. Anything not listed falls
    /// back to a capitalized version of the domain's first label (e.g. "example.com" → "Example").
    private static let friendlySiteNames: [String: String] = [
        "github.com": "GitHub",
        "gitlab.com": "GitLab",
        "bitbucket.org": "Bitbucket",
        "linear.app": "Linear",
        "notion.so": "Notion",
        "figma.com": "Figma",
        "docs.google.com": "Google Docs",
        "sheets.google.com": "Google Sheets",
        "slides.google.com": "Google Slides",
        "drive.google.com": "Google Drive",
        "colab.research.google.com": "Colab",
        "stackoverflow.com": "Stack Overflow",
        "youtube.com": "YouTube",
        "asana.com": "Asana",
        "app.asana.com": "Asana",
        "trello.com": "Trello",
        "atlassian.net": "Jira",
        "vercel.com": "Vercel",
        "netlify.com": "Netlify",
    ]

    /// Sites where the first path segment(s) name a specific repo/workspace worth
    /// surfacing as part of the folder name (e.g. "GitHub - grabbit").
    private static func projectName(fromHost host: String, path: String) -> String? {
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        if normalizedHost == "localhost" || normalizedHost == "127.0.0.1" {
            return "Localhost"
        }

        let segments = path.split(separator: "/").map(String.init)

        let friendlyName = friendlySiteNames[normalizedHost]
            ?? normalizedHost.split(separator: ".").first.map { component in
                component.prefix(1).uppercased() + component.dropFirst()
            }

        guard let friendlyName else { return nil }

        let slug: String?
        switch normalizedHost {
        case "github.com", "gitlab.com", "bitbucket.org":
            // /owner/repo/... → the repo name
            slug = segments.count >= 2 ? segments[1] : segments.first
        case "linear.app":
            // /workspace/... → the workspace slug
            slug = segments.first
        case "atlassian.net":
            slug = segments.first
        default:
            slug = nil
        }

        if let slug, slug.count >= 2 {
            return "\(friendlyName) - \(slug)"
        }

        return friendlyName
    }

    private static func documentURL(pid: pid_t) -> URL? {
        let appRef = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focusedWindow = focusedValue else {
            return nil
        }

        let windowRef = focusedWindow as! AXUIElement
        var docValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowRef, kAXDocumentAttribute as CFString, &docValue) == .success else {
            return nil
        }

        if let url = docValue as? URL {
            return url.isFileURL ? url : nil
        }
        if let path = docValue as? String, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            return url.isFileURL ? url : nil
        }
        return nil
    }

    private static func projectNameFromDocumentURL(_ url: URL) -> String? {
        let fileManager = FileManager.default
        var directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()

        while directory.path != "/" {
            let markerNames = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            if markerNames.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                return directory.lastPathComponent
            }
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory.lastPathComponent
            }
            directory.deleteLastPathComponent()
        }

        return nil
    }

    private static func focusedWindowTitle(pid: pid_t?) -> String? {
        guard let pid else { return nil }

        let appRef = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focusedWindow = focusedValue else {
            return nil
        }

        let windowRef = focusedWindow as! AXUIElement
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowRef, kAXTitleAttribute as CFString, &titleValue) == .success else {
            return nil
        }

        let title = (titleValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        return title
    }

    // MARK: - Vision OCR

    private static func recognizeText(in image: NSImage, accurate: Bool = false) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    continuation.resume(returning: "")
                    return
                }

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = accurate ? .accurate : .fast
                request.usesLanguageCorrection = false

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    // Vision boxes use bottom-left origin — sort top→bottom, then left→right.
                    // Band labels stand in for multimodal layout until Attachment/OCRTool ship.
                    struct OCRLine {
                        let text: String
                        let maxY: CGFloat
                        let minX: CGFloat
                    }

                    let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                        guard let text = observation.topCandidates(1).first?.string
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                              !text.isEmpty else {
                            return nil
                        }
                        let box = observation.boundingBox
                        return OCRLine(text: text, maxY: box.maxY, minX: box.minX)
                    }
                    .sorted { lhs, rhs in
                        if abs(lhs.maxY - rhs.maxY) > 0.015 {
                            return lhs.maxY > rhs.maxY
                        }
                        return lhs.minX < rhs.minX
                    }

                    guard !lines.isEmpty else {
                        continuation.resume(returning: "")
                        return
                    }

                    // Normalized Y: 1 = top of image. Bands approximate chrome vs body vs footer.
                    var chrome: [String] = []
                    var upper: [String] = []
                    var body: [String] = []
                    var footer: [String] = []
                    for line in lines {
                        switch line.maxY {
                        case 0.82...:
                            chrome.append(line.text)
                        case 0.55..<0.82:
                            upper.append(line.text)
                        case 0.18..<0.55:
                            body.append(line.text)
                        default:
                            footer.append(line.text)
                        }
                    }

                    func section(_ title: String, _ values: [String]) -> String? {
                        guard !values.isEmpty else { return nil }
                        return "[\(title)]\n" + values.joined(separator: "\n")
                    }

                    let sections = [
                        section("TOP_CHROME", chrome),
                        section("UPPER_CONTENT", upper),
                        section("BODY", body),
                        section("FOOTER", footer)
                    ].compactMap { $0 }

                    continuation.resume(returning: sections.joined(separator: "\n\n"))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    // MARK: - Rule-based classification

    private static let knownAppFolders: [String: String] = [
        "com.figma.Desktop": "Figma",
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "com.apple.dt.Xcode": "Xcode",
        "com.microsoft.VSCode": "VS Code",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.linear": "Linear",
        "com.notion.id": "Notion",
        "com.github.GitHubClient": "GitHub",
        "com.apple.finder": "Finder",
        "com.apple.mail": "Mail",
        "com.apple.Notes": "Notes",
        "com.apple.iWork.Keynote": "Keynote",
        "com.apple.iWork.Pages": "Pages",
        "com.apple.iWork.Numbers": "Numbers",
        "com.spotify.client": "Spotify",
        "com.adobe.Photoshop": "Photoshop",
        "com.adobe.illustrator": "Illustrator",
        "com.sketch.sketch": "Sketch",
        "com.figma.agent": "Figma",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Edge",
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm",
        "com.jetbrains.intellij": "IntelliJ",
        "com.jetbrains.intellij.ce": "IntelliJ",
        "com.jetbrains.pycharm": "PyCharm",
        "com.jetbrains.WebStorm": "WebStorm",
        "com.sublimetext.4": "Sublime Text",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.loom.desktop": "Loom",
        "com.culturedcode.ThingsMac": "Things",
        "com.omnigroup.OmniFocus3": "OmniFocus",
        "com.todoist.mac.Todoist": "Todoist",
        "com.readdle.smartemail-Mac": "Spark",
        "com.hnc.Discord": "Discord",
        "com.tdesktop.Telegram": "Telegram",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.apple.iCal": "Calendar",
        "com.apple.reminders": "Reminders",
    ]

    private static let genericWindowTitles: Set<String> = [
        "",
        "untitled",
        "new tab",
        "new window",
        "window",
        "document",
        "start page",
        "homepage",
        "recents",
    ]

    /// Single-token (and a few multi-word) UI chrome labels that must never become
    /// project or filename suggestions.
    private static let chromeNavLabels: Set<String> = [
        "back", "home", "menu", "close", "cancel", "done", "next", "previous",
        "search", "share", "edit", "more", "settings", "account", "profile",
        "sign in", "log in", "login", "signin", "sign out", "logout",
        "skip", "continue", "ok", "okay", "yes", "no", "submit", "save",
        "delete", "remove", "add", "new", "open", "help", "about", "privacy",
        "terms", "filter", "sort", "view", "list", "grid", "tab", "tabs",
        "sidebar", "navigation", "nav", "introduction", "overview", "contents",
        "summary", "conclusion", "details", "general", "advanced", "preferences",
        // In-app section / view titles — not the product or tab identity.
        "design", "parts", "requirements", "versions", "simulation", "materials",
        "layout", "canvas", "preview", "inspector", "layers", "assets",
        "components", "properties", "history", "comments", "prototype",
        "dashboard", "workspace", "library", "inbox", "explore", "activity",
    ]

    private static let headlineContinuationWords: Set<String> = [
        "reimagines", "reimagine", "brings", "bring", "is", "are", "was", "were",
        "with", "for", "that", "which", "who", "introduces", "introducing",
        "presents", "features", "using", "via", "from", "into", "and", "the",
        "a", "an", "to", "of", "in", "on", "at", "by", "as",
    ]

    private static func classifyWithRules(windowInfo: WindowSignature, ocrText: String) -> CaptureDestination? {
        // Base app / dominant app name (e.g. "Figma", "Safari", "Cursor").
        let baseProduct = resolveProductFolder(from: windowInfo)
        // Tab / project / document name, preferably from the window title or OCR.
        let tabOrProject = inferSubfolder(
            windowInfo: windowInfo,
            ocrText: ocrText,
            productFolder: baseProduct
        )

        // Prefer the tab/project name as the primary folder when we have one,
        // but ignore chrome/nav labels and ultra-short junk.
        if let tabOrProject,
           tabOrProject.count >= 3,
           !isRejectedOrganizeLabel(tabOrProject) {
            let destination = CaptureDestination(
                productFolder: tabOrProject,
                subfolder: nil,
                confidence: 0.8,
                source: .ocr
            )
            return destination.confidence >= minimumConfidence ? destination : nil
        }

        // Fall back to organizing by dominant app name (Figma, Safari, etc.).
        if let baseProduct, !isRejectedOrganizeLabel(baseProduct) {
            let destination = CaptureDestination(
                productFolder: baseProduct,
                subfolder: nil,
                confidence: 0.7,
                source: .windowMetadata
            )
            return destination.confidence >= minimumConfidence ? destination : nil
        }

        return nil
    }

    private static func resolveProductFolder(from windowInfo: WindowSignature) -> String? {
        if let dominant = windowInfo.dominantAppName {
            return dominant
        }

        if let dominantBundle = windowInfo.dominantAppBundleID,
           let known = knownAppFolders[dominantBundle] {
            return known
        }

        if let bundleID = windowInfo.bundleID,
           let known = knownAppFolders[bundleID] {
            return known
        }

        if let bundleID = windowInfo.bundleID,
           let localized = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return sanitizedFolderName(localized)
        }

        if let title = windowInfo.windowTitle,
           let parsed = parseWindowTitle(title, productHint: nil, bundleID: windowInfo.bundleID),
           !isGenericTitle(parsed) {
            return sanitizedFolderName(parsed)
        }

        return nil
    }

    private static func inferSubfolder(
        windowInfo: WindowSignature,
        ocrText: String,
        productFolder: String?
    ) -> String? {
        if let project = windowInfo.resolvedProjectName {
            return project
        }

        let titleForParsing = windowInfo.windowTitle
        let bundleForParsing = windowInfo.dominantAppBundleID ?? windowInfo.bundleID

        if let title = titleForParsing,
           let parsed = parseWindowTitle(title, productHint: productFolder, bundleID: bundleForParsing),
           !isGenericTitle(parsed) {
            if let productFolder, parsed.localizedCaseInsensitiveCompare(productFolder) == .orderedSame {
                return extractHeading(from: ocrText)
            }
            return sanitizedFolderName(parsed)
        }

        return extractHeading(from: ocrText)
    }

    private static func parseWindowTitle(_ title: String, productHint: String?, bundleID: String? = nil) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let separators = [" — ", " - ", " – ", " | "]
        for separator in separators {
            guard let range = trimmed.range(of: separator) else { continue }

            let lhs = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if let bundleID, let appSpecific = appSpecificTitleComponent(
                lhs: lhs,
                rhs: rhs,
                bundleID: bundleID
            ) {
                return appSpecific
            }

            if let productHint {
                if rhs.localizedCaseInsensitiveContains(productHint) {
                    return lhs.isEmpty ? nil : lhs
                }
                if lhs.localizedCaseInsensitiveContains(productHint) {
                    return rhs.isEmpty ? nil : rhs
                }
            }

            let productSide = rhs.isEmpty ? lhs : (lhs.isEmpty ? rhs : lhs)
            if !isGenericTitle(productSide) {
                return productSide
            }
        }

        if let productHint, trimmed.localizedCaseInsensitiveContains(productHint) {
            return nil
        }

        return isGenericTitle(trimmed) ? nil : trimmed
    }

    /// Known per-app window-title conventions for project/workspace extraction.
    private static func appSpecificTitleComponent(lhs: String, rhs: String, bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.dt.Xcode",
             "com.jetbrains.intellij",
             "com.jetbrains.intellij.ce",
             "com.jetbrains.pycharm",
             "com.jetbrains.WebStorm":
            return lhs.isEmpty || isGenericTitle(lhs) ? nil : lhs
        case "com.microsoft.VSCode",
             "com.sublimetext.4":
            return rhs.isEmpty || isGenericTitle(rhs) ? nil : rhs
        case "com.google.Chrome",
             "com.apple.Safari",
             "company.thebrowser.Browser",
             "com.brave.Browser",
             "org.mozilla.firefox",
             "com.microsoft.edgemac":
            return lhs.isEmpty || isGenericTitle(lhs) ? nil : lhs
        default:
            return nil
        }
    }

    private static func extractHeading(from ocrText: String) -> String? {
        let bands = parseOCRBands(ocrText)

        // Top chrome first — leftmost tab/workspace label (active tabs are usually first).
        // Don’t prefer multi-word inactive tabs (e.g. "Oslo Distr") over a longer product
        // token like "Handwerkercenter".
        if let phrase = firstGoodChromePhrase(in: bands.topChrome) {
            return phrase
        }
        if let phrase = firstGoodProductPhrase(in: bands.upperContent, allowSingleWord: true) {
            return phrase
        }
        if let phrase = firstGoodProductPhrase(in: bands.body, allowSingleWord: true) {
            return phrase
        }
        // Unbanded fallback (legacy OCR without section labels).
        if let phrase = firstGoodProductPhrase(in: bands.unbanded, allowSingleWord: true) {
            return phrase
        }
        return nil
    }

    /// Reading-order pick for tab/title chrome — first plausible product label wins.
    private static func firstGoodChromePhrase(in lines: [String]) -> String? {
        for line in lines {
            guard isPlausibleHeadingLine(line) else { continue }
            guard let extracted = productPhraseDetails(from: line) else { continue }
            let phrase = extracted.phrase
            guard !isRejectedOrganizeLabel(phrase) else { continue }
            // Prefer product-like tokens (≥4 letters) over ultra-short chrome fragments.
            if phrase.count >= 4 {
                return phrase
            }
        }
        return nil
    }

    private struct OCRBands {
        var topChrome: [String] = []
        var upperContent: [String] = []
        var body: [String] = []
        var footer: [String] = []
        var unbanded: [String] = []
    }

    private static func parseOCRBands(_ ocrText: String) -> OCRBands {
        var bands = OCRBands()
        var current: WritableKeyPath<OCRBands, [String]>? = nil
        var sawBandLabel = false

        for raw in ocrText.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                sawBandLabel = true
                switch line.uppercased() {
                case "[TOP_CHROME]":
                    current = \.topChrome
                case "[UPPER_CONTENT]":
                    current = \.upperContent
                case "[BODY]":
                    current = \.body
                case "[FOOTER]":
                    current = \.footer
                default:
                    current = nil
                }
                continue
            }

            if let current {
                bands[keyPath: current].append(line)
            } else if !sawBandLabel {
                bands.unbanded.append(line)
            }
        }
        return bands
    }

    private static func firstGoodProductPhrase(
        in lines: [String],
        allowSingleWord: Bool
    ) -> String? {
        var bestMulti: (phrase: String, score: Double)?
        var singleWordFallback: String?

        for line in lines {
            guard isPlausibleHeadingLine(line) else { continue }
            guard let extracted = productPhraseDetails(from: line) else { continue }
            let wordCount = extracted.phrase.split(whereSeparator: { $0.isWhitespace }).count
            // Prefer long headline-like lines (continuation truncate) over short TOC labels.
            let score = Double(min(line.count, 100))
                + (extracted.fromHeadline ? 50 : 0)
                + (wordCount >= 2 ? 10 : 0)

            if wordCount >= 2 {
                if bestMulti == nil || score > bestMulti!.score {
                    bestMulti = (extracted.phrase, score)
                }
            } else if allowSingleWord,
                      singleWordFallback == nil,
                      extracted.phrase.count >= 4,
                      !isRejectedOrganizeLabel(extracted.phrase) {
                singleWordFallback = extracted.phrase
            }
        }

        return bestMulti?.phrase ?? (allowSingleWord ? singleWordFallback : nil)
    }

    private static func isPlausibleHeadingLine(_ line: String) -> Bool {
        guard line.count >= 3 && line.count <= 120 else { return false }
        if line.hasPrefix("[") && line.hasSuffix("]") { return false }
        if isRejectedOrganizeLabel(line) { return false }
        if line.rangeOfCharacter(from: .decimalDigits) != nil && line.count < 8 { return false }
        return true
    }

    /// Truncate a long headline to a short product phrase (e.g. "Arc Search").
    private static func productPhraseDetails(
        from line: String,
        maxWords: Int = 4
    ) -> (phrase: String, fromHeadline: Bool)? {
        let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return nil }

        var taken: [String] = []
        var hitContinuation = false
        for word in words {
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard !cleaned.isEmpty else { continue }
            let lower = cleaned.lowercased()
            if taken.isEmpty {
                // Alone, a chrome token is never a product — but "Search" may appear
                // inside a real name like "Arc Search" once we have a lead word.
                if chromeNavLabels.contains(lower) { return nil }
                taken.append(cleaned)
                continue
            }
            if headlineContinuationWords.contains(lower) {
                hitContinuation = true
                break
            }
            taken.append(cleaned)
            if taken.count >= maxWords { break }
        }

        guard !taken.isEmpty else { return nil }
        let phrase = taken.joined(separator: " ")
        // Reject only when the *whole* phrase is chrome (e.g. "Sign In"), not when a
        // chrome word is a component of a product name ("Arc Search").
        if isRejectedOrganizeLabel(phrase) { return nil }
        guard let sanitized = sanitizedFolderName(phrase) else { return nil }
        // Headline signal: we stopped on a continuation verb, or the source line was long.
        let fromHeadline = hitContinuation || line.count >= 40
        return (sanitized, fromHeadline)
    }

    private static func isGenericTitle(_ title: String) -> Bool {
        isRejectedOrganizeLabel(title)
    }

    private static func sanitizedFolderName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let invalid = CharacterSet(charactersIn: ":/\\")
        let cleaned = trimmed
            .components(separatedBy: invalid)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        guard !cleaned.isEmpty else { return nil }
        if isRejectedOrganizeLabel(cleaned) { return nil }
        return String(cleaned.prefix(120))
    }
}
