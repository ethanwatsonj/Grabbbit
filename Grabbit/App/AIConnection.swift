//
//  AIConnection.swift
//  Grabbit
//
//  Apple Intelligence (free, on-device) + optional BYOK cloud (Gemini) for stronger
//  Auto Organize suggestions. Cloud key lives in Keychain only. When Gemini is
//  connected, Settings can prefer Apple FM or Gemini; preference is UserDefaults.
//

import Foundation

/// Auto Organize AI backend when a Gemini key is connected.
enum OrganizeAIProvider: String, CaseIterable, Identifiable {
    case appleFM
    case gemini

    var id: String { rawValue }

    var settingsLabel: String {
        switch self {
        case .appleFM: return "Apple FM"
        case .gemini: return "Gemini"
        }
    }
}

enum AIConnection {
    static let didChangeNotification = Notification.Name("AIConnectionDidChange")

    private static let keychainService = "ewew.design.Grabbit.ai"
    private static let geminiAccount = "geminiAPIKey"
    private static let organizeProviderKey = "organizeAIProvider"

    /// Free on-device Foundation Models path.
    static var isAppleIntelligenceAvailable: Bool {
        CaptureClassifierLLM.isAvailable
    }

    /// User supplied a Gemini API key for enhanced organize.
    static var isCloudConnected: Bool {
        (try? geminiAPIKey())?.isEmpty == false
    }

    /// Persisted provider choice (shown only while Gemini is connected).
    /// Defaults to Gemini so connecting a key matches prior “prefer cloud” behavior.
    static var preferredOrganizeProvider: OrganizeAIProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: organizeProviderKey)
            return OrganizeAIProvider(rawValue: raw ?? "") ?? .gemini
        }
        set {
            guard newValue != preferredOrganizeProvider else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: organizeProviderKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Use Gemini for Auto Organize only when connected and preferred.
    static var prefersEnhancedCloudOrganize: Bool {
        isCloudConnected && preferredOrganizeProvider == .gemini
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
        GeminiUsage.clearLocalUsage()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
