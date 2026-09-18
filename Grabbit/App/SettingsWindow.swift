//
//  SettingsWindow.swift
//  Grabbit
//

import AppKit
import Foundation
import SwiftUI

struct SettingsRootView: View {
    #if DEBUG
    @State private var showsIntro = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxl) {
                #if DEBUG
                debugLaunchersSection
                #endif
                GeneralSettingsView()
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.Color.background.swiftUI)
        .frame(minWidth: 560, minHeight: 420)
        #if DEBUG
        .libraryIntroModal(isPresented: $showsIntro, markSeenOnDismiss: false)
        #endif
    }

    #if DEBUG
    private var debugLaunchersSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("DEBUG")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)

            Divider()

            HStack(spacing: DesignTokens.Spacing.md) {
                Button("Intro Modal") {
                    showsIntro = true
                }
                .buttonStyle(.grabbit)

                Button("Kitchen Sink") {
                    KitchenSinkWindow.show()
                }
                .buttonStyle(.grabbit)

                Button("Auto Organize Diagram") {
                    AutoTagDecisionDiagramWindow.show()
                }
                .buttonStyle(.grabbit)

                Spacer(minLength: 0)
            }
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
    }
    #endif
}

// MARK: - General

private struct GeneralSettingsView: View {
    @State private var destinationPath = AppSettings.destinationFolderDisplayPath

    private let shortcuts: [(String, [String])] = [
        ("Grab Screen", ["⌘", "⇧", "3"]),
        ("Grab Region", ["⌘", "⇧", "4"]),
        ("Capture Bar", ["⌘", "⇧", "5"]),
        ("Show All", ["⌘", "7"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxl) {
            saveLocationSection
            ConnectAISettingsView()
            shortcutsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var saveLocationSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            sectionHeader("Save Location")
            Divider()
            HStack(spacing: DesignTokens.Spacing.md) {
                Text("Save to")
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                Text(destinationPath)
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Change…") {
                    chooseDestinationFolder()
                }
                .buttonStyle(.grabbit)
            }
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            sectionHeader("Shortcuts")
            Divider()

            ForEach(shortcuts, id: \.0) { label, keys in
                HStack {
                    Text(label)
                        .font(.grabbit(.body))
                        .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(keys, id: \.self) { key in
                            Text(key)
                                .font(DesignTokens.Typography.monoSwiftUI(size: DesignTokens.Typography.label.size))
                                .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                                .frame(width: 24, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                                        .fill(DesignTokens.Color.surface.swiftUI)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                                        .stroke(DesignTokens.Color.border.swiftUI, lineWidth: 0.5)
                                )
                        }
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.sm)
                Divider()
            }

            Button("Open Accessibility Settings for Grabbit…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
            .buttonStyle(.plain)
            .font(.grabbit(.caption))
            .foregroundStyle(Color(nsColor: .linkColor))
            .frame(maxWidth: .infinity)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.grabbit(.caption))
            .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Grabbit saves screenshots and recordings."
        panel.directoryURL = AppSettings.destinationFolderURL

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            AppSettings.destinationFolderURL = url
            DispatchQueue.main.async {
                destinationPath = AppSettings.destinationFolderDisplayPath
            }
        }
    }
}

// MARK: - Connect AI

private struct ConnectAISettingsView: View {
    @State private var apiKeyDraft = ""
    @State private var isCloudConnected = AIConnection.isCloudConnected
    @State private var appleIntelligenceAvailable = AIConnection.isAppleIntelligenceAvailable
    @State private var statusMessage: String?
    @State private var showsKeyField = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            sectionHeader("Connect AI")
            Divider()

            appleIntelligenceRow
            Divider()
            enhancedOrganizeRow

            if let statusMessage {
                Text(statusMessage)
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            }

            Text("Apple Intelligence stays free and on-device. Connect Gemini for stronger project and filename suggestions when you run Auto Organize — that path sends the capture to Google using your key.")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DesignTokens.Spacing.xs)
        }
        .onReceive(NotificationCenter.default.publisher(for: AIConnection.didChangeNotification)) { _ in
            refreshStatus()
        }
        .onAppear { refreshStatus() }
    }

    private var appleIntelligenceRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Intelligence")
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                Text(appleIntelligenceAvailable
                     ? "On-device Auto Organize available"
                     : "Unavailable on this Mac — enable Apple Intelligence if supported")
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            }
            Spacer(minLength: 0)
            Text(appleIntelligenceAvailable ? "Ready" : "Off")
                .font(.grabbit(.caption))
                .foregroundStyle(
                    appleIntelligenceAvailable
                        ? DesignTokens.Color.textPrimary.swiftUI
                        : DesignTokens.Color.textSecondary.swiftUI
                )
            if !appleIntelligenceAvailable {
                Button("Open Settings…") {
                    openAppleIntelligenceSettings()
                }
                .buttonStyle(.grabbit)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private var enhancedOrganizeRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enhanced Organize")
                        .font(.grabbit(.body))
                        .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                    Text(isCloudConnected
                         ? "Gemini connected — used first for Auto Organize"
                         : "Optional Gemini API key for better suggestions")
                        .font(.grabbit(.caption))
                        .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                }
                Spacer(minLength: 0)
                if isCloudConnected {
                    Text("Connected")
                        .font(.grabbit(.caption))
                        .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                    Button("Disconnect") {
                        disconnect()
                    }
                    .buttonStyle(.grabbit)
                } else {
                    Button(showsKeyField ? "Cancel" : "Connect…") {
                        showsKeyField.toggle()
                        statusMessage = nil
                        if !showsKeyField { apiKeyDraft = "" }
                    }
                    .buttonStyle(.grabbit)
                }
            }
            .padding(.vertical, DesignTokens.Spacing.sm)

            if showsKeyField && !isCloudConnected {
                HStack(spacing: DesignTokens.Spacing.md) {
                    SecureField("Gemini API key", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.grabbit(.body))
                    Button("Save") {
                        connect()
                    }
                    .buttonStyle(.grabbit)
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Link(
                    "Get a free Gemini API key",
                    destination: URL(string: "https://aistudio.google.com/apikey")!
                )
                .font(.grabbit(.caption))
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.grabbit(.caption))
            .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
    }

    private func refreshStatus() {
        isCloudConnected = AIConnection.isCloudConnected
        appleIntelligenceAvailable = AIConnection.isAppleIntelligenceAvailable
        if isCloudConnected {
            showsKeyField = false
            apiKeyDraft = ""
        }
    }

    private func connect() {
        do {
            try AIConnection.connectGemini(apiKey: apiKeyDraft)
            statusMessage = "Gemini connected. Auto Organize will prefer it."
            refreshStatus()
        } catch {
            statusMessage = "Couldn’t save API key to Keychain."
        }
    }

    private func disconnect() {
        do {
            try AIConnection.disconnectGemini()
            statusMessage = "Disconnected. Auto Organize falls back to Apple Intelligence when available."
            refreshStatus()
        } catch {
            statusMessage = "Couldn’t remove API key from Keychain."
        }
    }

    private func openAppleIntelligenceSettings() {
        // Best-effort deep links; macOS may ignore unknown preference panes.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.appleintelligence",
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

// MARK: - Window

final class SettingsWindow: NSWindow {

    static var current: SettingsWindow?

    static func show() {
        if current == nil {
            current = SettingsWindow()
        }
        current?.center()
        current?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "Grabbit Settings"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 520, height: 400)

        let hosting = NSHostingView(rootView: SettingsRootView())
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 520)
        contentView = hosting
    }
}
