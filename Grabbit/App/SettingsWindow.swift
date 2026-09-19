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
        .frame(minWidth: 600, minHeight: 460)
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

                Button("Gemini API Diagram") {
                    GeminiAPIOrganizeDiagramWindow.show()
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
    @State private var preferredProvider = AIConnection.preferredOrganizeProvider
    @State private var statusMessage: String?
    @State private var showsKeyField = false
    @State private var usage = GeminiUsageSnapshot()
    @State private var usageTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            sectionHeader("Connect AI")
            Divider()

            appleIntelligenceRow
            Divider()
            enhancedOrganizeRow

            if showsProviderToggle {
                Divider()
                providerToggleRow
            }

            if isCloudConnected {
                geminiUsageSection
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            }

            Text(connectAIFooterCopy)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DesignTokens.Spacing.xs)

            #if DEBUG
            Button("How Gemini prompting works…") {
                GeminiAPIOrganizeDiagramWindow.show()
            }
            .buttonStyle(.grabbit)
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: AIConnection.didChangeNotification)) { _ in
            refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: GeminiUsage.didChangeNotification)) { _ in
            applyLocalUsageCounters()
        }
        .onAppear { refreshStatus(forceUsageRefresh: true) }
        .onDisappear {
            usageTask?.cancel()
            usageTask = nil
        }
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
                    Text(enhancedOrganizeCaption)
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

    /// Discoverable whenever Apple FM is available or Gemini is connected.
    private var showsProviderToggle: Bool {
        appleIntelligenceAvailable || isCloudConnected
    }

    private var enhancedOrganizeCaption: String {
        guard isCloudConnected else {
            return "Optional Gemini API key for better suggestions"
        }
        switch preferredProvider {
        case .gemini:
            return "Gemini connected — selected for Auto Organize"
        case .appleFM:
            return "Gemini connected — Apple FM selected for Auto Organize"
        }
    }

    private var providerToggleCaption: String {
        if isCloudConnected {
            return "Switch between on-device Apple FM and Gemini"
        }
        if appleIntelligenceAvailable {
            return "Apple FM is active. Connect Gemini above to unlock the other option."
        }
        return "Connect Gemini to choose a cloud provider"
    }

    private var connectAIFooterCopy: String {
        if isCloudConnected {
            return "Apple Intelligence stays free and on-device. With Gemini connected, choose Apple FM or Gemini above. Gemini sends the capture to Google using your key only when selected and you run Auto Organize."
        }
        if appleIntelligenceAvailable {
            return "Apple Intelligence stays free and on-device. Connect Gemini above for stronger project and filename suggestions — that path sends the capture to Google using your key. After connecting, you can switch providers anytime."
        }
        return "Apple Intelligence stays free and on-device. Connect Gemini for stronger project and filename suggestions when you run Auto Organize — that path sends the capture to Google using your key."
    }

    /// Shown when Apple FM is available and/or Gemini is connected.
    private var providerToggleRow: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto Organize provider")
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                Text(providerToggleCaption)
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            }
            Spacer(minLength: 0)
            Picker("Auto Organize provider", selection: providerBinding) {
                ForEach(OrganizeAIProvider.allCases) { provider in
                    Text(provider.settingsLabel)
                        .tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            .opacity(isCloudConnected ? 1 : 0.9)
            .accessibilityLabel("Auto Organize provider")
            .accessibilityHint(
                isCloudConnected
                    ? "Choose Apple FM or Gemini for Auto Organize"
                    : "Gemini requires a connected API key"
            )
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private var providerBinding: Binding<OrganizeAIProvider> {
        Binding(
            get: {
                // Without a Gemini key, Apple FM is the only usable choice.
                isCloudConnected ? preferredProvider : .appleFM
            },
            set: { newValue in
                guard isCloudConnected else {
                    preferredProvider = .appleFM
                    statusMessage = "Connect a Gemini API key to use Gemini."
                    return
                }
                preferredProvider = newValue
                AIConnection.preferredOrganizeProvider = newValue
                statusMessage = newValue == .gemini
                    ? "Auto Organize will use Gemini."
                    : "Auto Organize will use Apple FM."
            }
        )
    }

    private var geminiUsageSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Gemini usage")
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                Spacer(minLength: 0)
                Button("Refresh") {
                    refreshUsage()
                }
                .buttonStyle(.grabbit)
                .disabled(usage.status == .loading)
            }

            usageStatusLine

            usageMetricRow(
                title: "Auto Organize today",
                value: "\(usage.localRequestsToday) request\(usage.localRequestsToday == 1 ? "" : "s") · \(formattedCount(usage.localTokensToday)) tokens"
            )

            if let remaining = usage.rateLimitRemaining, let limit = usage.rateLimitLimit {
                usageMetricRow(
                    title: "Rate limit remaining",
                    value: "\(remaining) of \(limit)"
                        + (usage.rateLimitReset.map { " · reset \($0)" } ?? "")
                )
            } else {
                usageMetricRow(
                    title: "Rate limit remaining",
                    value: "Not provided by this key’s API responses"
                )
            }

            if let model = usage.modelName {
                let input = usage.inputTokenLimit.map(formattedCount) ?? "—"
                let output = usage.outputTokenLimit.map(formattedCount) ?? "—"
                usageMetricRow(
                    title: model,
                    value: "Context \(input) in / \(output) out"
                )
            }

            Text("Google does not expose full project quota (RPD/TPM used) through an API key alone. Track official limits in AI Studio.")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                .fixedSize(horizontal: false, vertical: true)

            Link("Open Gemini usage in AI Studio", destination: GeminiUsage.aiStudioUsageURL)
                .font(.grabbit(.caption))
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    @ViewBuilder
    private var usageStatusLine: some View {
        switch usage.status {
        case .idle:
            EmptyView()
        case .loading:
            Text("Checking Gemini…")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
        case .ready:
            EmptyView()
        case .invalidKey:
            Text("API key was rejected — reconnect with a valid key.")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
        case .rateLimited(let hint):
            Text(hint.map { "Rate limited — \($0)" } ?? "Rate limited — try again shortly.")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
        case .unavailable(let message):
            Text(message)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
        }
    }

    private func usageMetricRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            Text(title)
                .font(.grabbit(.body))
                .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
            Spacer(minLength: 0)
            Text(value)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .multilineTextAlignment(.trailing)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.grabbit(.caption))
            .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
    }

    private func refreshStatus(forceUsageRefresh: Bool = false) {
        let wasConnected = isCloudConnected
        isCloudConnected = AIConnection.isCloudConnected
        appleIntelligenceAvailable = AIConnection.isAppleIntelligenceAvailable
        preferredProvider = AIConnection.preferredOrganizeProvider
        if isCloudConnected {
            showsKeyField = false
            apiKeyDraft = ""
            // Refresh Gemini usage when opening Settings or after connect — not on provider toggle.
            if forceUsageRefresh || !wasConnected {
                refreshUsage()
            } else {
                applyLocalUsageCounters()
            }
        } else {
            usageTask?.cancel()
            usageTask = nil
            usage = GeminiUsageSnapshot()
        }
    }

    private func refreshUsage() {
        applyLocalUsageCounters()
        usage.status = .loading
        usageTask?.cancel()
        usageTask = Task {
            let snapshot = await GeminiUsage.fetchSnapshot()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                usage = snapshot
            }
        }
    }

    private func applyLocalUsageCounters() {
        let local = GeminiUsage.localUsageToday()
        usage.localRequestsToday = local.requests
        usage.localTokensToday = local.tokens
    }

    private func formattedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func connect() {
        do {
            try AIConnection.connectGemini(apiKey: apiKeyDraft)
            statusMessage = "Gemini connected. Choose Apple FM or Gemini for Auto Organize."
            refreshStatus()
        } catch {
            statusMessage = "Couldn’t save API key to Keychain."
        }
    }

    private func disconnect() {
        do {
            try AIConnection.disconnectGemini()
            statusMessage = "Disconnected. Auto Organize uses Apple FM when available."
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "Grabbit Settings"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 560, height: 440)

        let hosting = NSHostingView(rootView: SettingsRootView())
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
        contentView = hosting
    }
}
