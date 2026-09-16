//
//  AutoTagDecisionDiagramWindow.swift
//  Grabbit
//
//  DEBUG-only window hosting the Auto-Tag decision flowchart.
//

import AppKit
import SwiftUI

#if DEBUG
final class AutoTagDecisionDiagramWindow: NSWindow {

    static var current: AutoTagDecisionDiagramWindow?

    static func show() {
        DispatchQueue.main.async {
            if current == nil {
                current = AutoTagDecisionDiagramWindow()
            }
            current?.center()
            current?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "Auto-Tag Decisions"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 640, height: 520)
        backgroundColor = DesignTokens.Color.background.ns
        level = .floating

        let hosting = NSHostingView(rootView: AutoTagDecisionDiagramView())
        hosting.frame = NSRect(x: 0, y: 0, width: 780, height: 720)
        contentView = hosting
    }
}
#endif
