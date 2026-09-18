//
//  GeminiAPIOrganizeDiagramWindow.swift
//  Grabbit
//
//  DEBUG-only window hosting the Gemini API / Connect AI flowchart.
//

import AppKit
import SwiftUI

#if DEBUG
final class GeminiAPIOrganizeDiagramWindow: NSWindow {

    static var current: GeminiAPIOrganizeDiagramWindow?

    static func show() {
        DispatchQueue.main.async {
            if current == nil {
                current = GeminiAPIOrganizeDiagramWindow()
            }
            current?.center()
            current?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "Gemini API · Connect AI"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 640, height: 520)
        backgroundColor = DesignTokens.Color.background.ns
        level = .floating

        let hosting = NSHostingView(rootView: GeminiAPIOrganizeDiagramView())
        hosting.frame = NSRect(x: 0, y: 0, width: 780, height: 780)
        contentView = hosting
    }
}
#endif
