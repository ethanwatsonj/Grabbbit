//
//  ToastView.swift
//  Grabbit
//
//  Created by Ethan Watson on 6/27/26.
//

import AppKit

enum ToastChromeStyle {
    /// Frosted HUD material (default).
    case adaptive
    /// Solid dark neutral fill — Capture Bar hover labels.
    case darkNeutral
}

enum ToastAnchorPlacement {
    /// Toast sits below the anchor (e.g. under a title bar).
    case below
    /// Toast sits above the anchor (e.g. over the Capture Bar).
    case above
}

final class ToastWindow: NSPanel {

    private static var current: ToastWindow?

    let associatedCaptureID: UUID?
    private let onTap: () -> Void
    private var dismissTimer: Timer?
    private weak var messageActionButton: NSButton?
    private var messageActionTrampoline: ToastActionTrampoline?
    private var anchorScreenRect: NSRect?
    private var anchorPlacement: ToastAnchorPlacement = .below

    // MARK: - Entry point

    static func show(image: NSImage, associatedCaptureID: UUID?, onTap: @escaping () -> Void) {
        DispatchQueue.main.async {
            current?.cancelAndClose()
            let window = ToastWindow(image: image, associatedCaptureID: associatedCaptureID, onTap: onTap)
            current = window
            window.presentAnimated()
        }
    }

    static func show(
        message: String,
        associatedCaptureID: UUID? = nil,
        aboveScreenRect: NSRect? = nil,
        chrome: ToastChromeStyle = .adaptive,
        hostWindow: NSWindow? = nil,
        autoDismiss: Bool = true
    ) {
        DispatchQueue.main.async {
            current?.cancelAndClose()
            let window = ToastWindow(
                message: message,
                associatedCaptureID: associatedCaptureID,
                anchorScreenRect: aboveScreenRect,
                anchorPlacement: aboveScreenRect == nil ? .below : .above,
                chrome: chrome
            )
            current = window
            window.presentAnimated(hostWindow: hostWindow, autoDismiss: autoDismiss)
        }
    }

    /// Dismisses the current toast if one is showing (used for hover-only Capture Bar labels).
    static func dismissCurrent() {
        DispatchQueue.main.async {
            current?.dismissAnimated()
        }
    }

    static func show(
        message: String,
        associatedCaptureID: UUID?,
        actionTitle: String,
        anchorScreenRect: NSRect? = nil,
        hostWindow: NSWindow? = nil,
        onAction: @escaping () -> Void,
        onPresented: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            current?.cancelAndClose()
            let window = ToastWindow(
                message: message,
                associatedCaptureID: associatedCaptureID,
                actionTitle: actionTitle,
                anchorScreenRect: anchorScreenRect,
                onAction: onAction
            )
            current = window
            window.presentAnimated(hostWindow: hostWindow)
            onPresented?()
        }
    }

    // MARK: - Init

    private func configurePanel(level: NSWindow.Level) {
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    private init(image: NSImage, associatedCaptureID: UUID?, onTap: @escaping () -> Void) {
        self.associatedCaptureID = associatedCaptureID
        self.onTap = onTap

        let contentSize = ToastWindow.layoutSize(for: image)

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel(level: .floating)

        let contentView = buildContentView(image: image, size: contentSize)
        self.contentView = contentView

        positionBottomRight(contentSize: contentSize)
    }

    private init(
        message: String,
        associatedCaptureID: UUID?,
        anchorScreenRect: NSRect? = nil,
        anchorPlacement: ToastAnchorPlacement = .below,
        chrome: ToastChromeStyle = .adaptive
    ) {
        self.associatedCaptureID = associatedCaptureID
        self.anchorScreenRect = anchorScreenRect
        self.anchorPlacement = anchorPlacement
        self.onTap = {}

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel(level: anchorScreenRect == nil ? .floating : .popUpMenu)

        let (contentView, contentSize) = ToastWindow.makeMessageContent(message: message, chrome: chrome)
        self.contentView = contentView

        positionForAnchor(contentSize: contentSize)
    }

    private init(
        message: String,
        associatedCaptureID: UUID?,
        actionTitle: String,
        anchorScreenRect: NSRect?,
        onAction: @escaping () -> Void
    ) {
        self.associatedCaptureID = associatedCaptureID
        self.anchorScreenRect = anchorScreenRect
        self.anchorPlacement = .below
        self.onTap = {}

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel(level: anchorScreenRect == nil ? .floating : .popUpMenu)

        let (contentView, contentSize, actionButton) = makeMessageContent(
            message: message,
            actionTitle: actionTitle,
            onAction: onAction
        )
        self.contentView = contentView
        self.messageActionButton = actionButton

        positionForAnchor(contentSize: contentSize)
    }

    private static func layoutSize(for image: NSImage) -> NSSize {
        let maxW: CGFloat = 240
        let maxH: CGFloat = 140
        let padding = DesignTokens.Spacing.md

        let imgSize = image.size
        let scale = min(maxW / imgSize.width, maxH / imgSize.height, 1.0)
        let thumbW = max(imgSize.width * scale, 60)
        let thumbH = imgSize.height * scale

        let totalW = thumbW + padding * 2
        let totalH = thumbH + padding * 2
        return NSSize(width: totalW, height: totalH)
    }

    private static let messageFont = NSFont.grabbit(.body)
    /// Capture Bar hover labels — denser than status toasts.
    private static let compactMessageFont = DesignTokens.Typography.font(size: 12, weight: .medium)
    private static let messagePadding = NSEdgeInsets(
        top: 10,
        left: DesignTokens.Spacing.lg,
        bottom: 10,
        right: DesignTokens.Spacing.lg
    )
    private static let compactMessagePadding = NSEdgeInsets(
        top: 4,
        left: 4,
        bottom: 4,
        right: 4
    )
    private static let compactCornerRadius: CGFloat = 2

    private static func messageMetrics(for chrome: ToastChromeStyle) -> (font: NSFont, padding: NSEdgeInsets, cornerRadius: CGFloat) {
        switch chrome {
        case .adaptive:
            return (messageFont, messagePadding, DesignTokens.Radius.lg)
        case .darkNeutral:
            return (compactMessageFont, compactMessagePadding, compactCornerRadius)
        }
    }

    private static func makeToastChrome(
        size: NSSize,
        chrome: ToastChromeStyle = .adaptive
    ) -> (container: NSView, contentHost: NSView) {
        let cornerRadius = messageMetrics(for: chrome).cornerRadius
        let bounds = NSRect(origin: .zero, size: size)

        let container = NSView(frame: bounds)
        container.wantsLayer = true

        switch chrome {
        case .adaptive:
            let vfx = NSVisualEffectView(frame: bounds)
            vfx.material = .hudWindow
            vfx.blendingMode = .behindWindow
            vfx.state = .active
            vfx.wantsLayer = true
            vfx.layer?.cornerRadius = cornerRadius
            vfx.layer?.cornerCurve = .continuous
            vfx.layer?.masksToBounds = true
            container.addSubview(vfx)
            applyToastShadow(to: container, cornerRadius: cornerRadius)
            return (container, vfx)

        case .darkNeutral:
            let fill = NSView(frame: bounds)
            fill.wantsLayer = true
            fill.layer?.backgroundColor = DesignTokens.Color.toastDarkFill.ns.cgColor
            fill.layer?.cornerRadius = cornerRadius
            fill.layer?.cornerCurve = .continuous
            fill.layer?.masksToBounds = true
            container.addSubview(fill)
            applyToastShadow(to: container, cornerRadius: cornerRadius)
            return (container, fill)
        }
    }

    private static func applyToastShadow(to container: NSView, cornerRadius: CGFloat = DesignTokens.Radius.lg) {
        guard let layer = container.layer else { return }
        DesignTokens.Elevation.panel.apply(
            to: layer,
            roundedPathIn: container.bounds,
            cornerRadius: cornerRadius
        )
    }

    private static func messageLabel(for message: String, chrome: ToastChromeStyle = .adaptive) -> NSTextField {
        let metrics = messageMetrics(for: chrome)
        let label = NSTextField(labelWithString: message)
        label.font = metrics.font
        label.textColor = chrome == .darkNeutral
            ? DesignTokens.Color.textOnPrimary.ns
            : DesignTokens.Color.textPrimary.ns
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.cell?.wraps = false
        label.cell?.truncatesLastVisibleLine = false
        return label
    }

    private static func makeMessageContent(
        message: String,
        chrome: ToastChromeStyle = .adaptive
    ) -> (view: NSView, size: NSSize) {
        let padding = messageMetrics(for: chrome).padding
        let label = ToastWindow.messageLabel(for: message, chrome: chrome)
        label.sizeToFit()

        let textW = ceil(label.frame.width)
        let textH = ceil(label.frame.height)
        let size = NSSize(
            width: textW + padding.left + padding.right,
            height: textH + padding.top + padding.bottom
        )

        let (container, host) = ToastWindow.makeToastChrome(size: size, chrome: chrome)

        label.frame = NSRect(x: padding.left, y: padding.bottom, width: textW, height: textH)
        host.addSubview(label)
        return (container, size)
    }

    private func makeMessageContent(
        message: String,
        actionTitle: String,
        onAction: @escaping () -> Void
    ) -> (view: NSView, size: NSSize, actionButton: NSButton) {
        let padding = ToastWindow.messagePadding
        let label = ToastWindow.messageLabel(for: message)
        label.sizeToFit()

        let actionButton = NSButton(title: actionTitle, target: nil, action: nil)
        actionButton.isBordered = false
        actionButton.bezelStyle = .inline
        actionButton.font = NSFont.grabbit(.body)
        actionButton.alignment = .center
        actionButton.contentTintColor = DesignTokens.Color.textSecondary.ns
        actionButton.setButtonType(.momentaryChange)
        actionButton.action = #selector(ToastActionTrampoline.handleTap)
        let trampoline = ToastActionTrampoline { [weak self] in
            onAction()
            self?.dismissAnimated()
        }
        messageActionTrampoline = trampoline
        actionButton.target = trampoline
        actionButton.sizeToFit()

        let spacing: CGFloat = 6
        let textW = ceil(label.frame.width)
        let textH = ceil(label.frame.height)
        let actionW = ceil(actionButton.frame.width)
        let actionH = ceil(actionButton.frame.height)
        let contentW = max(textW, actionW) + padding.left + padding.right
        let contentH = textH + actionH + spacing + padding.top + padding.bottom
        let size = NSSize(width: contentW, height: contentH)

        let (container, host) = ToastWindow.makeToastChrome(size: size)

        label.frame = NSRect(
            x: (size.width - textW) / 2,
            y: padding.bottom + actionH + spacing,
            width: textW,
            height: textH
        )
        actionButton.frame = NSRect(
            x: (size.width - actionW) / 2,
            y: padding.bottom,
            width: actionW,
            height: actionH
        )

        host.addSubview(label)
        host.addSubview(actionButton)
        return (container, size, actionButton)
    }

    private func buildContentView(image: NSImage, size: NSSize) -> NSView {
        let padding = DesignTokens.Spacing.md
        let (container, host) = ToastWindow.makeToastChrome(size: size)

        // Thumbnail
        let thumbW = size.width - padding * 2
        let thumbH = size.height - padding * 2
        let thumbFrame = NSRect(x: padding, y: padding, width: thumbW, height: thumbH)
        let imageView = NSImageView(frame: thumbFrame)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = DesignTokens.Radius.sm
        imageView.layer?.masksToBounds = true

        host.addSubview(imageView)
        return container
    }

    private func positionBottomRight(contentSize: NSSize) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 20
        let visibleRect = screen.visibleFrame
        let origin = NSPoint(
            x: visibleRect.maxX - contentSize.width - margin,
            y: visibleRect.minY + margin
        )
        setFrame(NSRect(origin: origin, size: contentSize), display: false)
    }

    private func positionForAnchor(contentSize: NSSize) {
        setFrame(NSRect(origin: anchoredOrigin(for: contentSize), size: contentSize), display: false)
    }

    private func anchoredOrigin(for contentSize: NSSize) -> NSPoint {
        if let anchor = anchorScreenRect {
            let margin: CGFloat = anchorPlacement == .above ? 6 : 8
            let x = anchor.midX - contentSize.width / 2
            let y: CGFloat
            switch anchorPlacement {
            case .below:
                y = anchor.minY - contentSize.height - margin
            case .above:
                y = anchor.maxY + margin
            }
            return NSPoint(x: x, y: y)
        }
        return screenBottomCenterOrigin(for: contentSize)
    }

    private func screenBottomCenterOrigin(for contentSize: NSSize) -> NSPoint {
        let margin: CGFloat = 16
        let visibleRect = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(
            x: visibleRect.midX - contentSize.width / 2,
            y: visibleRect.minY + margin
        )
    }

    // MARK: - Animation

    private func presentAnimated(hostWindow: NSWindow? = nil, autoDismiss: Bool = true) {
        let targetFrame = frame
        alphaValue = 0
        let slidesFromAbove = anchorScreenRect != nil && anchorPlacement == .below
        let offscreen = targetFrame.offsetBy(dx: 0, dy: slidesFromAbove ? 12 : -12)
        setFrame(offscreen, display: false)
        orderFrontRegardless()
        if let hostWindow {
            order(.above, relativeTo: hostWindow.windowNumber)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(targetFrame, display: true)
        }

        if autoDismiss {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissAnimated()
            }
        }
    }

    private func dismissAnimated() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.close()
                if ToastWindow.current === self {
                    ToastWindow.current = nil
                }
            }
        })
    }

    private func cancelAndClose() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        close()
        ToastWindow.current = nil
    }

    // MARK: - Interaction

    override func mouseUp(with event: NSEvent) {
        guard let contentView else { return }
        let locationInContent = contentView.convert(event.locationInWindow, from: nil)
        if let messageActionButton, messageActionButton.frame.contains(locationInContent) {
            return
        }
        handleTap()
    }

    @objc private func handleTap() {
        onTap()
        dismissAnimated()
    }
}

private final class ToastActionTrampoline: NSObject {
    let onTap: () -> Void

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init()
    }

    @objc func handleTap() {
        onTap()
    }
}
