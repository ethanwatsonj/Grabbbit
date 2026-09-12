//
//  CaptureBar.swift
//  Grabbit
//

import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit
import SwiftUI

// MARK: - CaptureBarStyle

/// Thin wrapper over `DesignTokens` for Capture Bar chrome.
private enum CaptureBarStyle {
    static let hoverCornerRadius = DesignTokens.Radius.md
    /// Slightly tighter than the 4pt grid so mode-button highlights stay compact.
    static let hoverPadding: CGFloat = 6
    static let hoverFill = DesignTokens.Color.panelHoverFill.ns
    static let activeFill = DesignTokens.Color.panelActiveFill.ns
}

// MARK: - CaptureMode

enum CaptureMode: Equatable {
    case screenshotRegion
    case screenshotWindow
    case screenshotApp
    case screenshotFullScreen
    case recordFullScreen
    case recordWindow
    case recordApp
    case recordRegion

    var isRecording: Bool {
        switch self {
        case .recordFullScreen, .recordWindow, .recordApp, .recordRegion:
            return true
        default:
            return false
        }
    }

    var isWindowCapture: Bool {
        self == .screenshotWindow || self == .recordWindow
    }

    var isAppCapture: Bool {
        self == .screenshotApp || self == .recordApp
    }
}

// MARK: - CaptureBarCloseButton

private final class CaptureBarCloseButton: NSControl {
    private let highlightLayer = CALayer()
    private let iconView = NSImageView()
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Close"
        setAccessibilityLabel("Close")

        highlightLayer.cornerRadius = CaptureBarStyle.hoverCornerRadius
        layer?.addSublayer(highlightLayer)

        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(cfg)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateLook()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateLook()
    }

    override func layout() {
        super.layout()
        let iconSide: CGFloat = 14
        iconView.frame = NSRect(
            x: (bounds.width - iconSide) / 2,
            y: (bounds.height - iconSide) / 2,
            width: iconSide,
            height: iconSide
        )
        highlightLayer.frame = bounds.insetBy(dx: 2, dy: 8)
        updateLook()
    }

    override func mouseUp(with event: NSEvent) {
        guard let window, event.window == window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        _ = target?.perform(action, with: self)
    }

    private func updateLook() {
        highlightLayer.backgroundColor = isHovered
            ? CaptureBarStyle.hoverFill.cgColor
            : CGColor.clear
    }
}

// MARK: - CaptureBarModeButton

private final class CaptureBarModeButton: NSControl {
    let mode: CaptureMode

    var isActiveMode: Bool = false {
        didSet { updateLook() }
    }

    private let actionTitle: String
    private let highlightLayer = CALayer()
    private let recordingDotLayer = CALayer()
    private let iconView = NSImageView()
    private var isHovered = false

    init(mode: CaptureMode, sfSymbol: String, label: String) {
        self.mode = mode
        self.actionTitle = label
        super.init(frame: .zero)
        wantsLayer = true
        // Hover labels use ToastWindow; skip the system tooltip so they don't double up.
        highlightLayer.cornerRadius = CaptureBarStyle.hoverCornerRadius
        layer?.addSublayer(highlightLayer)

        let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        iconView.image = NSImage(systemSymbolName: sfSymbol, accessibilityDescription: label)?
            .withSymbolConfiguration(cfg)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor

        if mode.isRecording {
            recordingDotLayer.backgroundColor = NSColor.secondaryLabelColor.cgColor
            recordingDotLayer.cornerRadius = 5
            layer?.addSublayer(recordingDotLayer)
        }

        setAccessibilityLabel(label)
        addSubview(iconView)
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateLook()
        guard let window else { return }
        let buttonScreen = window.convertToScreen(convert(bounds, to: nil))
        // Sit above the full bar chrome (including options row), centered on this button.
        let anchor = NSRect(
            x: buttonScreen.minX,
            y: window.frame.maxY,
            width: buttonScreen.width,
            height: 0
        )
        ToastWindow.show(
            message: actionTitle,
            aboveScreenRect: anchor,
            chrome: .darkNeutral,
            hostWindow: window,
            autoDismiss: false
        )
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateLook()
        ToastWindow.dismissCurrent()
    }

    override func layout() {
        super.layout()

        let iconSide: CGFloat = 28
        iconView.frame = NSRect(
            x: (bounds.width - iconSide) / 2,
            y: (bounds.height - iconSide) / 2,
            width: iconSide,
            height: iconSide
        )
        highlightLayer.frame = iconView.frame
            .insetBy(dx: -CaptureBarStyle.hoverPadding, dy: -CaptureBarStyle.hoverPadding)
            .intersection(bounds.insetBy(dx: 2, dy: 2))

        if mode.isRecording {
            let dot: CGFloat = 10
            // Sit flush on the bottom-right corner of the mode icon box.
            recordingDotLayer.frame = NSRect(
                x: iconView.frame.maxX - dot,
                y: iconView.frame.minY,
                width: dot,
                height: dot
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let window, event.window == window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        _ = target?.perform(action, with: self)
    }

    private func updateLook() {
        if isActiveMode {
            highlightLayer.backgroundColor = CaptureBarStyle.activeFill.cgColor
        } else if isHovered {
            highlightLayer.backgroundColor = CaptureBarStyle.hoverFill.cgColor
        } else {
            highlightLayer.backgroundColor = .clear
        }
    }
}

// MARK: - CaptureBarMediaButton

/// macOS screenshot-style control: icon + chevron, opens a popup menu on click.
private final class CaptureBarMediaButton: NSControl {
    var isMediaActive = false {
        didSet { updateHighlight() }
    }

    private let activeSymbol: String
    private let inactiveSymbol: String
    private let highlightLayer = CALayer()
    private let chevronView = NSImageView()
    private let iconView = NSImageView()
    private var isHovered = false

    init(baseSymbol: String, activeSymbol: String, inactiveSymbol: String, accessibilityLabel: String) {
        self.activeSymbol = activeSymbol
        self.inactiveSymbol = inactiveSymbol
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = accessibilityLabel

        highlightLayer.cornerRadius = CaptureBarStyle.hoverCornerRadius
        layer?.addSublayer(highlightLayer)

        chevronView.imageScaling = .scaleProportionallyDown
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(chevronView)
        addSubview(iconView)

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHighlight()
    }

    override func layout() {
        super.layout()
        let padTop: CGFloat = 8
        let chevronSize = NSSize(width: 8, height: 5)
        let iconSide: CGFloat = 18
        let gap: CGFloat = 3

        chevronView.frame = NSRect(
            x: (bounds.width - chevronSize.width) / 2,
            y: bounds.height - padTop - chevronSize.height,
            width: chevronSize.width,
            height: chevronSize.height
        )
        iconView.frame = NSRect(
            x: (bounds.width - iconSide) / 2,
            y: chevronView.frame.minY - gap - iconSide,
            width: iconSide,
            height: iconSide
        )

        let contentRect = iconView.frame.union(chevronView.frame)
        highlightLayer.frame = contentRect
            .insetBy(dx: -CaptureBarStyle.hoverPadding, dy: -CaptureBarStyle.hoverPadding)
            .intersection(bounds.insetBy(dx: 2, dy: 2))
    }

    override func mouseUp(with event: NSEvent) {
        guard let window, event.window == window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        _ = target?.perform(action, with: self)
    }

    private func updateAppearance() {
        let symbol = isMediaActive ? activeSymbol : inactiveSymbol
        let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.contentTintColor = isMediaActive ? .systemBlue : .labelColor

        let chevronCfg = NSImage.SymbolConfiguration(pointSize: 6, weight: .bold)
        chevronView.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronCfg)
        chevronView.contentTintColor = .secondaryLabelColor
        updateHighlight()
    }

    private func updateHighlight() {
        if isMediaActive {
            highlightLayer.backgroundColor = CaptureBarStyle.activeFill.cgColor
        } else if isHovered {
            highlightLayer.backgroundColor = CaptureBarStyle.hoverFill.cgColor
        } else {
            highlightLayer.backgroundColor = .clear
        }
    }
}

// MARK: - CaptureBarActionButton

/// Primary Capture / Record control — same `GrabbitButtonStyle` as Kitchen Sink / View All.
private struct CaptureBarActionButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.grabbitProminent)
            .disabled(!isEnabled)
            .fixedSize()
    }
}

// MARK: - CaptureBarWindowPicker

private final class CaptureBarWindowPickerCell: NSButtonCell {
    private let padding = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    private func padded(_ rect: NSRect) -> NSRect {
        NSRect(
            x: rect.origin.x + padding.left,
            y: rect.origin.y + padding.bottom,
            width: rect.width - padding.left - padding.right,
            height: rect.height - padding.top - padding.bottom
        )
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: padded(rect))
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        super.imageRect(forBounds: padded(rect))
    }
}

/// Full-width picker shown above the capture bar when capturing a window or app.
private final class CaptureBarWindowPicker: NSButton {
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let pickerCell = CaptureBarWindowPickerCell(textCell: "")
        pickerCell.isBordered = false
        cell = pickerCell
        title = "Select a window…"
        imagePosition = .imageRight
        image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Choose")
        font = NSFont.grabbit(.body)
        alignment = .left
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = CaptureBarStyle.hoverCornerRadius
        contentTintColor = .labelColor
        lineBreakMode = .byTruncatingTail
        updateHoverLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHoverLook()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHoverLook()
    }

    private func updateHoverLook() {
        if isHovered {
            layer?.backgroundColor = CaptureBarStyle.hoverFill.cgColor
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        }
    }
}

// MARK: - CaptureMediaDevices

private enum CaptureMediaDevices {
    static func audioInputDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func localizedName(for device: AVCaptureDevice) -> String {
        device.localizedName
    }
}

// MARK: - CaptureBar

final class CaptureBar: NSPanel {

    private static var instance: CaptureBar?

    /// True while the capture bar is intentionally on screen (set before async preview work).
    private(set) static var isPresented = false

    /// Frontmost app/window captured at the moment the bar is invoked (⌘⇧5), before Grabbit's
    /// own panel steals focus. Auto-Organize classification must use this, not a fresh
    /// `NSWorkspace.shared.frontmostApplication` read taken after capture — by then Grabbit
    /// itself is frontmost and classification would describe Grabbit instead of the source app.
    private(set) static var capturedEarlySignals: EarlyCaptureSignals?

    /// Read-only access to the active bar (nil until first `show()` call).
    static var shared: CaptureBar? { instance }

    private var selectedMode: CaptureMode = .screenshotRegion {
        didSet { refreshSelection() }
    }

    private var modeButtons: [(CaptureMode, CaptureBarModeButton)] = []
    private var captureButtonHosting: NSHostingView<CaptureBarActionButton>?
    private var captureButtonTitle = "Capture"
    private var captureButtonIsEnabled = true
    private weak var systemAudioButton: CaptureBarMediaButton?
    private weak var micButton: CaptureBarMediaButton?
    private weak var optionsMediaSeparator: NSBox?
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    private let barHeight: CGFloat = 72
    private let pickerRowHeight: CGFloat = 44
    private let pickerGap: CGFloat = 6
    private weak var barEffectView: NSVisualEffectView?
    private weak var optionsRow: NSVisualEffectView?
    private weak var windowPickerButton: CaptureBarWindowPicker?
    private weak var rootView: NSView?

    private var recordableWindows: [SCWindow] = []
    private var selectedRecordWindowID: CGWindowID?
    private var selectedRecordAppBundleID: String?
    private var selectedRegionRect: CGRect?
    private var recordableWindowsLoadGeneration = 0

    private var showsTargetPicker: Bool {
        selectedMode.isWindowCapture || selectedMode.isAppCapture
    }

    private var showsOptionsRow: Bool {
        selectedMode.isRecording || selectedMode.isWindowCapture || selectedMode.isAppCapture
    }

    private var showsRecordingMediaControls: Bool {
        selectedMode.isRecording
    }

    private var isRegionMode: Bool {
        selectedMode == .screenshotRegion || selectedMode == .recordRegion
    }

    private var selectedMicID: String? = nil
    private var systemAudioEnabled = false

    var micEnabled: Bool { selectedMicID != nil }

    // MARK: - Entry Points

    static func show() {
        // Must run before anything below touches focus — this is the last point where
        // NSWorkspace.shared.frontmostApplication still reflects the app the user was
        // actually looking at, rather than Grabbit's own panel.
        capturedEarlySignals = CaptureClassifier.gatherEarlyCaptureSignals()
        DispatchQueue.main.async {
            if instance == nil {
                instance = CaptureBar()
            }
            isPresented = true
            let bar = instance
            bar?.selectedRegionRect = nil
            bar?.selectedMode = .screenshotRegion
            // Force refresh even when mode was already screenshotRegion (didSet skips).
            bar?.refreshSelection()
            bar?.repositionOnScreen()
            bar?.startEscapeMonitor()
            bar?.makeKeyAndOrderFront(nil)
        }
    }

    static func dismiss() {
        RegionSelector.hide()
        dismissForRecording()
    }

    /// Hides the capture bar when starting a recording.
    static func dismissForRecording() {
        let dismiss = {
            isPresented = false
            guard let bar = instance else { return }
            bar.selectedRegionRect = nil
            bar.stopEscapeMonitor()
            RecordingBackgroundPreviewWindow.hide()
            bar.orderOut(nil)
        }
        if Thread.isMainThread {
            dismiss()
        } else {
            DispatchQueue.main.async {
                dismiss()
            }
        }
    }

    /// Restores default media settings after a recording ends.
    static func resetMediaSettings() {
        DispatchQueue.main.async {
            guard let bar = instance else { return }
            bar.selectedMicID = nil
            bar.systemAudioEnabled = false
            bar.updateMediaButtonAppearances()
            RecordingBackgroundPreviewWindow.hide()
            if isPresented, bar.showsTargetPicker || bar.selectedMode.isRecording {
                bar.applyCapturePreview()
            }
        }
    }

    override func orderOut(_ sender: Any?) {
        CaptureBar.isPresented = false
        RecordingBackgroundPreviewWindow.hide()
        super.orderOut(sender)
    }

    // MARK: - Init

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level.popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }

    // MARK: - Build UI

    private struct BarLayout {
        let totalWidth: CGFloat
        let horizontalPad: CGFloat
    }

    private static func computeBarLayout() -> BarLayout {
        let hPad: CGFloat = 14
        let closeW: CGFloat = 32
        let btnW: CGFloat = 58
        let sepPad: CGFloat = 8
        let sepW: CGFloat = 1
        let captureW: CGFloat = 82

        let allButtonCount = 8
        let separatorCount = 3
        let totalW = hPad
            + closeW
            + CGFloat(allButtonCount) * btnW
            + CGFloat(separatorCount) * (sepW + sepPad * 2)
            + captureW + hPad
        return BarLayout(totalWidth: totalW, horizontalPad: hPad)
    }

    private var barWidth: CGFloat {
        Self.computeBarLayout().totalWidth
    }

    private static let mediaToggleW: CGFloat = 32
    private static let mediaToggleGap: CGFloat = 4
    private static let mediaControlCount = 2

    private static var mediaControlsWidth: CGFloat {
        let count = CGFloat(mediaControlCount)
        return count * mediaToggleW + (count - 1) * mediaToggleGap
    }

    private func buildUI() {
        let barH = barHeight
        let btnW:       CGFloat = 58
        let btnH:       CGFloat = 56
        let hPad = Self.computeBarLayout().horizontalPad
        let sepPad:     CGFloat = 8
        let sepW:       CGFloat = 1
        let toggleW:    CGFloat = Self.mediaToggleW
        let toggleGap:  CGFloat = Self.mediaToggleGap
        let totalW = barWidth

        typealias BSpec = (CaptureMode, String, String)
        let groups: [[BSpec]] = [
            [
                (.screenshotFullScreen, "rectangle.fill",   "Full Screen"),
                (.screenshotWindow,     "macwindow",        "Window"),
                (.screenshotApp,        "arrow.up.and.down.square", "Scrolling Capture"),
                (.screenshotRegion,     "rectangle.dashed", "Region"),
            ],
            [
                (.recordFullScreen, "rectangle.fill",   "Record Full Screen"),
                (.recordWindow,     "macwindow",        "Record Window"),
                (.recordApp,        "app.fill",         "Record App"),
                (.recordRegion,     "rectangle.dashed", "Record Region"),
            ],
        ]

        let root = NSView(frame: NSRect(x: 0, y: 0, width: totalW, height: barH))
        contentView = root
        rootView = root

        let vfx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: totalW, height: barH))
        vfx.material = .menu
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = DesignTokens.Radius.lg
        vfx.layer?.masksToBounds = true
        root.addSubview(vfx)
        barEffectView = vfx

        let optionsRowView = NSVisualEffectView(frame: NSRect(
            x: 0,
            y: barH + pickerGap,
            width: totalW,
            height: pickerRowHeight
        ))
        optionsRowView.material = .menu
        optionsRowView.blendingMode = .behindWindow
        optionsRowView.state = .active
        optionsRowView.wantsLayer = true
        optionsRowView.layer?.cornerRadius = DesignTokens.Radius.lg
        optionsRowView.layer?.masksToBounds = true
        optionsRowView.isHidden = true
        root.addSubview(optionsRowView)
        optionsRow = optionsRowView

        let pickerH: CGFloat = 32
        let pickerBtn = CaptureBarWindowPicker(frame: CGRect(
            x: hPad,
            y: (pickerRowHeight - pickerH) / 2,
            width: totalW - hPad * 2,
            height: pickerH
        ))
        pickerBtn.target = self
        pickerBtn.action = #selector(windowPickerClicked(_:))
        optionsRowView.addSubview(pickerBtn)
        windowPickerButton = pickerBtn

        let mediaBtnY: CGFloat = (pickerRowHeight - 36) / 2
        var mediaX = totalW - hPad - Self.mediaControlsWidth

        // System audio popup
        let audioBtn = CaptureBarMediaButton(
            baseSymbol: "speaker.wave.2",
            activeSymbol: "speaker.wave.2.fill",
            inactiveSymbol: "speaker.wave.2",
            accessibilityLabel: "System Audio"
        )
        audioBtn.frame = CGRect(x: mediaX, y: mediaBtnY, width: toggleW, height: 36)
        audioBtn.target = self
        audioBtn.action = #selector(systemAudioMenuClicked(_:))
        optionsRowView.addSubview(audioBtn)
        systemAudioButton = audioBtn
        mediaX += toggleW + toggleGap

        // Microphone popup
        let micBtn = CaptureBarMediaButton(
            baseSymbol: "mic",
            activeSymbol: "mic.fill",
            inactiveSymbol: "mic",
            accessibilityLabel: "Microphone"
        )
        micBtn.frame = CGRect(x: mediaX, y: mediaBtnY, width: toggleW, height: 36)
        micBtn.target = self
        micBtn.action = #selector(micMenuClicked(_:))
        optionsRowView.addSubview(micBtn)
        micButton = micBtn

        let optionsMediaSep = NSBox(frame: .zero)
        optionsMediaSep.boxType = NSBox.BoxType.separator
        optionsRowView.addSubview(optionsMediaSep)
        optionsMediaSeparator = optionsMediaSep

        setContentSize(NSSize(width: totalW, height: barH))

        var x = hPad
        let modeBtnY: CGFloat = (barH - btnH) / 2
        let closeW: CGFloat = 32
        let sepInset: CGFloat = 14

        let closeBtn = CaptureBarCloseButton(frame: CGRect(x: x, y: modeBtnY, width: closeW, height: btnH))
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        vfx.addSubview(closeBtn)
        x += closeW + sepPad

        let closeSep = NSBox(frame: CGRect(x: x, y: sepInset, width: sepW, height: barH - sepInset * 2))
        closeSep.boxType = NSBox.BoxType.separator
        vfx.addSubview(closeSep)
        x += sepW + sepPad

        for group in groups {
            for spec in group {
                let btn = CaptureBarModeButton(mode: spec.0, sfSymbol: spec.1, label: spec.2)
                btn.frame = CGRect(x: x, y: modeBtnY, width: btnW, height: btnH)
                btn.target = self
                btn.action = #selector(modeTapped(_:))
                vfx.addSubview(btn)
                modeButtons.append((spec.0, btn))
                x += btnW
            }
            x += sepPad
            let sep = NSBox(frame: CGRect(x: x, y: sepInset, width: sepW, height: barH - sepInset * 2))
            sep.boxType = NSBox.BoxType.separator
            vfx.addSubview(sep)
            x += sepW + sepPad
        }

        let hosting = NSHostingView(rootView: makeCaptureActionButton())
        hosting.sizingOptions = [.intrinsicContentSize]
        vfx.addSubview(hosting)
        captureButtonHosting = hosting

        layoutMainBar()
        updateMediaButtonAppearances()
        refreshSelection()
    }

    private func makeCaptureActionButton() -> CaptureBarActionButton {
        CaptureBarActionButton(
            title: captureButtonTitle,
            isEnabled: captureButtonIsEnabled,
            action: { [weak self] in self?.captureTapped() }
        )
    }

    private func reloadCaptureActionButton() {
        captureButtonHosting?.rootView = makeCaptureActionButton()
        layoutMainBar()
    }

    private func layoutMainBar() {
        let barH = barHeight
        let hPad = Self.computeBarLayout().horizontalPad
        let totalW = barWidth

        barEffectView?.frame = NSRect(x: 0, y: 0, width: totalW, height: barH)
        rootView?.frame.size.width = totalW

        guard let hosting = captureButtonHosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        hosting.frame = CGRect(
            x: totalW - hPad - width,
            y: (barH - height) / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Escape

    private func startEscapeMonitor() {
        stopEscapeMonitor()
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            CaptureBar.dismiss()
        }
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == 53 else { return event }
            CaptureBar.dismiss()
            return nil
        }
    }

    private func stopEscapeMonitor() {
        if let monitor = escapeGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeGlobalMonitor = nil
        }
        if let monitor = escapeLocalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeLocalMonitor = nil
        }
    }

    override func cancelOperation(_ sender: Any?) {
        CaptureBar.dismiss()
    }

    // MARK: - Position

    private func repositionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        let sz = frame.size
        let x = (vis.midX - sz.width / 2).rounded()
        let y = (vis.minY + 24).rounded()
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Resizes content while keeping the window's bottom edge fixed so the bar does not shift.
    private func setContentSizeKeepingBottomFixed(_ size: NSSize) {
        let bottomY = frame.minY
        var newFrame = frameRect(forContentRect: NSRect(origin: .zero, size: size))
        newFrame.origin.x = frame.origin.x
        newFrame.origin.y = bottomY
        setFrame(newFrame, display: true)
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        CaptureBar.dismiss()
    }

    @objc private func modeTapped(_ sender: NSControl) {
        guard let btn = sender as? CaptureBarModeButton else { return }
        selectedMode = btn.mode
    }

    @objc private func captureTapped() {
        let mode = selectedMode
        let micOn = micEnabled
        let micID = selectedMicID
        let sysAudio = systemAudioEnabled
        let recBackground = RecordingBackgroundStyle.none

        switch mode {
        case .screenshotRegion:
            guard let rect = selectedRegionRect else { return }
            RegionSelector.hide()
            CaptureBar.dismiss()
            ScreenshotEngine.captureRegion(rect) { img in
                guard let img else { return }
                CapturePipeline.finishScreenshot(
                    img,
                    captureRect: rect,
                    earlySignals: CaptureBar.capturedEarlySignals
                )
            }

        case .screenshotWindow:
            guard let windowID = selectedRecordWindowID else { return }
            RegionSelector.hide()
            CaptureBar.dismiss()
            Task {
                await WindowSelector.activateWindow(windowID)
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        ScreenshotEngine.captureWindow(windowID, background: recBackground) { img in
                            guard let img else { return }
                            CapturePipeline.finishScreenshot(
                                img,
                                captureRect: nil,
                                earlySignals: CaptureBar.capturedEarlySignals
                            )
                        }
                    }
                }
            }

        case .screenshotApp:
            guard let bundleID = selectedRecordAppBundleID else { return }
            RegionSelector.hide()
            CaptureBar.dismiss()
            Task {
                await WindowSelector.activateApp(bundleIdentifier: bundleID)
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        ScreenshotEngine.captureApp(bundleIdentifier: bundleID) { img, rect in
                            guard let img else { return }
                            CapturePipeline.finishScreenshot(
                                img,
                                captureRect: rect,
                                earlySignals: CaptureBar.capturedEarlySignals
                            )
                        }
                    }
                }
            }

        case .screenshotFullScreen:
            guard let rect = NSScreen.main?.frame else { return }
            RegionSelector.hide()
            CaptureBar.dismiss()
            ScreenshotEngine.captureRegion(rect) { img in
                guard let img else { return }
                CapturePipeline.finishScreenshot(
                    img,
                    captureRect: rect,
                    earlySignals: CaptureBar.capturedEarlySignals
                )
            }

        case .recordWindow:
            guard let windowID = selectedRecordWindowID else { return }
            RegionSelector.hide()
            CaptureBar.dismissForRecording()
            Task {
                await WindowSelector.activateWindow(windowID)
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        Task {
                            await CaptureBar.prepareRecordingPreviewForCapture()
                            CaptureBar.executeRecording(
                                captureTarget: .window(windowID),
                                recordingBackground: recBackground,
                                micEnabled: micOn,
                                systemAudioEnabled: sysAudio,
                                micDeviceID: micID
                            )
                        }
                    }
                }
            }

        case .recordApp:
            guard let bundleID = selectedRecordAppBundleID else { return }
            RegionSelector.hide()
            CaptureBar.dismissForRecording()
            Task {
                await WindowSelector.activateApp(bundleIdentifier: bundleID)
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        Task {
                            await CaptureBar.prepareRecordingPreviewForCapture()
                            CaptureBar.executeRecording(
                                captureTarget: .app(bundleIdentifier: bundleID),
                                recordingBackground: recBackground,
                                micEnabled: micOn,
                                systemAudioEnabled: sysAudio,
                                micDeviceID: micID
                            )
                        }
                    }
                }
            }

        case .recordRegion:
            guard let rect = selectedRegionRect else { return }
            RegionSelector.hide()
            CaptureBar.dismissForRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                CaptureBar.executeRecording(
                    captureTarget: .region(rect),
                    recordingBackground: recBackground,
                    micEnabled: micOn,
                    systemAudioEnabled: sysAudio,
                    micDeviceID: micID
                )
            }

        case .recordFullScreen:
            RegionSelector.hide()
            CaptureBar.dismissForRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Task {
                    await CaptureBar.prepareRecordingPreviewForCapture()
                    CaptureBar.executeRecording(
                        captureTarget: .fullScreen,
                        recordingBackground: recBackground,
                        micEnabled: micOn,
                        systemAudioEnabled: sysAudio,
                        micDeviceID: micID
                    )
                }
            }
        }
    }

    /// Stops preview capture so RecordingEngine can capture the same window.
    private static func prepareRecordingPreviewForCapture() async {
        guard RecordingBackgroundPreviewWindow.isVisible else { return }
        await RecordingBackgroundPreviewWindow.transitionToRecording()
    }

    // MARK: - Capture Execution

    private static func executeRecording(
        captureTarget: RecordingCaptureTarget,
        recordingBackground: RecordingBackgroundStyle = .none,
        micEnabled: Bool = false,
        systemAudioEnabled: Bool = false,
        micDeviceID: String? = nil
    ) {
        RecordingEngine.shared.startRecording(
            captureTarget: captureTarget,
            recordingBackground: recordingBackground,
            micEnabled: micEnabled,
            systemAudioEnabled: systemAudioEnabled,
            micDeviceID: micDeviceID
        )
    }

    // MARK: - Media Popup Menus

    @objc private func systemAudioMenuClicked(_ sender: NSControl) {
        let menu = NSMenu()

        let noneItem = NSMenuItem(title: "None", action: #selector(selectSystemAudio(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.tag = 0
        noneItem.state = !systemAudioEnabled ? .on : .off
        menu.addItem(noneItem)

        let onItem = NSMenuItem(title: "System Audio", action: #selector(selectSystemAudio(_:)), keyEquivalent: "")
        onItem.target = self
        onItem.tag = 1
        onItem.state = systemAudioEnabled ? .on : .off
        menu.addItem(onItem)

        popMenu(menu, from: sender)
    }

    @objc private func micMenuClicked(_ sender: NSControl) {
        let menu = NSMenu()

        let noneItem = NSMenuItem(title: "None", action: #selector(selectMic(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.representedObject = nil as String?
        noneItem.state = selectedMicID == nil ? .on : .off
        menu.addItem(noneItem)

        let devices = CaptureMediaDevices.audioInputDevices()
        if !devices.isEmpty {
            menu.addItem(.separator())
            for device in devices {
                let item = NSMenuItem(
                    title: CaptureMediaDevices.localizedName(for: device),
                    action: #selector(selectMic(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = device.uniqueID
                item.state = selectedMicID == device.uniqueID ? .on : .off
                menu.addItem(item)
            }
        }

        popMenu(menu, from: sender)
    }

    @objc private func selectSystemAudio(_ sender: NSMenuItem) {
        systemAudioEnabled = sender.tag == 1
        updateMediaButtonAppearances()
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        selectedMicID = sender.representedObject as? String
        updateMediaButtonAppearances()
    }

    private func popMenu(_ menu: NSMenu, from button: NSView, above: Bool = false) {
        if above {
            menu.font = NSFont.grabbit(.body)
        }
        let y = above ? button.bounds.maxY : button.bounds.maxY + 2
        let loc = NSPoint(x: button.bounds.midX, y: y)
        menu.popUp(positioning: above ? menu.items.last : nil, at: loc, in: button)
    }

    // MARK: - Window Picker

    @objc private func windowPickerClicked(_ sender: NSButton) {
        Task {
            let windows = await WindowSelector.fetchRecordableWindows()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.recordableWindows = windows
                self.applyDefaultCaptureTarget(from: windows)
                self.updateWindowPickerTitle()
                self.updateCaptureButtonState()
                guard !windows.isEmpty else { return }

                let menu = NSMenu()
                if self.selectedMode.isAppCapture {
                    let apps = WindowSelector.recordableApps(from: windows)
                    for app in apps {
                        let item = NSMenuItem(
                            title: app.applicationName,
                            action: #selector(self.selectRecordApp(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.representedObject = app.bundleIdentifier
                        item.state = self.selectedRecordAppBundleID == app.bundleIdentifier ? .on : .off
                        menu.addItem(item)
                    }
                } else {
                    for window in windows {
                        let item = NSMenuItem(
                            title: WindowSelector.displayName(for: window),
                            action: #selector(self.selectRecordWindow(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.representedObject = NSNumber(value: window.windowID)
                        item.state = self.selectedRecordWindowID == window.windowID ? .on : .off
                        menu.addItem(item)
                    }
                }
                self.popMenu(menu, from: sender, above: true)
            }
        }
    }

    @objc private func selectRecordWindow(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let windowID = CGWindowID(number.uint32Value)
        selectedRecordWindowID = windowID
        updateWindowPickerTitle()
        updateCaptureButtonState()
        applyCapturePreview()
        Task {
            await WindowSelector.activateWindow(windowID)
        }
    }

    @objc private func selectRecordApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        selectedRecordAppBundleID = bundleID
        updateWindowPickerTitle()
        updateCaptureButtonState()
        applyCapturePreview()
        Task {
            await WindowSelector.activateApp(bundleIdentifier: bundleID)
        }
    }

    private func applyDefaultCaptureTarget(from windows: [SCWindow]) {
        if selectedMode.isAppCapture {
            let apps = WindowSelector.recordableApps(from: windows)
            if selectedRecordAppBundleID == nil
                || !apps.contains(where: { $0.bundleIdentifier == selectedRecordAppBundleID }) {
                selectedRecordAppBundleID = WindowSelector.defaultAppBundleID(
                    from: windows,
                    preferredBundleID: CaptureBar.capturedEarlySignals?.bundleID
                )
            }
        } else if selectedRecordWindowID == nil
            || !windows.contains(where: { $0.windowID == selectedRecordWindowID }) {
            selectedRecordWindowID = WindowSelector.defaultWindowID(from: windows)
        }
    }

    private func loadRecordableWindows() {
        recordableWindowsLoadGeneration += 1
        let generation = recordableWindowsLoadGeneration
        Task {
            let windows = await WindowSelector.fetchRecordableWindows()
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard generation == self.recordableWindowsLoadGeneration else { return }
                self.recordableWindows = windows
                self.applyDefaultCaptureTarget(from: windows)
                self.updateWindowPickerTitle()
                self.updateCaptureButtonState()
                self.applyCapturePreview()
            }
        }
    }

    private func updateWindowPickerTitle() {
        if selectedMode.isAppCapture {
            let apps = WindowSelector.recordableApps(from: recordableWindows)
            if let id = selectedRecordAppBundleID,
               let app = apps.first(where: { $0.bundleIdentifier == id }) {
                windowPickerButton?.title = app.applicationName
            } else if recordableWindows.isEmpty {
                windowPickerButton?.title = "Loading apps…"
            } else {
                windowPickerButton?.title = "Select an app…"
            }
        } else if let id = selectedRecordWindowID,
           let window = recordableWindows.first(where: { $0.windowID == id }) {
            windowPickerButton?.title = WindowSelector.displayName(for: window)
        } else if recordableWindows.isEmpty {
            windowPickerButton?.title = "Loading windows…"
        } else {
            windowPickerButton?.title = "Select a window…"
        }
    }

    private func updateWindowPickerVisibility() {
        optionsRow?.isHidden = !showsOptionsRow

        windowPickerButton?.isHidden = !showsTargetPicker
        let showMediaSeparator = showsTargetPicker && showsRecordingMediaControls
        optionsMediaSeparator?.isHidden = !showMediaSeparator

        for button in [systemAudioButton, micButton].compactMap({ $0 }) {
            button.isHidden = !showsRecordingMediaControls
        }

        layoutMainBar()
        layoutOptionsRow()

        let totalH = showsOptionsRow ? (barHeight + pickerGap + pickerRowHeight) : barHeight
        let newSize = NSSize(width: barWidth, height: totalH)
        if contentView?.frame.size != newSize {
            setContentSizeKeepingBottomFixed(newSize)
            repositionOnScreen()
        }

        if showsTargetPicker {
            loadRecordableWindows()
        } else {
            updateCaptureButtonState()
        }
    }

    private func updateCaptureButtonState() {
        let enabled: Bool
        switch selectedMode {
        case .screenshotRegion, .recordRegion:
            enabled = selectedRegionRect != nil
        case .screenshotWindow, .recordWindow:
            enabled = selectedRecordWindowID != nil
        case .screenshotApp, .recordApp:
            enabled = selectedRecordAppBundleID != nil
        default:
            enabled = true
        }
        guard captureButtonIsEnabled != enabled else { return }
        captureButtonIsEnabled = enabled
        reloadCaptureActionButton()
    }

    private func applyRegionSelector() {
        if isRegionMode {
            // Keep the same overlay (and selection) when switching between
            // screenshot region and record region.
            if RegionSelector.isInteractiveVisible {
                updateCaptureButtonState()
                return
            }
            RegionSelector.showInteractive(initialRect: selectedRegionRect) { [weak self] rect in
                guard let self else { return }
                self.selectedRegionRect = rect
                self.updateCaptureButtonState()
            }
        } else {
            RegionSelector.hide()
            updateCaptureButtonState()
        }
    }

    private func layoutOptionsRow() {
        guard let optionsRow else { return }
        let hPad = Self.computeBarLayout().horizontalPad
        let totalW = barWidth
        let pickerH: CGFloat = 32
        let toggleW = Self.mediaToggleW
        let toggleGap = Self.mediaToggleGap
        let mediaW = Self.mediaControlsWidth
        let sepPad: CGFloat = 8
        let sepW: CGFloat = 1
        let mediaBtnY: CGFloat = (pickerRowHeight - 36) / 2
        var mediaX: CGFloat

        let showWindowPicker = showsTargetPicker
        let showMediaControls = showsRecordingMediaControls

        if showWindowPicker && showMediaControls {
            let sepX = totalW - hPad - mediaW - sepPad - sepW
            let sepH: CGFloat = pickerRowHeight - 16
            optionsMediaSeparator?.frame = CGRect(x: sepX, y: 8, width: sepW, height: sepH)

            let pickerMaxX = sepX - sepPad
            windowPickerButton?.frame = CGRect(
                x: hPad,
                y: (pickerRowHeight - pickerH) / 2,
                width: max(120, pickerMaxX - hPad),
                height: pickerH
            )

            mediaX = totalW - hPad - mediaW
        } else if showWindowPicker {
            windowPickerButton?.frame = CGRect(
                x: hPad,
                y: (pickerRowHeight - pickerH) / 2,
                width: totalW - hPad * 2,
                height: pickerH
            )
            optionsMediaSeparator?.frame = .zero
            mediaX = totalW
        } else {
            windowPickerButton?.frame = .zero
            mediaX = (totalW - mediaW) / 2
        }

        for button in [systemAudioButton, micButton].compactMap({ $0 }) {
            button.frame = CGRect(x: mediaX, y: mediaBtnY, width: toggleW, height: 36)
            mediaX += toggleW + toggleGap
        }

        optionsRow.frame = NSRect(
            x: 0,
            y: barHeight + pickerGap,
            width: totalW,
            height: pickerRowHeight
        )
    }

    // MARK: - Capture Preview

    private func applyCapturePreview() {
        guard CaptureBar.isPresented, isVisible else {
            RecordingBackgroundPreviewWindow.hide()
            return
        }

        switch selectedMode {
        case .recordWindow, .screenshotWindow:
            guard selectedRecordWindowID != nil else {
                RecordingBackgroundPreviewWindow.hide()
                return
            }
        case .recordApp, .screenshotApp:
            guard selectedRecordAppBundleID != nil else {
                RecordingBackgroundPreviewWindow.hide()
                return
            }
        case .recordFullScreen:
            break
        case .recordRegion, .screenshotRegion, .screenshotFullScreen:
            RecordingBackgroundPreviewWindow.hide()
            return
        }

        let config = RecordingBackgroundPreviewWindow.Configuration(
            captureMode: selectedMode,
            windowID: selectedMode.isAppCapture
                ? WindowSelector.primaryWindow(for: selectedRecordAppBundleID ?? "", in: recordableWindows)?.windowID
                : selectedRecordWindowID,
            appBundleID: selectedRecordAppBundleID,
            background: .none
        )
        RecordingBackgroundPreviewWindow.showThumbnail(configuration: config)
    }

    private func updateMediaButtonAppearances() {
        systemAudioButton?.isMediaActive = systemAudioEnabled
        micButton?.isMediaActive = selectedMicID != nil
    }

    // MARK: - Refresh

    private func refreshSelection() {
        for (mode, btn) in modeButtons {
            btn.isActiveMode = (mode == selectedMode)
        }
        let title = selectedMode.isRecording ? "Record" : "Capture"
        if captureButtonTitle != title {
            captureButtonTitle = title
            reloadCaptureActionButton()
        }

        if showsTargetPicker || selectedMode.isRecording {
            applyCapturePreview()
        } else {
            RecordingBackgroundPreviewWindow.hide()
        }

        updateWindowPickerVisibility()
        applyRegionSelector()
    }
}
