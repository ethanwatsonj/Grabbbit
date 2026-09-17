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
