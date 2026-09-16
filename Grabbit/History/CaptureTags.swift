//
//  CaptureTags.swift
//  Grabbit
//
//  Typed tags for Capture Library organization. Project is hybrid: a tag and a folder.
//

import Foundation

enum CaptureTagKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case project
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .project: return "Project"
        case .custom: return "Custom"
        }
    }

    /// Sort order in the tag bar: Project → Custom.
    var sortOrder: Int {
        switch self {
        case .project: return 0
        case .custom: return 1
        }
    }
}

struct CaptureTag: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: CaptureTagKind
    var name: String

    init(id: UUID = UUID(), kind: CaptureTagKind, name: String) {
        self.id = id
        self.kind = kind
        self.name = CaptureTag.normalizeName(name)
    }

    static func normalizeName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(80))
    }

    static func sorted(_ tags: [CaptureTag]) -> [CaptureTag] {
        tags.sorted { lhs, rhs in
            if lhs.kind.sortOrder != rhs.kind.sortOrder {
                return lhs.kind.sortOrder < rhs.kind.sortOrder
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

}

/// Decodes a tag while dropping unknown kinds (e.g. legacy `component`).
struct LossyCaptureTag: Decodable {
    let tag: CaptureTag?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = CaptureTagKind(rawValue: rawKind) else {
            tag = nil
            return
        }
        tag = CaptureTag(id: id, kind: kind, name: name)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name
    }
}
