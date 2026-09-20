//
//  CaptureHistory.swift
//  Grabbit
//

import AppKit
import AVFoundation
import ImageIO

enum CaptureNaming {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()

    static func baseName(at date: Date = Date()) -> String {
        "Grabbit \(formatter.string(from: date))"
    }

    static func recordingFilename(at date: Date = Date()) -> String {
        "\(baseName(at: date)).mp4"
    }

    static func screenshotFilename(at date: Date = Date()) -> String {
        "\(baseName(at: date)).png"
    }

    static func uniqueURL(
        in directory: URL,
        preferredFilename: String,
        excluding existing: URL? = nil
    ) -> URL {
        let fileManager = FileManager.default
        let excluded = existing?.standardizedFileURL
        var candidate = directory.appendingPathComponent(preferredFilename)
        if !isOccupied(candidate, excluding: excluded, fileManager: fileManager) {
            return candidate
        }

        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            candidate = directory.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            if !isOccupied(candidate, excluding: excluded, fileManager: fileManager) {
                return candidate
            }
            counter += 1
        }
    }

    private static func isOccupied(
        _ url: URL,
        excluding: URL?,
        fileManager: FileManager
    ) -> Bool {
        let standardized = url.standardizedFileURL
        if let excluding, standardized == excluding {
            return false
        }
        return fileManager.fileExists(atPath: standardized.path)
    }
}

enum CaptureItem {
    case screenshot(NSImage)
    case recording(url: URL, thumbnail: NSImage)

    var thumbnail: NSImage {
        switch self {
        case .screenshot(let img): return img
        case .recording(_, let thumb): return thumb
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var kindLabel: String {
        isRecording ? "Recording" : "Screenshot"
    }
}

struct CaptureEntry: Identifiable {
    let id: UUID
    let createdAt: Date
    let item: CaptureItem
    let customName: String?
    let tags: [CaptureTag]

    init(
        id: UUID,
        createdAt: Date,
        item: CaptureItem,
        customName: String? = nil,
        tags: [CaptureTag] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.item = item
        self.customName = customName
        self.tags = CaptureTag.sorted(tags)
    }

    var thumbnail: NSImage { item.thumbnail }
    var isRecording: Bool { item.isRecording }
    var kindLabel: String { item.kindLabel }

    var projectTag: CaptureTag? {
        tags.first { $0.kind == .project }
    }

    var displayName: String {
        if let customName, !customName.isEmpty {
            return customName
        }
        switch item {
        case .screenshot:
            return CaptureNaming.baseName(at: createdAt)
        case .recording(let url, _):
            return url.deletingPathExtension().lastPathComponent
        }
    }

    var menuTitle: String {
        "\(displayName) · \(createdAt.compactRelativeLabel)"
    }
}

extension Date {
    var compactRelativeLabel: String {
        let seconds = Date().timeIntervalSince(self)
        guard seconds >= 0 else {
            return formatted(date: .abbreviated, time: .omitted)
        }

        if seconds < 60 { return "just now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)min" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }

        let calendar = Calendar.current
        if calendar.isDate(self, equalTo: Date(), toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(.dateTime.month(.abbreviated).day().year())
    }
}

extension Notification.Name {
    static let captureHistoryDidChange = Notification.Name("CaptureHistoryDidChange")
}

final class CaptureHistory {
    static let shared = CaptureHistory()

    static let maxMenuItems = 3
    private static let maxStored = 200
    /// Max edge for list/menu thumbnails. Full images stay on disk until requested.
    private static let thumbnailMaxPixelSize: CGFloat = 240

    private struct StoredCapture: Codable {
        enum Kind: String, Codable {
            case screenshot
            case recording
        }

        let id: UUID
        let createdAt: Date
        let kind: Kind
        let path: String
        let thumbnailPath: String?
        let customName: String?
        let tags: [CaptureTag]
        /// Capture-time window / project signals for library Auto Organize after relaunch.
        let windowSignature: WindowSignature?

        init(
            id: UUID,
            createdAt: Date,
            kind: Kind,
            path: String,
            thumbnailPath: String?,
            customName: String?,
            tags: [CaptureTag] = [],
            windowSignature: WindowSignature? = nil
        ) {
            self.id = id
            self.createdAt = createdAt
            self.kind = kind
            self.path = path
            self.thumbnailPath = thumbnailPath
            self.customName = customName
            self.tags = tags
            self.windowSignature = windowSignature
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            kind = try container.decode(Kind.self, forKey: .kind)
            path = try container.decode(String.self, forKey: .path)
            thumbnailPath = try container.decodeIfPresent(String.self, forKey: .thumbnailPath)
            customName = try container.decodeIfPresent(String.self, forKey: .customName)
            tags = try container.decodeIfPresent([LossyCaptureTag].self, forKey: .tags)?
                .compactMap(\.tag) ?? []
            windowSignature = try container.decodeIfPresent(WindowSignature.self, forKey: .windowSignature)
        }
    }

    private let storageDirectory: URL
    private let manifestURL: URL
    private var storedCaptures: [StoredCapture] = []
    /// Full-resolution screenshot cache. Entries themselves only keep list thumbnails.
    private let fullImageCache = NSCache<NSUUID, NSImage>()
    /// Medium-res previews for library card grids (sharper than list thumbs, lighter than full).
    private let previewImageCache = NSCache<NSString, NSImage>()
    /// Coalesces overlapping folder scans (launch + Library + Settings).
    private var reconcileTask: Task<Void, Never>?

    private(set) var entries: [CaptureEntry] = []

    /// Captures whose files live under the current Settings save folder (including project subfolders).
    var entriesInSaveRoot: [CaptureEntry] {
        let scoped = entries.filter { isUnderSaveRoot(id: $0.id) }
        // If the save-folder preference failed to load (Desktop fallback), scoped is empty
        // even though history still has real captures — don't hide them from Recents/Library.
        if scoped.isEmpty, !entries.isEmpty, !AppSettings.hasConfiguredDestinationFolder {
            return entries
        }
        return scoped
    }

    var recents: [CaptureItem] { entriesInSaveRoot.map(\.item) }
    var menuEntries: [CaptureEntry] { Array(entriesInSaveRoot.prefix(Self.maxMenuItems)) }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let grabbitRoot = appSupport.appendingPathComponent("Grabbit", isDirectory: true)
        let legacyRoot = appSupport.appendingPathComponent("Snipsnap", isDirectory: true)
        Self.migrateLegacyAppSupportIfNeeded(from: legacyRoot, to: grabbitRoot)
        storageDirectory = grabbitRoot.appendingPathComponent("recents", isDirectory: true)
        manifestURL = storageDirectory.appendingPathComponent("manifest.json")
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        fullImageCache.countLimit = 24
        previewImageCache.countLimit = 48
        loadFromDisk()
    }

    /// One-time move of Application Support data after the Snipsnap → Grabbit rename.
    private static func migrateLegacyAppSupportIfNeeded(from legacyRoot: URL, to grabbitRoot: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyRoot.path) else { return }
        if fm.fileExists(atPath: grabbitRoot.path) { return }
        try? fm.moveItem(at: legacyRoot, to: grabbitRoot)
    }

    /// Manifest stores absolute paths; rewriting after the folder rename keeps thumbs findable
    /// without regenerating every recording frame on the main thread at launch.
    private static let legacyAppSupportPathComponent = "/Application Support/Snipsnap/"
    private static let currentAppSupportPathComponent = "/Application Support/Grabbit/"

    private static func rewritingLegacyAppSupportPath(_ path: String) -> String {
        guard path.contains(legacyAppSupportPathComponent) else { return path }
        return path.replacingOccurrences(
            of: legacyAppSupportPathComponent,
            with: currentAppSupportPathComponent
        )
    }

    private static func rewritingLegacyAppSupportPaths(in entry: StoredCapture) -> StoredCapture {
        let path = rewritingLegacyAppSupportPath(entry.path)
        let thumbnailPath = entry.thumbnailPath.map { rewritingLegacyAppSupportPath($0) }
        guard path != entry.path || thumbnailPath != entry.thumbnailPath else { return entry }
        return StoredCapture(
            id: entry.id,
            createdAt: entry.createdAt,
            kind: entry.kind,
            path: path,
            thumbnailPath: thumbnailPath,
            customName: entry.customName,
            tags: entry.tags,
            windowSignature: entry.windowSignature
        )
    }

    func windowSignature(for id: UUID) -> WindowSignature? {
        storedCaptures.first(where: { $0.id == id })?.windowSignature
    }

    func setWindowSignature(id: UUID, _ signature: WindowSignature) {
        guard let index = storedCaptures.firstIndex(where: { $0.id == id }) else { return }
        let stored = storedCaptures[index]
        storedCaptures[index] = StoredCapture(
            id: stored.id,
            createdAt: stored.createdAt,
            kind: stored.kind,
            path: stored.path,
            thumbnailPath: stored.thumbnailPath,
            customName: stored.customName,
            tags: stored.tags,
            windowSignature: signature
        )
        persist()
    }

    @discardableResult
    func add(_ item: CaptureItem) -> CaptureEntry? {
        let id = UUID()
        let createdAt = Date()

        switch item {
        case .screenshot(let image):
            guard let path = saveScreenshot(image, at: createdAt) else { return nil }
            let thumb = Self.downsampledImage(image, maxPixelSize: Self.thumbnailMaxPixelSize) ?? image
            let thumbPath = saveThumbnail(thumb)
            fullImageCache.setObject(image, forKey: id as NSUUID)
            let entry = CaptureEntry(id: id, createdAt: createdAt, item: .screenshot(thumb), tags: [])
            storedCaptures.insert(
                StoredCapture(
                    id: id,
                    createdAt: createdAt,
                    kind: .screenshot,
                    path: path.path,
                    thumbnailPath: thumbPath?.path,
                    customName: nil,
                    tags: [],
                ),
                at: 0
            )
            entries.insert(entry, at: 0)

        case .recording(let url, let thumbnail):
            let thumbPath = saveThumbnail(thumbnail)
            let entry = CaptureEntry(id: id, createdAt: createdAt, item: item, tags: [])
            storedCaptures.insert(
                StoredCapture(
                    id: id,
                    createdAt: createdAt,
                    kind: .recording,
                    path: url.path,
                    thumbnailPath: thumbPath?.path,
                    customName: nil,
                    tags: [],
                ),
                at: 0
            )
            entries.insert(entry, at: 0)
        }

        trimAndPersist()
        NotificationCenter.default.post(name: .captureHistoryDidChange, object: self)
        return entries.first
    }

    /// Full-resolution screenshot for annotate / classify / preview. Recordings return their thumbnail.
    func fullImage(for id: UUID) -> NSImage? {
        if let cached = fullImageCache.object(forKey: id as NSUUID) {
            return cached
        }
        guard let stored = storedCaptures.first(where: { $0.id == id }) else {
            return entries.first(where: { $0.id == id })?.thumbnail
        }

        switch stored.kind {
        case .screenshot:
            let url = URL(fileURLWithPath: stored.path)
            guard let image = NSImage(contentsOf: url) else { return nil }
            fullImageCache.setObject(image, forKey: id as NSUUID)
            return image
        case .recording:
            return entries.first(where: { $0.id == id })?.thumbnail
        }
    }

    /// Sharper-than-list image for card grids. Downsamples from disk so Retina cards stay crisp
    /// without pulling every full screenshot into memory.
    func previewImage(for id: UUID, maxPixelSize: CGFloat = 720) -> NSImage? {
        let cacheKey = "\(id.uuidString):\(Int(maxPixelSize))" as NSString
        if let cached = previewImageCache.object(forKey: cacheKey) {
            return cached
        }

        guard let stored = storedCaptures.first(where: { $0.id == id }) else {
            return entries.first(where: { $0.id == id })?.thumbnail
        }

        let image: NSImage?
        switch stored.kind {
        case .screenshot:
            let url = URL(fileURLWithPath: stored.path)
            image = Self.downsampledImage(at: url, maxPixelSize: maxPixelSize)
                ?? NSImage(contentsOf: url)
        case .recording:
            if let thumbPath = stored.thumbnailPath {
                let url = URL(fileURLWithPath: thumbPath)
                image = Self.downsampledImage(at: url, maxPixelSize: maxPixelSize)
                    ?? NSImage(contentsOf: url)
            } else {
                image = entries.first(where: { $0.id == id })?.thumbnail
            }
        }

        if let image {
            previewImageCache.setObject(image, forKey: cacheKey)
        }
        return image
    }

    func entry(at index: Int) -> CaptureEntry? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    func previousScreenshot(excluding id: UUID?) -> (entry: CaptureEntry, image: NSImage)? {
        for entry in entriesInSaveRoot {
            guard entry.id != id else { continue }
            guard case .screenshot = entry.item else { continue }
            guard let image = fullImage(for: entry.id) else { continue }
            return (entry, image)
        }
        return nil
    }

    func screenshotChoices(excluding id: UUID?, limit: Int = 8) -> [(entry: CaptureEntry, image: NSImage)] {
        var results: [(CaptureEntry, NSImage)] = []
        for entry in entriesInSaveRoot {
            guard entry.id != id else { continue }
            guard case .screenshot = entry.item else { continue }
            guard let image = fullImage(for: entry.id) else { continue }
            results.append((entry, image))
            if results.count >= limit { break }
        }
        return results
    }

    /// On-disk path from the manifest (may be temporarily unreachable during iCloud moves).
    func storedFileURL(for id: UUID) -> URL? {
        guard let stored = storedCaptures.first(where: { $0.id == id }) else { return nil }
        // Pass isDirectory: false so URL construction doesn't lstat the path (scroll-hot).
        return URL(fileURLWithPath: stored.path, isDirectory: false)
    }

    func fileURL(for id: UUID) -> URL? {
        guard let url = storedFileURL(for: id) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func parentDirectoryURL(for id: UUID) -> URL? {
        fileURL(for: id)?.deletingLastPathComponent()
    }

    func isAtRootCapture(id: UUID) -> Bool {
        guard let parent = parentDirectoryURL(for: id) else { return false }
        return parent.standardizedFileURL == AppSettings.destinationFolderURL.standardizedFileURL
    }

    /// True when the capture file is inside the Settings save folder (root or a nested project folder).
    func isUnderSaveRoot(id: UUID) -> Bool {
        guard let fileURL = fileURL(for: id) else { return false }
        return Self.isURL(fileURL, under: AppSettings.destinationFolderURL)
    }

    static func isURL(_ url: URL, under root: URL) -> Bool {
        let filePath = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if filePath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath.hasPrefix(prefix)
    }

    @discardableResult
    func replaceScreenshot(id: UUID, with image: NSImage) -> Bool {
        guard let storedIndex = storedCaptures.firstIndex(where: { $0.id == id }),
              storedCaptures[storedIndex].kind == .screenshot,
              let entryIndex = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let url = URL(fileURLWithPath: storedCaptures[storedIndex].path)
        guard writePNG(image, to: url) else { return false }

        let entry = entries[entryIndex]
        let thumb = Self.downsampledImage(image, maxPixelSize: Self.thumbnailMaxPixelSize) ?? image
        if let thumbPath = saveThumbnail(thumb) {
            let stored = storedCaptures[storedIndex]
            // Drop previous screenshot thumb if we had one.
            if let oldThumb = stored.thumbnailPath, oldThumb != thumbPath.path {
                try? FileManager.default.removeItem(atPath: oldThumb)
            }
            storedCaptures[storedIndex] = StoredCapture(
                id: stored.id,
                createdAt: stored.createdAt,
                kind: stored.kind,
                path: stored.path,
                thumbnailPath: thumbPath.path,
                customName: stored.customName,
                tags: stored.tags,
                windowSignature: stored.windowSignature
            )
            persist()
        }
        fullImageCache.setObject(image, forKey: id as NSUUID)
        entries[entryIndex] = CaptureEntry(
            id: entry.id,
            createdAt: entry.createdAt,
            item: .screenshot(thumb),
            customName: entry.customName,
            tags: entry.tags
        )
        NotificationCenter.default.post(name: .captureHistoryDidChange, object: self)
        return true
    }

    @discardableResult
    func renameCapture(id: UUID, to newName: String) -> Bool {
        let sanitized = Self.sanitizedBaseName(newName)
        guard !sanitized.isEmpty else { return false }
        guard let storedIndex = storedCaptures.firstIndex(where: { $0.id == id }),
              let entryIndex = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let stored = storedCaptures[storedIndex]
        let oldURL = URL(fileURLWithPath: stored.path)
        let ext = oldURL.pathExtension
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent("\(sanitized).\(ext)")

        if oldURL != newURL {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: newURL.path) {
                return false
            }
            do {
                try fileManager.moveItem(at: oldURL, to: newURL)
            } catch {
                return false
            }
        }

        let updatedStored = StoredCapture(
            id: stored.id,
            createdAt: stored.createdAt,
            kind: stored.kind,
            path: newURL.path,
            thumbnailPath: stored.thumbnailPath,
            customName: sanitized,
            tags: stored.tags,
            windowSignature: stored.windowSignature
        )
        storedCaptures[storedIndex] = updatedStored

        let entry = entries[entryIndex]
        let updatedItem: CaptureItem
        switch entry.item {
        case .screenshot(let thumb):
            updatedItem = .screenshot(thumb)
        case .recording(_, let thumb):
            // Keep the in-memory recording URL in sync — preview/annotate use it.
            updatedItem = .recording(url: newURL, thumbnail: thumb)
        }
        entries[entryIndex] = CaptureEntry(
            id: entry.id,
            createdAt: entry.createdAt,
            item: updatedItem,
            customName: sanitized,
            tags: entry.tags
        )
        persist()
        NotificationCenter.default.post(name: .captureHistoryDidChange, object: self)
        return true
    }

    func moveCapture(id: UUID, toDirectory directory: URL) -> URL? {
        guard let storedIndex = storedCaptures.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let stored = storedCaptures[storedIndex]
        let oldURL = URL(fileURLWithPath: stored.path).standardizedFileURL
        let oldParent = oldURL.deletingLastPathComponent().standardizedFileURL
        let destination = directory.standardizedFileURL
        let newURL = CaptureNaming.uniqueURL(
            in: destination,
            preferredFilename: oldURL.lastPathComponent,
            excluding: oldURL
        ).standardizedFileURL

        if oldURL != newURL {
            let fileManager = FileManager.default
            do {
                try fileManager.moveItem(at: oldURL, to: newURL)
            } catch {
                return nil
            }
        }

        let updatedStored = StoredCapture(
            id: stored.id,
            createdAt: stored.createdAt,
            kind: stored.kind,
            path: newURL.path,
            thumbnailPath: stored.thumbnailPath,
            customName: stored.customName,
            tags: stored.tags,
            windowSignature: stored.windowSignature
        )
        storedCaptures[storedIndex] = updatedStored

        if let entryIndex = entries.firstIndex(where: { $0.id == id }) {
            let entry = entries[entryIndex]
            let updatedItem: CaptureItem
            switch entry.item {
            case .screenshot(let thumb):
                updatedItem = .screenshot(thumb)
            case .recording(_, let thumb):
                updatedItem = .recording(url: newURL, thumbnail: thumb)
            }
            entries[entryIndex] = CaptureEntry(
                id: entry.id,
                createdAt: entry.createdAt,
                item: updatedItem,
                customName: entry.customName,
                tags: entry.tags
            )
        }

        if oldParent != destination {
            Self.removeEmptyDirectoriesIfNeeded(startingAt: oldParent)
        }

        persist()
        NotificationCenter.default.post(name: .captureHistoryDidChange, object: self)
        return newURL
    }

    func remove(id: UUID) {
        guard let index = storedCaptures.firstIndex(where: { $0.id == id }) else { return }
        let stored = storedCaptures[index]
        let oldParent = URL(fileURLWithPath: stored.path)
            .deletingLastPathComponent()
            .standardizedFileURL
        trashStoredFiles(for: stored)
        Self.removeEmptyDirectoriesIfNeeded(startingAt: oldParent)

        storedCaptures.remove(at: index)
        entries.removeAll { $0.id == id }
        fullImageCache.removeObject(forKey: id as NSUUID)
        previewImageCache.removeObject(forKey: "\(id.uuidString):720" as NSString)
        persist()
        NotificationCenter.default.post(name: .captureHistoryDidChange, object: self)
    }

    /// Removes emptied project/subfolders under the save root after a capture leaves.
    /// Never deletes the destination root itself.
    private static func removeEmptyDirectoriesIfNeeded(startingAt directory: URL) {
        let root = AppSettings.destinationFolderURL.standardizedFileURL
        var current = directory.standardizedFileURL
        let fileManager = FileManager.default

        while current != root, isURL(current, under: root) {
            guard isEffectivelyEmptyDirectory(current) else { return }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            try? fileManager.removeItem(at: current)
            current = parent
        }
    }

    /// True when the directory has no real contents (ignores `.DS_Store`).
    private static func isEffectivelyEmptyDirectory(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        return contents.allSatisfy { $0.lastPathComponent == ".DS_Store" }
    }

    // MARK: - Tags

    func tags(for id: UUID) -> [CaptureTag] {
        entries.first(where: { $0.id == id })?.tags ?? []
    }

    @discardableResult
    func addTag(id: UUID, kind: CaptureTagKind, name: String) -> CaptureTag? {
        if kind == .project {
            return setProjectTag(id: id, name: name) ? tags(for: id).first(where: { $0.kind == .project }) : nil
        }

        let normalized = CaptureTag.normalizeName(name)
        guard !normalized.isEmpty else { return nil }

        var created: CaptureTag?
        let ok = mutateTags(id: id) { tags in
            if tags.contains(where: {
                $0.kind == kind && $0.name.caseInsensitiveCompare(normalized) == .orderedSame
            }) {
                return
            }
            let tag = CaptureTag(kind: kind, name: normalized)
            tags.append(tag)
            created = tag
        }
        return ok ? created : nil
    }

    @discardableResult
    func removeTag(id: UUID, tagID: UUID) -> Bool {
        guard let tag = tags(for: id).first(where: { $0.id == tagID }) else { return false }
        if tag.kind == .project {
            return clearProjectTag(id: id)
        }
        return mutateTags(id: id) { tags in
            tags.removeAll { $0.id == tagID }
        }
    }

    /// Upserts the sole project tag and moves the file into that project folder.
    @discardableResult
    func setProjectTag(id: UUID, name: String) -> Bool {
        let normalized = CaptureTag.normalizeName(name)
        guard !normalized.isEmpty else { return false }

        let destination = CaptureDestination(
            productFolder: normalized,
            subfolder: nil,
            confidence: 1.0,
            source: .windowMetadata
        )
        guard CaptureOrganizer.moveCapture(id: id, to: destination) else { return false }

        return mutateTags(id: id, notify: true) { tags in
            tags.removeAll { $0.kind == .project }
            tags.insert(CaptureTag(kind: .project, name: normalized), at: 0)
        }
    }

    /// Removes the project tag and moves the file back to the root save folder.
    @discardableResult
    func clearProjectTag(id: UUID) -> Bool {
        let root = AppSettings.destinationFolderURL
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return false
        }

        if !isAtRootCapture(id: id) {
            guard moveCapture(id: id, toDirectory: root) != nil else { return false }
        }

        return mutateTags(id: id, notify: true) { tags in
            tags.removeAll { $0.kind == .project }
        }
    }

    /// Aligns the project tag with the capture's current parent folder (after moves / reverts).
    func syncProjectTagFromFolder(id: UUID) {
        guard let parent = parentDirectoryURL(for: id) else { return }
        let root = AppSettings.destinationFolderURL.standardizedFileURL

        if parent.standardizedFileURL == root {
            _ = mutateTags(id: id) { tags in
                tags.removeAll { $0.kind == .project }
            }
            return
        }

        let folderName = CaptureTag.normalizeName(parent.lastPathComponent)
        guard !folderName.isEmpty else { return }
        _ = mutateTags(id: id) { tags in
            tags.removeAll { $0.kind == .project }
            tags.insert(CaptureTag(kind: .project, name: folderName), at: 0)
        }
    }

    /// After a project folder rename on disk: rewrite stored paths under the old
    /// folder and update matching project tags. Single persist / notify.
    @discardableResult
    func renameProject(from oldName: String, to newName: String) -> Bool {
        let normalizedOld = CaptureTag.normalizeName(oldName)
        let normalizedNew = CaptureTag.normalizeName(newName)
        guard !normalizedOld.isEmpty, !normalizedNew.isEmpty else { return false }
        if normalizedOld == normalizedNew { return true }

        let root = AppSettings.destinationFolderURL.standardizedFileURL
        let oldDirectory = root
            .appendingPathComponent(normalizedOld, isDirectory: true)
            .standardizedFileURL
        let newDirectory = root
            .appendingPathComponent(normalizedNew, isDirectory: true)
            .standardizedFileURL
        let oldPrefix = oldDirectory.path.hasSuffix("/")
            ? oldDirectory.path
            : oldDirectory.path + "/"
        var didChange = false

        for index in storedCaptures.indices {
            let stored = storedCaptures[index]
            let oldURL = URL(fileURLWithPath: stored.path).standardizedFileURL
            let parent = oldURL.deletingLastPathComponent().standardizedFileURL
            let underOldFolder = parent == oldDirectory
                || oldURL.path.hasPrefix(oldPrefix)

            var newPath = stored.path
            if underOldFolder {
                let suffix = String(oldURL.path.dropFirst(oldDirectory.path.count))
                newPath = newDirectory.path + suffix
            }

            var tags = stored.tags
            var tagsChanged = false
            if let projectIndex = tags.firstIndex(where: {
                $0.kind == .project
                    && $0.name.caseInsensitiveCompare(normalizedOld) == .orderedSame
            }) {
                tags[projectIndex] = CaptureTag(
                    id: tags[projectIndex].id,
                    kind: .project,
                    name: normalizedNew
                )
                tags = CaptureTag.sorted(tags)
                tagsChanged = true
            } else if underOldFolder {
                tags.removeAll { $0.kind == .project }
                tags.insert(CaptureTag(kind: .project, name: normalizedNew), at: 0)
                tags = CaptureTag.sorted(tags)
                tagsChanged = true
            }

            guard newPath != stored.path || tagsChanged else { continue }
            didChange = true

            storedCaptures[index] = StoredCapture(
                id: stored.id,
                createdAt: stored.createdAt,
                kind: stored.kind,
                path: newPath,
                thumbnailPath: stored.thumbnailPath,
                customName: stored.customName,
                tags: tags,
                windowSignature: stored.windowSignature
            )

            if let entryIndex = entries.firstIndex(where: { $0.id == stored.id }) {
                let entry = entries[entryIndex]
                let updatedItem: CaptureItem
                switch entry.item {
                case .screenshot(let thumb):
                    updatedItem = .screenshot(thumb)
                case .recording(_, let thumb):
                    updatedItem = .recording(
                        url: URL(fileURLWithPath: newPath),
                        thumbnail: thumb
                    )
                }
                entries[entryIndex] = CaptureEntry(
                    id: entry.id,
                    createdAt: entry.createdAt,
                    item: updatedItem,
                    customName: entry.customName,
                    tags: tags
                )
            }
        }

        guard didChange else { return true }
        persist()
        NotificationCenter.default.post(name: .captureHistoryDidChange, object: self)
        return true
    }

    @discardableResult
    private func mutateTags(
        id: UUID,
        notify: Bool = true,
        _ transform: (inout [CaptureTag]) -> Void
    ) -> Bool {
        guard let storedIndex = storedCaptures.firstIndex(where: { $0.id == id }),
              let entryIndex = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let stored = storedCaptures[storedIndex]
        var tags = stored.tags
        transform(&tags)
        // Project is the on-disk folder — keep at most one.
        if let project = tags.first(where: { $0.kind == .project }) {
            tags.removeAll { $0.kind == .project }
            tags.insert(project, at: 0)
        }
        tags = CaptureTag.sorted(tags)

        storedCaptures[storedIndex] = StoredCapture(
            id: stored.id,
            createdAt: stored.createdAt,
            kind: stored.kind,
            path: stored.path,
            thumbnailPath: stored.thumbnailPath,
            customName: stored.customName,
            tags: tags,
            windowSignature: stored.windowSignature
        )

        let entry = entries[entryIndex]
        entries[entryIndex] = CaptureEntry(
            id: entry.id,
            createdAt: entry.createdAt,
            item: entry.item,
            customName: entry.customName,
            tags: tags
        )

        persist()
        if notify {
            NotificationCenter.default.post(name: .captureHistoryDidChange, object: self)
        }
        return true
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }

        if let stored = try? JSONDecoder().decode([StoredCapture].self, from: data) {
            rebuildEntries(from: stored)
            return
        }

        // Migrate legacy manifest without id/createdAt.
        struct LegacyStoredCapture: Codable {
            enum Kind: String, Codable { case screenshot, recording }
            let kind: Kind
            let path: String
            let thumbnailPath: String?
        }

        guard let legacy = try? JSONDecoder().decode([LegacyStoredCapture].self, from: data) else { return }

        var migrated: [StoredCapture] = []
        for (index, entry) in legacy.enumerated() {
            migrated.append(
                StoredCapture(
                    id: UUID(),
                    createdAt: Date().addingTimeInterval(-Double(index) * 60),
                    kind: StoredCapture.Kind(rawValue: entry.kind.rawValue) ?? .screenshot,
                    path: entry.path,
                    thumbnailPath: entry.thumbnailPath,
                    customName: nil,
                    tags: [],
                )
            )
        }
        rebuildEntries(from: migrated)
        persist()
    }

    private func rebuildEntries(from stored: [StoredCapture]) {
        var loadedEntries: [CaptureEntry] = []
        var validStored: [StoredCapture] = []
        var didMutateStored = false

        for entry in stored {
            var resolved = Self.rewritingLegacyAppSupportPaths(in: entry)
            if resolved.path != entry.path || resolved.thumbnailPath != entry.thumbnailPath {
                didMutateStored = true
            }

            // Stale absolute thumb paths (e.g. after rename) used to force a main-thread
            // video frame extract for every recording on launch.
            if let thumbPath = resolved.thumbnailPath,
               !FileManager.default.fileExists(atPath: thumbPath) {
                resolved = StoredCapture(
                    id: resolved.id,
                    createdAt: resolved.createdAt,
                    kind: resolved.kind,
                    path: resolved.path,
                    thumbnailPath: nil,
                    customName: resolved.customName,
                    tags: resolved.tags,
                    windowSignature: resolved.windowSignature
                )
                didMutateStored = true
            }

            guard let item = captureItem(from: resolved) else {
                // Keep unreachable rows (iCloud still hydrating, temporary unmount).
                // Dropping them here permanently empties Recents after a restart blip.
                validStored.append(resolved)
                continue
            }

            // Backfill missing thumbnails so relaunch stays cheap and avoids
            // regenerating frames from video on every launch.
            if resolved.thumbnailPath == nil,
               let thumbPath = saveThumbnail(item.thumbnail) {
                resolved = StoredCapture(
                    id: resolved.id,
                    createdAt: resolved.createdAt,
                    kind: resolved.kind,
                    path: resolved.path,
                    thumbnailPath: thumbPath.path,
                    customName: resolved.customName,
                    tags: resolved.tags,
                    windowSignature: resolved.windowSignature
                )
                didMutateStored = true
            }

            let synthesized = synthesizeProjectTagIfNeeded(for: resolved)
            if synthesized.tags != resolved.tags {
                resolved = synthesized
                didMutateStored = true
            }

            loadedEntries.append(
                CaptureEntry(
                    id: resolved.id,
                    createdAt: resolved.createdAt,
                    item: item,
                    customName: resolved.customName,
                    tags: resolved.tags
                )
            )
            validStored.append(resolved)
        }

        entries = loadedEntries
        storedCaptures = validStored

        if didMutateStored || validStored.count != stored.count {
            persist()
        }
    }

    /// If the file lives in a project subfolder and has no project tag, synthesize one from the folder name.
    private func synthesizeProjectTagIfNeeded(for stored: StoredCapture) -> StoredCapture {
        guard !stored.tags.contains(where: { $0.kind == .project }) else { return stored }

        let fileURL = URL(fileURLWithPath: stored.path)
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL
        let root = AppSettings.destinationFolderURL.standardizedFileURL
        guard parent != root else { return stored }

        let folderName = CaptureTag.normalizeName(parent.lastPathComponent)
        guard !folderName.isEmpty else { return stored }

        var tags = stored.tags
        tags.insert(CaptureTag(kind: .project, name: folderName), at: 0)
        return StoredCapture(
            id: stored.id,
            createdAt: stored.createdAt,
            kind: stored.kind,
            path: stored.path,
            thumbnailPath: stored.thumbnailPath,
            customName: stored.customName,
            tags: CaptureTag.sorted(tags),
            windowSignature: stored.windowSignature
        )
    }

    private func captureItem(from entry: StoredCapture) -> CaptureItem? {
        let fileManager = FileManager.default

        switch entry.kind {
        case .screenshot:
            let url = URL(fileURLWithPath: entry.path)
            guard fileManager.fileExists(atPath: url.path) else { return nil }

            if let thumbPath = entry.thumbnailPath,
               fileManager.fileExists(atPath: thumbPath),
               let thumb = NSImage(contentsOf: URL(fileURLWithPath: thumbPath)) {
                return .screenshot(thumb)
            }

            guard let thumb = Self.downsampledImage(at: url, maxPixelSize: Self.thumbnailMaxPixelSize) else {
                return nil
            }
            return .screenshot(thumb)

        case .recording:
            let url = URL(fileURLWithPath: entry.path)
            guard fileManager.fileExists(atPath: url.path) else { return nil }

            if let thumbPath = entry.thumbnailPath,
               fileManager.fileExists(atPath: thumbPath),
               let thumb = NSImage(contentsOf: URL(fileURLWithPath: thumbPath)) {
                return .recording(url: url, thumbnail: thumb)
            }

            guard let thumb = recordingThumbnail(for: url) else { return nil }
            return .recording(url: url, thumbnail: thumb)
        }
    }

    /// Async variant used by folder ingest so video frame extracts don't stall the main actor.
    private func captureItemAsync(from entry: StoredCapture) async -> CaptureItem? {
        let fileManager = FileManager.default

        switch entry.kind {
        case .screenshot:
            return captureItem(from: entry)

        case .recording:
            let url = URL(fileURLWithPath: entry.path)
            guard fileManager.fileExists(atPath: url.path) else { return nil }

            if let thumbPath = entry.thumbnailPath,
               fileManager.fileExists(atPath: thumbPath),
               let thumb = NSImage(contentsOf: URL(fileURLWithPath: thumbPath)) {
                return .recording(url: url, thumbnail: thumb)
            }

            guard let thumb = await recordingThumbnailAsync(for: url) else { return nil }
            return .recording(url: url, thumbnail: thumb)
        }
    }

    /// Picks up capture files that already sit under the current destination folder
    /// but were never added through the app — e.g. the user just switched Settings to
    /// a folder that already has screenshots/recordings in it (moved in via Finder, or
    /// captures made in an earlier session that aged out of the in-memory history).
    /// Without this, switching the save location wouldn't make the Library reflect what's
    /// actually in that folder until those files were touched by the app again.
    ///
    /// Runs off the interactive path: video frame extracts must not block the main actor
    /// (Show All used to freeze while ingesting dozens of unindexed recordings).
    func scheduleReconcileWithDisk() {
        guard reconcileTask == nil else { return }
        reconcileTask = Task { @MainActor in
            defer { reconcileTask = nil }
            let didAdd = await self.reconcileWithDiskAsync()
            if didAdd {
                NotificationCenter.default.post(name: .captureHistoryDidChange, object: self)
            }
        }
    }

    /// Sync wrapper for older call sites — schedules async ingest and returns immediately.
    @discardableResult
    func reconcileWithDisk() -> Bool {
        scheduleReconcileWithDisk()
        return false
    }

    private func reconcileWithDiskAsync() async -> Bool {
        // A recording in progress writes straight into the destination folder as it
        // grows — scanning mid-write would add a broken/duplicate entry for a file
        // `CaptureHistory.add` is about to claim properly once it finishes.
        guard !RecordingEngine.shared.isRecording else { return false }

        let root = AppSettings.destinationFolderURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return false
        }

        var knownPaths = Set(storedCaptures.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        var didAdd = false

        // Avoid for-in: DirectoryEnumerator.makeIterator is unavailable in async (Swift 6).
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            if values?.isDirectory == true { continue }

            let standardized = url.standardizedFileURL
            guard !knownPaths.contains(standardized.path) else { continue }

            let kind: StoredCapture.Kind
            switch url.pathExtension.lowercased() {
            case "png", "jpg", "jpeg": kind = .screenshot
            case "mp4", "mov": kind = .recording
            default: continue
            }

            // Let the Library / menu paint between video frame extracts.
            await Task.yield()

            let createdAt = values?.creationDate ?? Date()
            let provisional = StoredCapture(
                id: UUID(),
                createdAt: createdAt,
                kind: kind,
                path: standardized.path,
                thumbnailPath: nil,
                customName: nil,
                tags: [],
            )
            guard let item = await captureItemAsync(from: provisional) else { continue }

            let stored = synthesizeProjectTagIfNeeded(for: StoredCapture(
                id: provisional.id,
                createdAt: provisional.createdAt,
                kind: provisional.kind,
                path: provisional.path,
                thumbnailPath: saveThumbnail(item.thumbnail)?.path,
                customName: nil,
                tags: [],
                windowSignature: provisional.windowSignature
            ))

            storedCaptures.append(stored)
            entries.append(
                CaptureEntry(
                    id: stored.id,
                    createdAt: stored.createdAt,
                    item: item,
                    customName: stored.customName,
                    tags: stored.tags
                )
            )
            knownPaths.insert(standardized.path)
            didAdd = true
        }

        guard didAdd else { return false }

        // Keep the newest-first ordering used everywhere else in history.
        storedCaptures.sort { $0.createdAt > $1.createdAt }
        entries.sort { $0.createdAt > $1.createdAt }
        persist()
        return true
    }

    private func trimAndPersist() {
        if entries.count > Self.maxStored {
            let evicted = storedCaptures.suffix(from: Self.maxStored)
            for entry in evicted {
                fullImageCache.removeObject(forKey: entry.id as NSUUID)
                previewImageCache.removeObject(forKey: "\(entry.id.uuidString):720" as NSString)
                // Index-only eviction: never delete the user's capture file. The library
                // reconciles from disk, so files past the manifest cap remain on disk and
                // can reappear. Only app-owned thumbnails are safe to drop.
                removeThumbnailIfPresent(for: entry)
            }
            entries = Array(entries.prefix(Self.maxStored))
            storedCaptures = Array(storedCaptures.prefix(Self.maxStored))
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storedCaptures) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func removeThumbnailIfPresent(for entry: StoredCapture) {
        guard let thumbPath = entry.thumbnailPath else { return }
        try? FileManager.default.removeItem(atPath: thumbPath)
    }

    private func trashStoredFiles(for entry: StoredCapture) {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: entry.path)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.trashItem(at: url, resultingItemURL: nil)
        }
        if let thumbPath = entry.thumbnailPath {
            let thumbURL = URL(fileURLWithPath: thumbPath)
            if fileManager.fileExists(atPath: thumbURL.path) {
                try? fileManager.trashItem(at: thumbURL, resultingItemURL: nil)
            }
        }
    }

    // MARK: - File helpers

    private static func sanitizedBaseName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let invalid = CharacterSet(charactersIn: ":/\\")
        return trimmed
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private func saveScreenshot(_ image: NSImage, at date: Date) -> URL? {
        let destinationDirectory = AppSettings.destinationFolderURL
        do {
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let url = CaptureNaming.uniqueURL(
            in: destinationDirectory,
            preferredFilename: CaptureNaming.screenshotFilename(at: date)
        )
        guard writePNG(image, to: url) else { return nil }
        return url
    }

    private func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }

        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func saveThumbnail(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let url = storageDirectory.appendingPathComponent("thumb-\(UUID().uuidString).png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func recordingThumbnail(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Prefer a nearby keyframe so local loads stay cheap.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // Await image(at:) at .high instead of blocking on generateCGImageAsynchronously's
        // Default-QoS callback (priority inversion from User-interactive callers).
        let result = ThumbnailResult()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .high) {
            defer { semaphore.signal() }
            do {
                let (cgImage, _) = try await generator.image(at: .zero)
                result.cgImage = cgImage
            } catch {
                result.cgImage = nil
            }
        }
        semaphore.wait()
        guard let cgImage = result.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    private func recordingThumbnailAsync(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return NSImage(cgImage: cgImage, size: .zero)
        } catch {
            return nil
        }
    }

    // MARK: - Downsampling

    private static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        return downsampledImage(from: source, maxPixelSize: maxPixelSize)
    }

    private static func downsampledImage(_ image: NSImage, maxPixelSize: CGFloat) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return image.thumbnail(size: NSSize(width: maxPixelSize, height: maxPixelSize))
        }
        return downsampledImage(from: source, maxPixelSize: maxPixelSize)
    }

    private static func downsampledImage(from source: CGImageSource, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

private final class ThumbnailResult: @unchecked Sendable {
    nonisolated(unsafe) var cgImage: CGImage?
}
