//
//  AIConnection.swift
//  Grabbit
//
//  Apple Intelligence (free, on-device) + optional BYOK cloud (Gemini) for stronger
//  Auto Organize suggestions. Cloud key lives in Keychain only.
//

import Foundation

enum AIConnection {
    static let didChangeNotification = Notification.Name("AIConnectionDidChange")

    private static let keychainService = "ewew.design.Grabbit.ai"
    private static let geminiAccount = "geminiAPIKey"

    /// Free on-device Foundation Models path.
    static var isAppleIntelligenceAvailable: Bool {
        CaptureClassifierLLM.isAvailable
    }

    /// User supplied a Gemini API key for enhanced organize.
    static var isCloudConnected: Bool {
        (try? geminiAPIKey())?.isEmpty == false
    }

    /// Prefer cloud when connected — stronger multimodal naming/project match.
    static var prefersEnhancedCloudOrganize: Bool {
        isCloudConnected
    }

    static func geminiAPIKey() throws -> String? {
        let raw = try KeychainStore.string(service: keychainService, account: geminiAccount)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func connectGemini(apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try disconnectGemini()
            return
        }
        try KeychainStore.setString(trimmed, service: keychainService, account: geminiAccount)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func disconnectGemini() throws {
        try KeychainStore.setString(nil, service: keychainService, account: geminiAccount)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
