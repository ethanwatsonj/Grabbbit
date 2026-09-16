//
//  AppSettings.swift
//  Grabbit
//

import Foundation
import CoreGraphics

enum AppSettings {
    private static let destinationFolderKey = "destinationFolderPath"
    private static let hasSeenLibraryIntroKey = "hasSeenLibraryIntro"
    private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private static let legacySnipsnapSuiteName = "ewew.design.Snipsnap"

    static let spotlightDimOpacityNotches: [CGFloat] = [0, 0.05, 0.15, 0.30, 0.60]
    static let spotlightBlurRadiusNotches: [CGFloat] = [0, 1, 2, 5, 10]
    static let spotlightDimOpacityDefault: CGFloat = 0.30
    static let spotlightBlurRadiusDefault: CGFloat = 5

    static func snapSpotlightDimOpacity(_ value: CGFloat) -> CGFloat {
        spotlightDimOpacityNotches.min(by: { abs($0 - value) < abs($1 - value) }) ?? spotlightDimOpacityDefault
    }

    static func snapSpotlightBlurRadius(_ value: CGFloat) -> CGFloat {
        spotlightBlurRadiusNotches.min(by: { abs($0 - value) < abs($1 - value) }) ?? spotlightBlurRadiusDefault
    }

    static func spotlightDimOpacityIndex(for value: CGFloat) -> Int {
        let snapped = snapSpotlightDimOpacity(value)
        return spotlightDimOpacityNotches.firstIndex(of: snapped) ?? 3
    }

    static func spotlightBlurRadiusIndex(for value: CGFloat) -> Int {
        let snapped = snapSpotlightBlurRadius(value)
        return spotlightBlurRadiusNotches.firstIndex(of: snapped) ?? 3
    }

    static var destinationFolderURL: URL {
        get {
            if let path = resolvedDestinationPath() {
                // Prefer the configured path even when iCloud hasn't hydrated yet after
                // restart. Falling back to Desktop empties Recents and can make Show All
                // scan the wrong tree.
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        }
        set {
            let path = newValue.standardizedFileURL.path
            let previous = resolvedDestinationPath()
            persistDestinationPath(path)
            if previous != path {
                // Pick up whatever's already sitting in the newly chosen folder before
                // anyone re-reads history, so the Library reflects it immediately
                // instead of only what the app happens to remember creating.
                CaptureHistory.shared.scheduleReconcileWithDisk()
                // Library / menu scope to this folder — refresh when it changes.
                NotificationCenter.default.post(name: .captureHistoryDidChange, object: nil)
            }
        }
    }

    /// True when Settings has an explicit save folder (not the Desktop fallback).
    static var hasConfiguredDestinationFolder: Bool {
        resolvedDestinationPath() != nil
    }

    /// True after the Capture Library intro has been dismissed once.
    static var hasSeenLibraryIntro: Bool {
        get { UserDefaults.standard.bool(forKey: hasSeenLibraryIntroKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasSeenLibraryIntroKey) }
    }

    /// True after first-launch Screen Recording → Accessibility → save folder.
    /// Existing installs that already chose a save folder are treated as onboarded.
    static var hasCompletedOnboarding: Bool {
        get {
            if UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey) {
                return true
            }
            if hasConfiguredDestinationFolder {
                UserDefaults.standard.set(true, forKey: hasCompletedOnboardingKey)
                return true
            }
            return false
        }
        set { UserDefaults.standard.set(newValue, forKey: hasCompletedOnboardingKey) }
    }

    static var destinationFolderDisplayPath: String {
        let path = destinationFolderURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func ensureDestinationFolderExists() throws {
        try FileManager.default.createDirectory(
            at: destinationFolderURL,
            withIntermediateDirectories: true
        )
    }

    /// UserDefaults can fail after restart when the preferences plist is quarantined /
    /// rejected by cfprefsd (`Could not write domain ewew.design.Grabbit`) even though
    /// the file on disk still has `destinationFolderPath`. Read past that and mirror
    /// into Application Support so Recents keep scoping to the real save folder.
    private static func resolvedDestinationPath() -> String? {
        if let path = UserDefaults.standard.string(forKey: destinationFolderKey), !path.isEmpty {
            mirrorDestinationPathIfNeeded(path)
            return path
        }

        if let path = destinationPathFromApplicationSupport(), !path.isEmpty {
            UserDefaults.standard.set(path, forKey: destinationFolderKey)
            return path
        }

        if let path = destinationPathFromPreferencesPlist(bundleID: Bundle.main.bundleIdentifier ?? "ewew.design.Grabbit") {
            persistDestinationPath(path)
            return path
        }

        // One-time migrate after Snipsnap → Grabbit rename.
        if let legacy = UserDefaults(suiteName: legacySnipsnapSuiteName)?
            .string(forKey: destinationFolderKey),
           !legacy.isEmpty {
            persistDestinationPath(legacy)
            return legacy
        }

        if let path = destinationPathFromPreferencesPlist(bundleID: legacySnipsnapSuiteName) {
            persistDestinationPath(path)
            return path
        }

        return nil
    }

    private static func persistDestinationPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: destinationFolderKey)
        mirrorDestinationPathIfNeeded(path)
    }

    private static func mirrorDestinationPathIfNeeded(_ path: String) {
        let url = destinationMirrorURL()
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if (try? String(contentsOf: url, encoding: .utf8)) == path { return }
        try? path.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func destinationPathFromApplicationSupport() -> String? {
        let url = destinationMirrorURL()
        guard let path = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private static func destinationMirrorURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Grabbit", isDirectory: true)
            .appendingPathComponent("destinationFolderPath.txt", isDirectory: false)
    }

    private static func destinationPathFromPreferencesPlist(bundleID: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(bundleID).plist", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = plist[destinationFolderKey] as? String,
              !path.isEmpty else {
            return nil
        }
        return path
    }
}
