//
//  GeminiUsage.swift
//  Grabbit
//
//  Surfaces Gemini usage/limits for Settings. The Generative Language API key
//  does not expose account-wide quota counters; we show:
//  1) Rate-limit headers when Google returns them (often absent on free tier)
//  2) Model token limits for the Flash models Grabbit tries
//  3) Local Auto Organize request/token totals for today (tracked from responses)
//  Full project quota remains in Google AI Studio.
//

import Foundation
import os

struct GeminiUsageSnapshot: Equatable {
    enum Status: Equatable {
        case idle
        case loading
        case ready
        case invalidKey
        case rateLimited(retryHint: String?)
        case unavailable(message: String)
    }

    var status: Status = .idle
    var modelName: String?
    var inputTokenLimit: Int?
    var outputTokenLimit: Int?
    /// Present only when Google emits x-ratelimit-* on the models list response.
    var rateLimitRemaining: Int?
    var rateLimitLimit: Int?
    var rateLimitReset: String?
    var localRequestsToday: Int = 0
    var localTokensToday: Int = 0
    var fetchedAt: Date?
}

enum GeminiUsage {
    static let didChangeNotification = Notification.Name("GeminiUsageDidChange")
    static let aiStudioUsageURL = URL(string: "https://aistudio.google.com/usage")!

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Grabbit",
        category: "GeminiUsage"
    )

    private static let defaults = UserDefaults.standard
    private static let requestsKey = "gemini.localRequests.day"
    private static let tokensKey = "gemini.localTokens.day"
    private static let dayKey = "gemini.localUsage.dayStamp"

    private static let preferredModelFragments = [
        "gemini-2.0-flash",
        "gemini-2.5-flash",
        "gemini-1.5-flash",
    ]

    // MARK: - Local counters (from Auto Organize generateContent)

    static func localUsageToday() -> (requests: Int, tokens: Int) {
        rollLocalCountersIfNeeded()
        return (
            defaults.integer(forKey: requestsKey),
            defaults.integer(forKey: tokensKey)
        )
    }

    static func recordGenerateContentSuccess(
        http: HTTPURLResponse,
        responseBody: Data
    ) {
        rollLocalCountersIfNeeded()
        defaults.set(defaults.integer(forKey: requestsKey) + 1, forKey: requestsKey)

        if let tokens = totalTokenCount(from: responseBody), tokens > 0 {
            defaults.set(defaults.integer(forKey: tokensKey) + tokens, forKey: tokensKey)
        }

        // Keep the freshest rate-limit snapshot from live organize calls too.
        if let remaining = intHeader(http, names: ["x-ratelimit-remaining", "X-RateLimit-Remaining"]),
           let limit = intHeader(http, names: ["x-ratelimit-limit", "X-RateLimit-Limit"]) {
            LastRateLimit.remaining = remaining
            LastRateLimit.limit = limit
            LastRateLimit.reset = stringHeader(
                http,
                names: ["x-ratelimit-reset", "X-RateLimit-Reset"]
            )
            LastRateLimit.updatedAt = Date()
        }

        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func recordGenerateContentFailure(http: HTTPURLResponse, responseBody: Data) {
        if http.statusCode == 429 {
            LastRateLimit.remaining = 0
            if let limit = intHeader(http, names: ["x-ratelimit-limit", "X-RateLimit-Limit"]) {
                LastRateLimit.limit = limit
            }
            LastRateLimit.reset = stringHeader(
                http,
                names: ["x-ratelimit-reset", "X-RateLimit-Reset"]
            ) ?? retryDelayHint(from: responseBody)
            LastRateLimit.updatedAt = Date()
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static func clearLocalUsage() {
        defaults.removeObject(forKey: requestsKey)
        defaults.removeObject(forKey: tokensKey)
        defaults.removeObject(forKey: dayKey)
        LastRateLimit.clear()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: - Live fetch for Settings

    static func fetchSnapshot() async -> GeminiUsageSnapshot {
        var snapshot = GeminiUsageSnapshot()
        let local = localUsageToday()
        snapshot.localRequestsToday = local.requests
        snapshot.localTokensToday = local.tokens

        if let remaining = LastRateLimit.remaining, let limit = LastRateLimit.limit {
            snapshot.rateLimitRemaining = remaining
            snapshot.rateLimitLimit = limit
            snapshot.rateLimitReset = LastRateLimit.reset
        }

        guard let apiKey = try? AIConnection.geminiAPIKey(), !apiKey.isEmpty else {
            snapshot.status = .unavailable(message: "Connect a Gemini API key to see usage.")
            return snapshot
        }

        snapshot.status = .loading

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=100") else {
            snapshot.status = .unavailable(message: "Couldn’t build Gemini models request.")
            return snapshot
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                snapshot.status = .unavailable(message: "Unexpected response from Gemini.")
                return snapshot
            }

            if let remaining = intHeader(http, names: ["x-ratelimit-remaining", "X-RateLimit-Remaining"]) {
                snapshot.rateLimitRemaining = remaining
                LastRateLimit.remaining = remaining
            }
            if let limit = intHeader(http, names: ["x-ratelimit-limit", "X-RateLimit-Limit"]) {
                snapshot.rateLimitLimit = limit
                LastRateLimit.limit = limit
            }
            if let reset = stringHeader(http, names: ["x-ratelimit-reset", "X-RateLimit-Reset"]) {
                snapshot.rateLimitReset = reset
                LastRateLimit.reset = reset
            }
            if snapshot.rateLimitRemaining != nil || snapshot.rateLimitLimit != nil {
                LastRateLimit.updatedAt = Date()
            }

            switch http.statusCode {
            case 200...299:
                if let model = preferredModel(from: data) {
                    snapshot.modelName = model.displayName ?? model.name
                    snapshot.inputTokenLimit = model.inputTokenLimit
                    snapshot.outputTokenLimit = model.outputTokenLimit
                }
                snapshot.status = .ready
                snapshot.fetchedAt = Date()
            case 400, 401, 403:
                snapshot.status = .invalidKey
            case 429:
                snapshot.status = .rateLimited(retryHint: retryDelayHint(from: data) ?? snapshot.rateLimitReset)
            default:
                let snippet = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(160) ?? ""
                logger.error("Gemini models HTTP \(http.statusCode): \(snippet, privacy: .public)")
                snapshot.status = .unavailable(message: "Gemini returned HTTP \(http.statusCode).")
            }
        } catch {
            snapshot.status = .unavailable(message: error.localizedDescription)
        }

        return snapshot
    }

    // MARK: - Parsing helpers

    private struct CatalogModel {
        var name: String
        var displayName: String?
        var inputTokenLimit: Int?
        var outputTokenLimit: Int?
    }

    private static func preferredModel(from data: Data) -> CatalogModel? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = root["models"] as? [[String: Any]]
        else {
            return nil
        }

        let parsed: [CatalogModel] = models.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let methods = entry["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent") else { return nil }
            return CatalogModel(
                name: name.replacingOccurrences(of: "models/", with: ""),
                displayName: entry["displayName"] as? String,
                inputTokenLimit: entry["inputTokenLimit"] as? Int,
                outputTokenLimit: entry["outputTokenLimit"] as? Int
            )
        }

        for fragment in preferredModelFragments {
            if let match = parsed.first(where: { $0.name.localizedCaseInsensitiveContains(fragment) }) {
                return match
            }
        }
        return parsed.first
    }

    private static func totalTokenCount(from data: Data) -> Int? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let usage = root["usageMetadata"] as? [String: Any]
        else {
            return nil
        }
        if let total = usage["totalTokenCount"] as? Int { return total }
        if let total = usage["totalTokenCount"] as? NSNumber { return total.intValue }
        let prompt = (usage["promptTokenCount"] as? Int)
            ?? (usage["promptTokenCount"] as? NSNumber)?.intValue
            ?? 0
        let candidates = (usage["candidatesTokenCount"] as? Int)
            ?? (usage["candidatesTokenCount"] as? NSNumber)?.intValue
            ?? 0
        let sum = prompt + candidates
        return sum > 0 ? sum : nil
    }

    private static func retryDelayHint(from data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = root["error"] as? [String: Any]
        else {
            return nil
        }
        if let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        guard let details = error["details"] as? [[String: Any]] else { return nil }
        for detail in details {
            if let retry = detail["retryDelay"] as? String { return "Retry after \(retry)" }
            if let meta = detail["metadata"] as? [String: Any],
               let delay = meta["quotaResetDelay"] as? String {
                return "Resets in \(delay)"
            }
        }
        return nil
    }

    private static func intHeader(_ http: HTTPURLResponse, names: [String]) -> Int? {
        for name in names {
            if let value = http.value(forHTTPHeaderField: name),
               let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return intValue
            }
        }
        return nil
    }

    private static func stringHeader(_ http: HTTPURLResponse, names: [String]) -> String? {
        for name in names {
            if let value = http.value(forHTTPHeaderField: name)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// RPD-style counters reset at midnight Pacific (matches Gemini docs).
    private static func rollLocalCountersIfNeeded() {
        let stamp = pacificDayStamp()
        if defaults.string(forKey: dayKey) != stamp {
            defaults.set(stamp, forKey: dayKey)
            defaults.set(0, forKey: requestsKey)
            defaults.set(0, forKey: tokensKey)
        }
    }

    private static func pacificDayStamp() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let comps = calendar.dateComponents([.year, .month, .day], from: Date())
        return String(
            format: "%04d-%02d-%02d",
            comps.year ?? 0,
            comps.month ?? 0,
            comps.day ?? 0
        )
    }

    private enum LastRateLimit {
        static var remaining: Int?
        static var limit: Int?
        static var reset: String?
        static var updatedAt: Date?

        static func clear() {
            remaining = nil
            limit = nil
            reset = nil
            updatedAt = nil
        }
    }
}
