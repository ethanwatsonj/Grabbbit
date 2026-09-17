//
//  CaptureLibraryOrganizer.swift
//  Grabbit
//

import Foundation

struct CaptureLocationSnapshot: Equatable {
    let name: String
    let directoryURL: URL
}

enum CaptureLibraryOrganizer {
    /// Project folders under the Settings save location — on-disk children of the
    /// destination root (including empty folders), plus any capture parent folders.
    static func existingProjectNames() -> [String] {
        var names = Set<String>()
        let root = AppSettings.destinationFolderURL
        let fileManager = FileManager.default

        if let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in children {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                guard isDirectory else { continue }
                let name = CaptureTag.normalizeName(url.lastPathComponent)
                guard !name.isEmpty else { continue }
                names.insert(name)
            }
        }

        let history = CaptureHistory.shared
        for entry in history.entriesInSaveRoot {
            guard !history.isAtRootCapture(id: entry.id),
                  let parent = history.parentDirectoryURL(for: entry.id) else {
                continue
            }
            let name = CaptureTag.normalizeName(parent.lastPathComponent)
            guard !name.isEmpty else { continue }
            names.insert(name)
        }

        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Distinct tag names of the given kind across captures in the Settings save folder.
    static func existingTagNames(kind: CaptureTagKind) -> [String] {
        var names = Set<String>()
        for entry in CaptureHistory.shared.entriesInSaveRoot {
            for tag in entry.tags where tag.kind == kind {
                let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                names.insert(name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func sanitizedProjectName(_ raw: String) -> String? {
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

    /// Renames a project folder under the save root and rewrites matching capture
    /// paths / project tags. Returns `false` when the name is invalid or conflicts.
    @discardableResult
    static func renameProject(from oldName: String, to rawNewName: String) -> Bool {
        let normalizedOld = CaptureTag.normalizeName(oldName)
        guard !normalizedOld.isEmpty,
              normalizedOld.caseInsensitiveCompare("None") != .orderedSame,
              let cleanedNew = sanitizedProjectName(rawNewName) else {
            return false
        }
        let normalizedNew = CaptureTag.normalizeName(cleanedNew)
        guard !normalizedNew.isEmpty else { return false }
        if normalizedOld == normalizedNew { return true }

        let root = AppSettings.destinationFolderURL.standardizedFileURL
        let oldURL = root.appendingPathComponent(normalizedOld, isDirectory: true)
            .standardizedFileURL
        let newURL = root.appendingPathComponent(normalizedNew, isDirectory: true)
            .standardizedFileURL
        let fileManager = FileManager.default
        let oldExists = fileManager.fileExists(atPath: oldURL.path)
        let newExists = fileManager.fileExists(atPath: newURL.path)
        let isCaseOnlyChange = normalizedOld.caseInsensitiveCompare(normalizedNew) == .orderedSame

        if oldExists {
            if newExists, !isCaseOnlyChange {
                return false
            }
            do {
                if isCaseOnlyChange {
                    let tempURL = root
                        .appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
                        .standardizedFileURL
                    try fileManager.moveItem(at: oldURL, to: tempURL)
                    try fileManager.moveItem(at: tempURL, to: newURL)
                } else {
                    try fileManager.moveItem(at: oldURL, to: newURL)
                }
            } catch {
                return false
            }
        } else if newExists, !isCaseOnlyChange {
            // Tags-only rename into an existing folder name — refuse to merge.
            return false
        }

        CaptureDestinationMappingCache.shared.renameProductFolder(
            from: normalizedOld,
            to: normalizedNew
        )
        return CaptureHistory.shared.renameProject(from: normalizedOld, to: normalizedNew)
    }

    @discardableResult
    static func apply(
        suggestion: RenameSuggestion,
        to entry: CaptureEntry,
        windowInfo: WindowSignature?
    ) -> CaptureLocationSnapshot? {
        guard let snapshot = snapshot(for: entry) else { return nil }

        if suggestion.hasRename, let name = suggestion.suggestedName {
            _ = CaptureHistory.shared.renameCapture(id: entry.id, to: name)
        }

        if suggestion.hasProject, let project = suggestion.suggestedProject {
            // Sole project tag + move into `{saveRoot}/{project}/`.
            _ = CaptureHistory.shared.setProjectTag(id: entry.id, name: project)
            if let windowInfo {
                let destination = CaptureDestination(
                    productFolder: project,
                    subfolder: nil,
                    confidence: suggestion.confidence,
                    source: .localLLM
                )
                CaptureDestinationMappingCache.shared.confirm(signature: windowInfo, destination: destination)
            }
        }

        return snapshot
    }

    static func revert(snapshot: CaptureLocationSnapshot, captureID: UUID) {
        _ = CaptureHistory.shared.renameCapture(id: captureID, to: snapshot.name)
        _ = CaptureHistory.shared.moveCapture(id: captureID, toDirectory: snapshot.directoryURL)
        CaptureHistory.shared.syncProjectTagFromFolder(id: captureID)
    }

    static func snapshot(for entry: CaptureEntry) -> CaptureLocationSnapshot? {
        guard let fileURL = CaptureHistory.shared.fileURL(for: entry.id) else { return nil }
        return CaptureLocationSnapshot(
            name: entry.displayName,
            directoryURL: fileURL.deletingLastPathComponent()
        )
    }
}
