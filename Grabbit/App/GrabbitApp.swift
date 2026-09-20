//
//  GrabbitApp.swift
//  Grabbit
//
//  Created by Ethan Watson on 6/27/26.
//

import SwiftUI
import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let menuBarIconImage: NSImage = {
        if let base = NSImage(named: "MenuBarIcon"),
           let image = base.copy() as? NSImage {
            // Landscape filled rabbit matching the cross-stitch silhouette
            // (traced from the RabbitHop2 mid-air pose, native 30×14 aspect).
            // Rendered slightly below native size so it sits smaller in the menu bar.
            image.size = NSSize(width: 26, height: 12)
            image.isTemplate = true
            return image
        }
        return NSImage(
            systemSymbolName: "rectangle.dashed.badge.record",
            accessibilityDescription: "Grabbit"
        ) ?? NSImage()
    }()

    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var recordingEscapeGlobalMonitor: Any?
    private var recordingEscapeLocalMonitor: Any?
    private var recordingElapsedSeconds = 0
    private var recordingTimerSource: DispatchSourceTimer?
    private var historyObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DesignTokens.Typography.registerBundledFonts()

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            applyIdleStatusItemAppearance(to: button)
        }

        if ProcessInfo.processInfo.environment["GRABBIT_PROBE_TITLE_DRAG"] == "1" {
            // Open library immediately for in-app hit-path probing (see CaptureLibraryWindow).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                CaptureLibraryWindow.show()
            }
        }

        historyObserver = NotificationCenter.default.addObserver(
            forName: .captureHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildMenu()
        }

        // Paint the status item before loading capture history (disk + optional thumb work).
        DispatchQueue.main.async { [weak self] in
            self?.rebuildMenu()
            // Index anything already in the save folder (e.g. after switching folders or
            // restarting) so Recents / Show All aren't empty until the user captures again.
            CaptureHistory.shared.scheduleReconcileWithDisk()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.beginFirstRunOrWarmPermissions()
        }

        RecordingEngine.shared.onRecordingStarted = { [weak self] in
            guard let self else { return }
            self.startRecordingStatus()
            self.startRecordingEscapeMonitor()
            self.rebuildMenu()
        }

        RecordingEngine.shared.onRecordingStopped = { [weak self] url in
            guard let self else { return }
            self.stopRecordingEscapeMonitor()
            self.stopRecordingStatus()
            RecordingBackgroundPreviewWindow.hide()
            CaptureBar.resetMediaSettings()
            self.rebuildMenu()

            guard let url else { return }
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.generateCGImagesAsynchronously(
                forTimes: [NSValue(time: .zero)]
            ) { _, cgImage, _, _, _ in
                DispatchQueue.main.async {
                    guard let cgImage else { return }
                    let thumb = NSImage(cgImage: cgImage, size: .zero)
                    CaptureHistory.shared.add(.recording(url: url, thumbnail: thumb))
                    self.rebuildMenu()
                    ToastWindow.show(image: thumb, associatedCaptureID: nil) {
                        VideoAnnotationWindow.show(url: url, thumbnail: thumb)
                    }
                }
            }
        }

        RecordingEngine.shared.onRecordingFailed = { [weak self] error in
            guard let self else { return }
            self.stopRecordingEscapeMonitor()
            self.stopRecordingStatus()
            RecordingBackgroundPreviewWindow.hide()
            CaptureBar.resetMediaSettings()
            self.rebuildMenu()
            let alert = NSAlert()
            alert.messageText = "Recording Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }

        let trusted = AXIsProcessTrusted()
        #if DEBUG
        print("[Grabbit] Accessibility trusted: \(trusted)")
        #endif

        registerGlobalHotkeys()
        #if DEBUG
        print("[Grabbit] Global monitor registered: \(globalMonitor != nil), local: \(localHotkeyMonitor != nil)")
        #endif
    }

    private func registerGlobalHotkeys() {
        if let old = globalMonitor {
            NSEvent.removeMonitor(old)
            globalMonitor = nil
        }
        if let old = localHotkeyMonitor {
            NSEvent.removeMonitor(old)
            localHotkeyMonitor = nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event)
        }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleHotkey(event) else { return event }
            return nil
        }
    }

    /// Returns true when a registered hotkey was handled (and the event should be consumed).
    @discardableResult
    private func handleHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let control = flags.contains(.control)

        // Defaults mirror native macOS screenshot shortcuts so Grabbit can replace them.
        if event.keyCode == 20, command, shift, !option, !control {
            #if DEBUG
            print("[Grabbit] ⌘⇧3 triggered")
            #endif
            takeFullScreenScreenshot()
            return true
        }
        if event.keyCode == 21, command, shift, !option, !control {
            #if DEBUG
            print("[Grabbit] ⌘⇧4 triggered")
            #endif
            takeScreenshot()
            return true
        }
        if event.keyCode == 23, command, shift, !option, !control {
            #if DEBUG
            print("[Grabbit] ⌘⇧5 triggered")
            #endif
            CaptureBar.show()
            return true
        }
        // ⌘7 → Capture Library (keyCode 26 = "7")
        if event.keyCode == 26, command, !shift, !option, !control {
            #if DEBUG
            print("[Grabbit] ⌘7 triggered")
            #endif
            showCaptureLibrary()
            return true
        }
        return false
    }

    /// First launch: guided onboarding. Later launches: only re-prompt Accessibility if revoked.
    private func beginFirstRunOrWarmPermissions() {
        if AppSettings.hasCompletedOnboarding {
            requestAccessibilityPermissionIfNeeded()
            RecordingEngine.shared.prewarm()
            return
        }

        OnboardingWindow.show { [weak self] in
            self?.registerGlobalHotkeys()
            RecordingEngine.shared.prewarm()
        }
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )

        pollForAccessibilityGrant()
    }

    private func pollForAccessibilityGrant() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if AXIsProcessTrusted() {
                #if DEBUG
                print("[Grabbit] Accessibility granted — re-registering monitor")
                #endif
                self.registerGlobalHotkeys()
                #if DEBUG
                print("[Grabbit] Monitor re-registered: global=\(self.globalMonitor != nil) local=\(self.localHotkeyMonitor != nil)")
                #endif
            } else {
                self.pollForAccessibilityGrant()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRecordingEscapeMonitor()
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
            self.historyObserver = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            localHotkeyMonitor = nil
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppDockPresentation.isLibraryPresented {
            CaptureLibraryWindow.current?.makeKeyAndOrderFront(nil)
        } else {
            CaptureLibraryWindow.show()
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let showAllItem = NSMenuItem(title: "Show All…", action: #selector(showCaptureLibrary), keyEquivalent: "7")
        showAllItem.keyEquivalentModifierMask = .command
        showAllItem.target = self
        menu.addItem(showAllItem)
        return menu
    }

    private func startRecordingEscapeMonitor() {
        stopRecordingEscapeMonitor()
        recordingEscapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            self?.stopRecording()
        }
        recordingEscapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard RecordingEngine.shared.isRecording, event.keyCode == 53 else { return event }
            self?.stopRecording()
            return nil
        }
    }

    private func stopRecordingEscapeMonitor() {
        if let monitor = recordingEscapeGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            recordingEscapeGlobalMonitor = nil
        }
        if let monitor = recordingEscapeLocalMonitor {
            NSEvent.removeMonitor(monitor)
            recordingEscapeLocalMonitor = nil
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let captureBarItem = NSMenuItem(title: "Open Capture Bar", action: #selector(showCaptureBar), keyEquivalent: "5")
        captureBarItem.keyEquivalentModifierMask = [.command, .shift]
        captureBarItem.target = self
        menu.addItem(captureBarItem)

        menu.addItem(.separator())

        let fullScreenItem = NSMenuItem(title: "Grab Screen", action: #selector(takeFullScreenScreenshot), keyEquivalent: "3")
        fullScreenItem.keyEquivalentModifierMask = [.command, .shift]
        fullScreenItem.target = self
        menu.addItem(fullScreenItem)

        let screenshotItem = NSMenuItem(title: "Grab Region", action: #selector(takeScreenshot), keyEquivalent: "4")
        screenshotItem.keyEquivalentModifierMask = [.command, .shift]
        screenshotItem.target = self
        menu.addItem(screenshotItem)

        let recItem: NSMenuItem
        if RecordingEngine.shared.isRecording {
            recItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            recItem.target = self
            let stopCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            recItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(stopCfg)
        } else if RecordingEngine.shared.isStartingRecording {
            recItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        } else {
            recItem = NSMenuItem(title: "Record Screen", action: #selector(toggleRecording), keyEquivalent: "")
            recItem.target = self
        }
        menu.addItem(recItem)

        menu.addItem(.separator())

        let menuEntries = CaptureHistory.shared.menuEntries
        if menuEntries.isEmpty {
            let emptyItem = NSMenuItem(title: "No recent captures", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for (index, entry) in menuEntries.enumerated() {
                let label = entry.displayName
                let item = NSMenuItem(
                    title: label,
                    action: #selector(openHistoryItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
        }

        let showAllItem = NSMenuItem(title: "Show All…", action: #selector(showCaptureLibrary), keyEquivalent: "7")
        showAllItem.keyEquivalentModifierMask = .command
        showAllItem.target = self
        menu.addItem(showAllItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        if RecordingEngine.shared.isRecording {
            statusItem.menu = nil
            configureRecordingStatusItemClick()
        } else {
            statusItem.button?.action = nil
            statusItem.button?.target = nil
            statusItem.menu = menu
        }
    }

    /// Left-click stops recording; right-click opens the menu.
    private func configureRecordingStatusItemClick() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard RecordingEngine.shared.isRecording else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            rebuildMenu()
            statusItem.menu?.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height),
                in: sender
            )
            statusItem.menu = nil
            configureRecordingStatusItemClick()
        } else {
            stopRecording()
        }
    }

    private func formattedRecordingTime(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func startRecordingStatus() {
        recordingElapsedSeconds = 0
        statusItem.length = NSStatusItem.variableLength
        configureRecordingStatusItemClick()
        updateRecordingStatusDisplay()

        let src = DispatchSource.makeTimerSource(queue: .main)
        src.schedule(deadline: .now() + 1, repeating: 1)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.recordingElapsedSeconds += 1
            self.updateRecordingStatusDisplay()
        }
        src.resume()
        recordingTimerSource = src
    }

    private func stopRecordingStatus() {
        recordingTimerSource?.cancel()
        recordingTimerSource = nil
        recordingElapsedSeconds = 0
        statusItem.length = NSStatusItem.variableLength
        if let button = statusItem.button {
            button.action = nil
            button.target = nil
            applyIdleStatusItemAppearance(to: button)
        }
    }

    private func applyIdleStatusItemAppearance(to button: NSStatusBarButton) {
        button.title = ""
        button.image = Self.menuBarIconImage
        button.imagePosition = .imageOnly
        button.toolTip = "Grabbit"
    }

    private func updateRecordingStatusDisplay() {
        guard let button = statusItem.button else { return }
        let time = formattedRecordingTime(recordingElapsedSeconds)
        let stopCfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        button.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop recording")?
            .withSymbolConfiguration(stopCfg)
        button.imagePosition = .imageLeading
        button.title = " \(time)"
        button.toolTip = "Recording — \(time). Click to stop."
    }

    @objc private func openHistoryItem(_ sender: NSMenuItem) {
        let menuEntries = CaptureHistory.shared.menuEntries
        guard menuEntries.indices.contains(sender.tag) else { return }
        CaptureLibraryWindow.open(menuEntries[sender.tag])
    }

    @objc private func showCaptureLibrary() {
        CaptureLibraryWindow.show()
    }

    @objc func showCaptureBar() {
        CaptureBar.show()
    }

    @objc func toggleRecording() {
        RecordingEngine.shared.startRecording()
        rebuildMenu()  // immediately reflect "Starting…" state
    }

    @objc func stopRecording() {
        RecordingEngine.shared.stopRecording()
    }

    @objc func openSettings() {
        SettingsWindow.show()
    }

    @objc func takeFullScreenScreenshot() {
        let earlySignals = CaptureClassifier.gatherEarlyCaptureSignals()
        guard let rect = NSScreen.main?.frame else { return }
        ScreenshotEngine.captureRegion(rect) { image in
            guard let image else { return }
            CapturePipeline.finishScreenshot(
                image,
                captureRect: rect,
                earlySignals: earlySignals
            )
        }
    }

    @objc func takeScreenshot() {
        // Captured before RegionSelector.show() below — that call activates Grabbit's own
        // overlay window, so any read of NSWorkspace.shared.frontmostApplication taken after
        // this point would describe Grabbit instead of whatever app the user was looking at.
        let earlySignals = CaptureClassifier.gatherEarlyCaptureSignals()
        DispatchQueue.main.async {
            RegionSelector.show { rect in
                guard let rect else { return }
                ScreenshotEngine.captureRegion(rect) { image in
                    guard let image else { return }
                    CapturePipeline.finishScreenshot(
                        image,
                        captureRect: rect,
                        earlySignals: earlySignals
                    )
                }
            }
        }
    }
}

@main
struct GrabbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView()
        }
    }
}

extension NSImage {
    func thumbnail(size: NSSize) -> NSImage {
        let srcSize = self.size
        guard srcSize.width > 0, srcSize.height > 0 else { return self }

        let widthRatio = size.width / srcSize.width
        let heightRatio = size.height / srcSize.height
        let scale = min(widthRatio, heightRatio)
        let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)

        let thumb = NSImage(size: size)
        thumb.lockFocus()
        let origin = NSPoint(
            x: (size.width - drawSize.width) / 2,
            y: (size.height - drawSize.height) / 2
        )
        draw(in: NSRect(origin: origin, size: drawSize),
             from: NSRect(origin: .zero, size: srcSize),
             operation: .copy,
             fraction: 1.0)
        thumb.unlockFocus()
        return thumb
    }
}
