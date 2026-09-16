//
//  OnboardingWindow.swift
//  Grabbit
//
//  First-launch flow: Screen Recording → Accessibility → save folder.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

// MARK: - Window

final class OnboardingWindow: NSWindow {
    static var current: OnboardingWindow?

    static func show(onComplete: @escaping () -> Void) {
        if let existing = current {
            existing.onComplete = onComplete
            existing.center()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = OnboardingWindow(onComplete: onComplete)
        current = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var onComplete: () -> Void

    private init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        title = "Welcome to Grabbit"
        isReleasedWhenClosed = false
        level = .floating

        let hosting = NSHostingView(
            rootView: OnboardingRootView(
                onFinished: { [weak self] in
                    guard let self else { return }
                    AppSettings.hasCompletedOnboarding = true
                    let complete = self.onComplete
                    Self.current = nil
                    self.close()
                    complete()
                }
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 420)
        contentView = hosting
    }

    override func close() {
        if Self.current === self {
            Self.current = nil
        }
        super.close()
    }
}

// MARK: - Steps

private enum OnboardingStep: Int, CaseIterable {
    case screenRecording
    case accessibility
    case saveFolder

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .saveFolder: return "Save Folder"
        }
    }

    var bodyText: String {
        switch self {
        case .screenRecording:
            return "Grabbit needs screen access to capture screenshots and recordings. Nothing is ever uploaded without your action."
        case .accessibility:
            return "Needed so your keyboard shortcuts work from any app (⌘⇧3, ⌘⇧4, ⌘⇧5, ⌘7)."
        case .saveFolder:
            return "Choose where Grabbit saves screenshots and recordings. You can change this later in Settings."
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "keyboard"
        case .saveFolder: return "folder"
        }
    }
}

// MARK: - Root view

private struct OnboardingRootView: View {
    let onFinished: () -> Void

    @State private var step: OnboardingStep = .screenRecording
    @State private var hasScreenRecording = CGPreflightScreenCaptureAccess()
    @State private var hasAccessibility = AXIsProcessTrusted()
    @State private var destinationPath = AppSettings.destinationFolderDisplayPath
    @State private var folderChosen = AppSettings.hasConfiguredDestinationFolder
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxl) {
            header
            stepContent
            Spacer(minLength: 0)
            footer
        }
        .padding(DesignTokens.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignTokens.Color.background.swiftUI)
        .onAppear { startPolling() }
        .onChange(of: step) { _, newStep in
            if newStep == .accessibility, !hasAccessibility {
                promptAccessibilityTrust()
            }
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Welcome to Grabbit")
                .font(.grabbit(.title))
                .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)

            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count) — \(step.title)")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
        }
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Image(systemName: step.systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(DesignTokens.Color.primary.swiftUI)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                        .fill(DesignTokens.Color.surface.swiftUI)
                )

            Text(step.bodyText)
                .font(.grabbit(.body))
                .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                .fixedSize(horizontal: false, vertical: true)

            switch step {
            case .screenRecording:
                permissionRow(
                    granted: hasScreenRecording,
                    grantTitle: "Open Screen Recording Settings",
                    action: openScreenRecordingSettings
                )
            case .accessibility:
                permissionRow(
                    granted: hasAccessibility,
                    grantTitle: "Open Accessibility Settings",
                    action: openAccessibilitySettings
                )
            case .saveFolder:
                saveFolderRow
            }
        }
    }

    private func permissionRow(granted: Bool, grantTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
            } else {
                Button(grantTitle, action: action)
                    .buttonStyle(.grabbit)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private var saveFolderRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(spacing: DesignTokens.Spacing.md) {
                Text(destinationPath)
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Choose…") {
                    chooseFolder()
                }
                .buttonStyle(.grabbit)
            }
            .padding(.vertical, DesignTokens.Spacing.sm)

            if !folderChosen {
                Text("Pick a folder to continue. Desktop is fine as a starting point.")
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .screenRecording {
                Button("Back") {
                    goBack()
                }
                .buttonStyle(.plain)
                .font(.grabbit(.body))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            }

            Spacer(minLength: 0)

            Button(primaryTitle) {
                advance()
            }
            .buttonStyle(.grabbit)
            .disabled(!canAdvance)
        }
    }

    private var primaryTitle: String {
        step == .saveFolder ? "Get Started" : "Continue"
    }

    private var canAdvance: Bool {
        switch step {
        case .screenRecording: return hasScreenRecording
        case .accessibility: return hasAccessibility
        case .saveFolder: return folderChosen
        }
    }

    private func advance() {
        guard canAdvance else { return }
        switch step {
        case .screenRecording:
            step = .accessibility
            refreshPermissions()
        case .accessibility:
            step = .saveFolder
        case .saveFolder:
            onFinished()
        }
    }

    private func goBack() {
        switch step {
        case .screenRecording:
            break
        case .accessibility:
            step = .screenRecording
        case .saveFolder:
            step = .accessibility
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                refreshPermissions()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // Prompt Screen Recording early so the system dialog can appear on this step.
        if !hasScreenRecording {
            requestScreenRecordingAccess()
        }
        if step == .accessibility, !hasAccessibility {
            promptAccessibilityTrust()
        }
    }

    private func refreshPermissions() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        hasAccessibility = AXIsProcessTrusted()
    }

    private func requestScreenRecordingAccess() {
        _ = CGRequestScreenCaptureAccess()
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            await MainActor.run { refreshPermissions() }
        }
    }

    private func openScreenRecordingSettings() {
        requestScreenRecordingAccess()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
    }

    private func openAccessibilitySettings() {
        promptAccessibilityTrust()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    private func promptAccessibilityTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func chooseFolder() {
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
            destinationPath = AppSettings.destinationFolderDisplayPath
            folderChosen = true
        }
    }
}
