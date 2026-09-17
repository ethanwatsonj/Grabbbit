//
//  CaptureClassifier.swift
//  Grabbit
//
//  On-device Auto-Organize classification: proposes a product/subfolder destination
//  for a capture using window metadata and Vision OCR. Fully deterministic and
//  synchronous-fast — no local LLM tier, so a suggestion never needs to "load."
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

        if CaptureClassifierLLM.isAvailable {
            if let llm = await CaptureClassifierLLM.suggestRenameAndProject(
                image: request.image,
                windowInfo: request.windowInfo,
                ocrText: ocrText,
                existingProjects: existingProjects
            ), llm.hasProject {
                // Drop a no-op rename so accept only updates when the name changes.
                if let name = llm.suggestedName,
                   filenameMatchesCurrent(name, currentName: request.entry.displayName) {
                    return RenameSuggestion(
                        suggestedName: nil,
                        suggestedProject: llm.suggestedProject,
                        confidence: llm.confidence
                    )
                }
                return llm
            }
            guard !Task.isCancelled else { return nil }
        }

        // Deterministic path — only surface once a project is known from
        // mapping cache, resolved workspace, or OCR/title/app rules.
        // Always pair project with a rename when we have a distinct filename signal.
        if let cached = CaptureDestinationMappingCache.shared.destination(for: signature) {
            let name = suggestedFilename(
                windowInfo: signature,
                ocrText: ocrText,
                project: cached.productFolder,
                currentName: request.entry.displayName
            )
            return RenameSuggestion(
                suggestedName: name,
                suggestedProject: cached.productFolder,
                confidence: cached.confidence
            )
        }

        if let project = signature.resolvedProjectName.flatMap({ sanitizedFolderName($0) }) {
            let name = suggestedFilename(
                windowInfo: signature,
                ocrText: ocrText,
                project: project,
                currentName: request.entry.displayName
            )
            return RenameSuggestion(suggestedName: name, suggestedProject: project, confidence: 0.8)
        }

        if let ruleResult = classifyWithRules(windowInfo: signature, ocrText: ocrText) {
            let name = suggestedFilename(
                windowInfo: signature,
                ocrText: ocrText,
                project: ruleResult.productFolder,
                currentName: request.entry.displayName
            )
            return RenameSuggestion(
                suggestedName: name,
                suggestedProject: ruleResult.productFolder,
                confidence: ruleResult.confidence
            )
        }

        // Still unclear — finish with no suggestion rather than presenting
        // empty filename / project placeholders.
        return nil
    }

    /// Prefer tab / workspace / heading for rename; fall back to the project folder.
    /// Skip when it would leave the file unchanged.
    private static func suggestedFilename(
        windowInfo: WindowSignature,
        ocrText: String,
        project: String,
        currentName: String
    ) -> String? {
        let product = resolveProductFolder(from: windowInfo)
        let candidates: [String?] = [
            inferSubfolder(windowInfo: windowInfo, ocrText: ocrText, productFolder: product),
            windowInfo.resolvedProjectName.flatMap { sanitizedFolderName($0) },
            sanitizedFolderName(project),
        ]

        for candidate in candidates {
            guard let name = candidate,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !filenameMatchesCurrent(name, currentName: currentName) else {
                continue
            }
            return name
        }
        return nil
    }

    private static func filenameMatchesCurrent(_ suggested: String, currentName: String) -> Bool {
        let suggestedBase = (suggested as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBase = (currentName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suggestedBase.caseInsensitiveCompare(currentBase) == .orderedSame
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
        // but ignore obviously junky, ultra-short strings.
        if let tabOrProject, tabOrProject.count >= 3 {
            let destination = CaptureDestination(
                productFolder: tabOrProject,
                subfolder: nil,
                confidence: 0.8,
                source: .ocr
            )
            return destination.confidence >= minimumConfidence ? destination : nil
        }

        // Fall back to organizing by dominant app name (Figma, Safari, etc.).
        if let baseProduct {
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
        let lines = ocrText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard line.count >= 3 && line.count <= 80 else { return false }
                // Skip band labels from spatially partitioned OCR.
                if line.hasPrefix("[") && line.hasSuffix("]") { return false }
                return true
            }

        for line in lines.prefix(12) {
            if isGenericTitle(line) { continue }
            if line.rangeOfCharacter(from: .decimalDigits) != nil && line.count < 8 { continue }
            return sanitizedFolderName(line)
        }

        return nil
    }

    private static func isGenericTitle(_ title: String) -> Bool {
        genericWindowTitles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
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
        return String(cleaned.prefix(120))
    }
}
