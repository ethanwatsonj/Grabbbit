//
//  CaptureLibraryWindow.swift
//  Grabbit
//

import SwiftUI
import Combine
import QuartzCore
import UniformTypeIdentifiers
@preconcurrency import AppKit

enum AppDockPresentation {
    static var isLibraryPresented: Bool {
        guard let window = CaptureLibraryWindow.current else { return false }
        return window.isVisible || window.isMiniaturized
    }

    static func presentLibraryWindow() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    static func hideFromDockIfNeeded() {
        guard isLibraryPresented == false else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

final class CaptureLibraryWindow: NSWindow, NSWindowDelegate {
    static var current: CaptureLibraryWindow?

    private nonisolated(unsafe) var historyObserver: NSObjectProtocol?
    fileprivate let sessionState = CaptureLibrarySessionState()
    private var hostingView: CaptureLibraryHostingView?
    /// Coalesce titlebar paint so we never mutate chrome mid-layout (AppKit layout-loop crash).
    private var titlebarFillPending = false
    /// System spacing between close → miniaturize / close → zoom, captured once
    /// so repositioning during drag never depends on mid-reset frames.
    private var trafficLightSpacingX: (miniaturize: CGFloat, zoom: CGFloat)?
    /// Shared field editor for `StableFlippedTextField` — default NSTextView
    /// allows window moves while selecting text under `fullSizeContentView`.
    private lazy var stableFieldEditor: StableNonMovingFieldEditor = {
        StableNonMovingFieldEditor(frame: .zero)
    }()

    static func show(selecting id: UUID? = nil) {
        DispatchQueue.main.async {
            if current == nil {
                current = CaptureLibraryWindow()
            }
            if let id {
                current?.sessionState.pendingSelectionID = id
            }
            AppDockPresentation.presentLibraryWindow()
            CaptureHistory.shared.scheduleReconcileWithDisk()
            current?.reloadContent()
            current?.center()
            current?.makeKeyAndOrderFront(nil)
            // Titlebar materials finish installing after the first layout pass.
            // Defer layoutSubtreeIfNeeded — sync force overlaps AppKit's own layout
            // from makeKeyAndOrderFront and triggers layout-recursion warnings.
            current?.scheduleTitlebarFill()
            DispatchQueue.main.async {
                current?.contentView?.needsLayout = true
                current?.contentView?.layoutSubtreeIfNeeded()
            }
            NSApp.activate(ignoringOtherApps: true)

            if !AppSettings.hasSeenLibraryIntro {
                current?.sessionState.markIntroSeenOnDismiss = true
                current?.sessionState.showsIntro = true
            }
        }
    }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Grabbit"
        titleVisibility = .hidden
        // Compact chrome: traffic lights only — preview header hugs the window top.
        toolbar = nil
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        // Drag is scoped to empty title chrome via CaptureLibraryTitleChromeDragView —
        // never move the window from header controls or the preview body.
        // Nuclear: window stays non-movable unless the strip explicitly opts in
        // for performDrag (Cursor/Electron app-region policy in AppKit form).
        isMovableByWindowBackground = false
        isMovable = false
        backgroundColor = DesignTokens.Color.background.ns
        minSize = NSSize(width: 640, height: 420)
        isReleasedWhenClosed = false
        delegate = self

        historyObserver = NotificationCenter.default.addObserver(
            forName: .captureHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadContent()
            }
        }

        reloadContent()
    }

    deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
    }

    func reloadContent() {
        // Show whatever we already know immediately. Folder ingest (including video
        // frame extracts) runs in the background via scheduleReconcileWithDisk so
        // opening Show All never freezes the UI on a large save folder.
        let view = CaptureLibraryView(
            entries: CaptureHistory.shared.entriesInSaveRoot,
            sessionState: sessionState
        )
        if let hostingView {
            // Update in place so sidebar scroll position and @State selection survive.
            hostingView.rootView = view
            layoutLibraryContent(hostingView)
            scheduleTitlebarFill()
            return
        }
        let hostingView = CaptureLibraryHostingView(rootView: view)
        // Avoid List intrinsic height driving window/sidebar sizing.
        hostingView.sizingOptions = []
        self.hostingView = hostingView
        layoutLibraryContent(hostingView)
        scheduleTitlebarFill()
    }

    private func layoutLibraryContent(_ hostingView: NSView) {
        if let container = contentView as? CaptureLibraryContentContainer {
            container.setHostingView(hostingView)
            return
        }

        let container = CaptureLibraryContentContainer()
        container.wantsLayer = true
        container.layer?.backgroundColor = DesignTokens.Color.background.ns.cgColor
        container.setHostingView(hostingView)
        contentView = container
    }

    /// Defer chrome mutations until after the current layout pass settles.
    fileprivate func scheduleTitlebarFill() {
        guard !titlebarFillPending else { return }
        titlebarFillPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.titlebarFillPending = false
            self.applyTitlebarFill()
        }
    }

    /// Kill titlebar vibrancy so it doesn’t flash white; keep chrome clear so
    /// SwiftUI headers can draw through and hug the top (Cursor-style).
    /// Must not run during AppKit layout — hiding titlebar materials invalidates layout.
    private func applyTitlebarFill() {
        let fill = DesignTokens.Color.background.ns
        backgroundColor = fill
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = fill.cgColor

        guard let closeButton = standardWindowButton(.closeButton),
              let titlebar = closeButton.superview else { return }

        // Titlebar view + container often use NSVisualEffectView materials that
        // stay system-white unless removed. Keep layers clear so content shows.
        var roots: [NSView] = [titlebar]
        if let container = titlebar.superview {
            roots.append(container)
        }
        for root in roots {
            hideVisualEffects(in: root, depth: 0)
            root.wantsLayer = true
            root.layer?.backgroundColor = NSColor.clear.cgColor
        }

        layoutTrafficLights()
    }

    /// Equal top + left inset for the traffic-light cluster, chosen so the
    /// lights share a vertical center with the header row (which keeps the
    /// uniform `windowEdgeInset` content margin on all four sides).
    /// Safe to call during layout — only adjusts button frames.
    private func layoutTrafficLights() {
        guard let close = standardWindowButton(.closeButton),
              let miniaturize = standardWindowButton(.miniaturizeButton),
              let zoom = standardWindowButton(.zoomButton),
              let container = close.superview else { return }

        let height = close.frame.height
        // Header row: `windowEdgeInset` top padding + `headerControlHeight` controls.
        let headerCenterFromTop = CaptureLibraryChrome.windowEdgeInset
            + CaptureLibraryChrome.headerControlHeight / 2
        // Same value for top and left so the cluster isn’t skewed in the corner.
        let lightInset = max(0, headerCenterFromTop - height / 2)
        let y = container.isFlipped
            ? lightInset
            : container.bounds.height - height - lightInset

        // Capture system spacing once (before we move the cluster). AppKit resets
        // button frames to default insets while dragging — re-reading offsets then
        // is fine, but caching avoids any mid-reset oddities.
        let spacing = trafficLightSpacingX ?? {
            let captured = (
                miniaturize: miniaturize.frame.minX - close.frame.minX,
                zoom: zoom.frame.minX - close.frame.minX
            )
            trafficLightSpacingX = captured
            return captured
        }()

        let closeOrigin = NSPoint(x: lightInset, y: y)
        let miniOrigin = NSPoint(x: lightInset + spacing.miniaturize, y: y)
        let zoomOrigin = NSPoint(x: lightInset + spacing.zoom, y: y)

        // Skip no-op writes so we don’t dirty AppKit mid-drag.
        if !close.frame.origin.equalTo(closeOrigin) {
            close.setFrameOrigin(closeOrigin)
        }
        if !miniaturize.frame.origin.equalTo(miniOrigin) {
            miniaturize.setFrameOrigin(miniOrigin)
        }
        if !zoom.frame.origin.equalTo(zoomOrigin) {
            zoom.setFrameOrigin(zoomOrigin)
        }
    }

    /// Re-pin traffic lights after AppKit’s own titlebar layout (which resets them
    /// to system edge insets). Frame-only — never hide materials here.
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTrafficLights()
    }

    private func hideVisualEffects(in view: NSView, depth: Int) {
        guard depth < 5 else { return }
        if let effect = view as? NSVisualEffectView {
            // Safe here because applyTitlebarFill is always deferred off the layout pass.
            if !effect.isHidden || effect.alphaValue != 0 {
                effect.isHidden = true
                effect.alphaValue = 0
            }
        }
        for subview in view.subviews {
            hideVisualEffects(in: subview, depth: depth + 1)
        }
    }

    static func open(_ entry: CaptureEntry) {
        switch entry.item {
        case .screenshot:
            guard let image = CaptureHistory.shared.fullImage(for: entry.id) else { return }
            AnnotationWindow.show(image: image, fileName: entry.displayName, captureID: entry.id)
        case .recording(_, let thumbnail):
            // Prefer the manifest path so rename/move can't leave annotate on a stale URL.
            let url = CaptureHistory.shared.fileURL(for: entry.id)
                ?? CaptureHistory.shared.storedFileURL(for: entry.id)
            guard let url else { return }
            VideoAnnotationWindow.show(url: url, thumbnail: thumbnail)
        }
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            AppDockPresentation.hideFromDockIfNeeded()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        scheduleTitlebarFill()
    }

    func windowDidResize(_ notification: Notification) {
        contentView?.needsLayout = true
        layoutTrafficLights()
        scheduleTitlebarFill()
    }

    func windowDidMove(_ notification: Notification) {
        // AppKit re-lays out titlebar buttons to default insets while dragging.
        layoutTrafficLights()
    }

    /// Supply a field editor that opts out of window dragging. Without this,
    /// click-drag to select text in the filename / soft-control fields moves
    /// the library window (default NSTextView.mouseDownCanMoveWindow == true).
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        if client is StableFlippedTextField {
            return stableFieldEditor
        }
        return nil
    }

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        if object is StableFlippedTextField {
            return stableFieldEditor
        }
        return super.fieldEditor(createFlag, for: object)
    }

    /// Last line of defense: never start a window drag from a title-band text
    /// field / field editor (strip mis-claim or AppKit titlebar chrome).
    /// Window defaults to `isMovable = false`; only the empty-chrome strip
    /// flips that on for `performDrag`.
    override func performDrag(with event: NSEvent) {
        if Self.shouldBlockWindowDrag(for: event, in: self) {
            return
        }
        guard isMovable else { return }
        super.performDrag(with: event)
    }

    fileprivate static func shouldBlockWindowDrag(for event: NSEvent, in window: NSWindow) -> Bool {
        // Geometry only — hosting hitTest often claims `self`, so hit-walking
        // never sees SoftControl chrome under the cursor. Block text-field
        // frames and full `.libraryTitlebarInteractive()` marker frames
        // (icon / padding / chevron outside the hugging NSTextField).
        let location = event.locationInWindow
        if textInputFrameContains(location, in: window) { return true }
        if CaptureLibraryTitlebarInteractiveAnchorView.containsWindowPoint(location, window: window) {
            return true
        }
        return false
    }

    fileprivate static func textInputFrameContains(_ locationInWindow: NSPoint, in window: NSWindow) -> Bool {
        guard let root = window.contentView else { return false }
        var found = false
        func walk(_ view: NSView) {
            if found { return }
            if view is StableFlippedTextField || view is StableNonMovingFieldEditor {
                let rect = view.convert(view.bounds, to: nil)
                // Inflate slightly for soft-control padding around a hugging field.
                if rect.insetBy(dx: -12, dy: -8).contains(locationInWindow) {
                    found = true
                    return
                }
            }
            if let field = view as? NSTextField, let editor = field.currentEditor() as? NSView {
                let rect = editor.convert(editor.bounds, to: nil)
                if rect.insetBy(dx: -4, dy: -4).contains(locationInWindow) {
                    found = true
                    return
                }
            }
            for sub in view.subviews {
                walk(sub)
            }
        }
        walk(root)
        return found
    }
}

/// Hosts SwiftUI edge-to-edge under a transparent titlebar (`fullSizeContentView`).
/// Blocks system window-drag through the hosting tree; title-chrome dragging is
/// owned by `CaptureLibraryTitleChromeDragView`.
private final class CaptureLibraryHostingView: NSHostingView<CaptureLibraryView> {
    /// When true, `hitTest` returns the real SwiftUI/AppKit leaf (used by the
    /// drag strip to inspect content under the cursor without claiming it).
    fileprivate var isContentHitTesting = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else {
            return nil
        }
        if isContentHitTesting {
            return hit
        }
        // AppKit-backed previews (annotation toolbar / canvas, timeline) and
        // stable text fields must remain the hit target so mouseDown/actions
        // fire. Claiming `self` here swallowed ToolbarPillView tool clicks.
        if Self.shouldDeliverHitToAppKit(hit, stoppingAt: self) {
            return hit
        }
        // DEFAULT DENY: claim at the hosting root so AppKit consults
        // mouseDownCanMoveWindow (= false) for SwiftUI leaves that default
        // to canMove=true under fullSizeContentView.
        // NSHostingView still routes the event into SwiftUI from self.
        return self
    }

    /// Whether `hit` sits in an AppKit subtree that handles its own mouse input.
    private static func shouldDeliverHitToAppKit(_ hit: NSView, stoppingAt root: NSView) -> Bool {
        var current: NSView? = hit
        while let view = current, view !== root {
            if view is ScreenshotLibraryAnnotationView { return true }
            if view is RecordingTimelinePreviewView { return true }
            if view is StableFlippedTextField || view is StableNonMovingFieldEditor { return true }
            if view is CaptureLibrarySidebarResizeHandleView { return true }
            current = view.superview
        }
        return false
    }

    /// Deepest content view under `point` without the hosting claim override.
    /// `point` must be in this view's coordinate system (flipped).
    fileprivate func contentHitTest(_ point: NSPoint) -> NSView? {
        isContentHitTesting = true
        defer { isContentHitTesting = false }
        // hitTest expects superview coordinates.
        let pointInSuperview: NSPoint
        if let superview {
            pointInSuperview = convert(point, to: superview)
        } else {
            pointInSuperview = point
        }
        return hitTest(pointInSuperview)
    }
}

/// Hosts SwiftUI edge-to-edge under a transparent titlebar (`fullSizeContentView`).
private final class CaptureLibraryContentContainer: NSView {
    private var hostingView: NSView?
    private let titleChromeDragView = CaptureLibraryTitleChromeDragView()
    private var outsideClickMonitor: Any?

    override var mouseDownCanMoveWindow: Bool { false }

    func setHostingView(_ view: NSView) {
        guard hostingView !== view else {
            needsLayout = true
            return
        }
        hostingView?.removeFromSuperview()
        hostingView = view
        view.translatesAutoresizingMaskIntoConstraints = true
        // Manual frames only — autoresizing can shift/clip the first paint.
        view.autoresizingMask = []
        addSubview(view)
        // Drag strip must stay above SwiftUI so it can claim empty title chrome.
        addSubview(titleChromeDragView)
        titleChromeDragView.hostingView = view
        needsLayout = true
    }

    func layoutHostingView() {
        guard let hostingView else { return }
        let frame = bounds.integral
        guard !frame.isNull, !frame.isEmpty else { return }
        // Setting an identical frame still dirties layout on some AppKit builds.
        if !hostingView.frame.equalTo(frame) {
            hostingView.frame = frame
        }
        layoutTitleChromeDragView()
    }

    private func layoutTitleChromeDragView() {
        let height = CaptureLibraryChrome.titleChromeDragHeight
        let dragFrame = NSRect(
            x: bounds.minX,
            y: bounds.maxY - height,
            width: bounds.width,
            height: height
        ).integral
        if !titleChromeDragView.frame.equalTo(dragFrame) {
            titleChromeDragView.frame = dragFrame
        }
        titleChromeDragView.hostingView = hostingView
    }

    override func layout() {
        super.layout()
        layoutHostingView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeOutsideClickMonitor()
        guard window != nil else { return }
        // SwiftUI TextFields keep the field editor until something else becomes first
        // responder — clear editing when the click lands outside any text input.
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.resignTextFocusIfClickOutside(event)
            return event
        }
    }

    deinit {
        removeOutsideClickMonitor()
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func resignTextFocusIfClickOutside(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        guard let field = editingTextField(in: window) else { return }

        if field is RenameNSTextField {
            // Inline rename chrome is only padding + focus ring around the field —
            // don't treat large SwiftUI ancestors as "still inside" (that left the
            // blue rename ring stuck after clicking away). Cover sidebar + preview
            // soft-control padding so both keep focus on chrome clicks.
            let padX = max(
                CaptureInlineRenameChrome.horizontalPadding,
                CaptureInlineRenameChrome.previewHorizontalPadding
            ) + CaptureInlineRenameChrome.focusLineWidth + 2
            let padY = max(
                CaptureInlineRenameChrome.verticalPadding,
                CaptureInlineRenameChrome.previewVerticalPadding
            ) + CaptureInlineRenameChrome.focusLineWidth + 2
            let hit = field.convert(field.bounds.insetBy(dx: -padX, dy: -padY), to: nil)
            if hit.contains(event.locationInWindow) {
                return
            }
        } else {
            guard let editingView = activeTextEditingView(in: window) else { return }
            let pointInEditor = editingView.convert(event.locationInWindow, from: nil)
            if editingView.bounds.insetBy(dx: -2, dy: -2).contains(pointInEditor) {
                return
            }
            // Field editor lives separately from its NSTextField — keep focus when
            // the click is still on that field or its soft-control chrome.
            if click(event, isInsideSoftControlChromeOf: field) {
                return
            }
        }

        // Force the field editor to end so delegates commit (SwiftUI clicks often
        // never steal first responder on their own).
        window.endEditing(for: field)
        if window.firstResponder === field
            || (window.firstResponder as? NSTextView)?.delegate as AnyObject? === field {
            window.makeFirstResponder(nil)
        }
    }

    private func activeTextEditingView(in window: NSWindow) -> NSView? {
        let responder = window.firstResponder
        if let field = responder as? NSTextField, field.isEditable {
            return field
        }
        if let textView = responder as? NSTextView, textView.isEditable {
            return textView
        }
        return nil
    }

    private func editingTextField(in window: NSWindow) -> NSTextField? {
        if let field = window.firstResponder as? NSTextField, field.isEditable {
            return field
        }
        if let textView = window.firstResponder as? NSTextView,
           let field = textView.delegate as? NSTextField {
            return field
        }
        return nil
    }

    /// Soft controls wrap the AppKit field in SwiftUI padding/icon chrome.
    /// Walk ancestors so clicks on that chrome don't end editing.
    private func click(_ event: NSEvent, isInsideSoftControlChromeOf field: NSTextField) -> Bool {
        var view: NSView? = field
        var depth = 0
        while let current = view, depth < 8 {
            let point = current.convert(event.locationInWindow, from: nil)
            if current.bounds.insetBy(dx: -2, dy: -2).contains(point) {
                // Prefer retaining focus while the click is still within a
                // reasonably small ancestor (the soft-control cluster).
                if current.bounds.width <= field.bounds.width + 120,
                   current.bounds.height <= field.bounds.height + 24 {
                    return true
                }
                if current === field {
                    return true
                }
            }
            view = current.superview
            depth += 1
        }
        return false
    }
}

// MARK: - Title chrome window drag

/// Transparent overlay on the library title band. Claims **empty** chrome only
/// for `performDrag`. Over interactive header controls, `hitTest` returns `nil`
/// so those views stay out of the drag path (no redispatch).
private final class CaptureLibraryTitleChromeDragView: NSView {
    weak var hostingView: NSView?

    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit passes `point` in superview coordinates. The strip sits at the
        // top of the container (frame.origin.y ≠ 0), so use `frame`, not `bounds`.
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        // Controls must never be the drag path — pass through so hosting/SwiftUI
        // receive mouseDown/dragged/up for the full press sequence.
        if hasInteractiveContent(at: local) {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // HitTest can miss soft-control chrome (coord skew) while the geometry
        // gate still correctly blocks performDrag — never swallow that click.
        if CaptureLibraryWindow.shouldBlockWindowDrag(for: event, in: window) {
            forwardMouseDownToContent(event)
            return
        }
        // Window defaults to isMovable=false; briefly allow move for this
        // empty-chrome drag only (performDrag tracks until mouse up).
        let wasMovable = window.isMovable
        window.isMovable = true
        defer { window.isMovable = wasMovable }
        window.performDrag(with: event)
    }

    /// Deliver a mis-claimed press to the deepest content leaf under the cursor.
    private func forwardMouseDownToContent(_ event: NSEvent) {
        guard let hostingView else { return }
        let pointInHosting = hostingView.convert(event.locationInWindow, from: nil)
        let target: NSView?
        if let libraryHosting = hostingView as? CaptureLibraryHostingView {
            target = libraryHosting.contentHitTest(pointInHosting)
        } else {
            target = hostingView.hitTest(
                hostingView.superview.map { hostingView.convert(pointInHosting, to: $0) }
                    ?? pointInHosting
            )
        }
        // Prefer the real AppKit field / editor when present.
        if let target {
            var current: NSView? = target
            while let view = current, view !== hostingView {
                if view is StableFlippedTextField || view is StableNonMovingFieldEditor {
                    view.mouseDown(with: event)
                    return
                }
                current = view.superview
            }
            if target !== hostingView, target !== self {
                target.mouseDown(with: event)
            }
        }
    }

    /// True when the point lands on a header control (or resize handle) — those
    /// must never start a window drag / must receive the click.
    private func hasInteractiveContent(at pointInStrip: NSPoint) -> Bool {
        guard let hostingView else { return false }
        // Prefer window space for text/marker tests — same policy as
        // `shouldBlockWindowDrag` (avoids flipped/hosting mismatches that only
        // exclude the bottom edge of controls and swallow the first click).
        let pointInWindow = convert(pointInStrip, to: nil)
        if let window,
           CaptureLibraryWindow.textInputFrameContains(pointInWindow, in: window)
        {
            return true
        }
        if let window,
           CaptureLibraryTitlebarInteractiveAnchorView.containsWindowPoint(
            pointInWindow,
            window: window
           )
        {
            return true
        }

        // Convert strip-local → hosting-local for deep content hit-testing.
        let pointInHosting = convert(pointInStrip, to: hostingView)

        let hit: NSView?
        if let libraryHosting = hostingView as? CaptureLibraryHostingView {
            hit = libraryHosting.contentHitTest(pointInHosting)
        } else {
            hit = hostingView.hitTest(
                hostingView.superview.map { hostingView.convert(pointInHosting, to: $0) }
                    ?? pointInHosting
            )
        }
        guard let hit else {
            // No content leaf under the cursor — empty chrome, allow strip drag.
            return false
        }
        if isKnownInteractiveControl(hit) {
            return true
        }
        if isTitleBandBackground(hit) {
            return false
        }
        return true
    }

    private func isKnownInteractiveControl(_ hit: NSView) -> Bool {
        var current: NSView? = hit
        while let view = current {
            if view is CaptureLibraryTitlebarInteractiveMarking { return true }
            if view is NSControl || view is NSTextView { return true }
            if view is CaptureLibrarySidebarResizeHandleView { return true }
            if String(describing: type(of: view)).contains("AnchorView") { return true }
            if view === hostingView { break }
            current = view.superview
        }
        return false
    }

    /// Large non-control surfaces that may sit under the title strip (sidebar
    /// scroll document, preview annotation canvas). These are empty chrome.
    /// Controls are excluded earlier via markers / text frames / known controls.
    private func isTitleBandBackground(_ hit: NSView) -> Bool {
        // Hosting root is what contentHitTest returns for empty SwiftUI areas.
        if hit === hostingView { return true }
        if hit is ScreenshotLibraryAnnotationView { return true }
        let name = String(describing: type(of: hit))
        let looksLikeScrollOrCanvasHost =
            name.contains("DocumentView")
            || name.contains("HostingScrollView")
            || name.contains("HostingClipView")
            || name.contains("_NSGraphicsView")
        if looksLikeScrollOrCanvasHost { return true }
        // SwiftUI wraps Buttons in PlatformGroupContainer — only treat as empty
        // chrome when the leaf spans most of the title band width.
        let looksLikeContainer =
            name.contains("PlatformGroupContainer")
            || name.contains("PlatformContainer")
        let isFullBand: Bool = {
            guard let hostingView else { return false }
            return hit.bounds.width >= hostingView.bounds.width * 0.85
        }()
        if looksLikeContainer { return isFullBand }
        return isFullBand
    }
}

/// Marker for title-chrome controls that must receive mouse events and must not
/// participate in window dragging.
private protocol CaptureLibraryTitlebarInteractiveMarking: AnyObject {}

/// Layout-neutral frame marker (SwiftUI `background`). Does not wrap controls in
/// a nested `NSHostingView` — that broke HStack baseline / padding.
///
/// Anchors register themselves so the drag strip / hosting hit-test can cover the
/// full control frame even when SwiftUI nests representables deeply.
private final class CaptureLibraryTitlebarInteractiveAnchorView:
    NSView, CaptureLibraryTitlebarInteractiveMarking
{
    private static let registry = NSHashTable<CaptureLibraryTitlebarInteractiveAnchorView>.weakObjects()

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Never steal hits from the control drawn in front of this background.
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Self.registry.add(self)
        } else {
            Self.registry.remove(self)
        }
    }

    /// Whether `point` (in `root`'s coordinates) falls inside any live anchor.
    static func contains(_ point: NSPoint, in root: NSView) -> Bool {
        guard let rootWindow = root.window else { return false }
        for anchor in registry.allObjects {
            guard anchor.window === rootWindow, !anchor.bounds.isEmpty else { continue }
            let frame = anchor.convert(anchor.bounds, to: root)
            if !frame.isEmpty, frame.contains(point) {
                return true
            }
        }
        return false
    }

    /// Window-space marker test — used by `performDrag` / strip mouseDown gate.
    static func containsWindowPoint(_ locationInWindow: NSPoint, window: NSWindow) -> Bool {
        for anchor in registry.allObjects {
            guard anchor.window === window, !anchor.bounds.isEmpty else { continue }
            let frame = anchor.convert(anchor.bounds, to: nil)
            if !frame.isEmpty, frame.insetBy(dx: -2, dy: -2).contains(locationInWindow) {
                return true
            }
        }
        return false
    }
}

private struct CaptureLibraryTitlebarInteractiveAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> CaptureLibraryTitlebarInteractiveAnchorView {
        CaptureLibraryTitlebarInteractiveAnchorView()
    }

    func updateNSView(_ nsView: CaptureLibraryTitlebarInteractiveAnchorView, context: Context) {}

    /// Background proposes the control's size — take it so markers cover the full
    /// TagKindDropdown / filename / Auto Organize frames (not zero-size stubs).
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: CaptureLibraryTitlebarInteractiveAnchorView,
        context: Context
    ) -> CGSize? {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed >= 0 {
            width = proposed
        } else {
            width = 1
        }
        let height: CGFloat
        if let proposed = proposal.height, proposed.isFinite, proposed >= 0 {
            height = max(proposed, 1)
        } else {
            height = CaptureLibraryChrome.headerControlHeight
        }
        let size = CGSize(width: max(width, 1), height: height)
        if nsView.frame.size != size {
            nsView.setFrameSize(size)
        }
        return size
    }
}

private extension View {
    /// Mark this header control for the title-chrome drag strip / hosting hit-test
    /// without changing layout (no nested hosting wrapper).
    func libraryTitlebarInteractive() -> some View {
        background {
            CaptureLibraryTitlebarInteractiveAnchor()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Row suggestion state

/// One in-flight Auto Organize job; `token` ignores completions from cancelled predecessors.
private struct SuggestionInFlight {
    let token: UUID
    let task: Task<Void, Never>
}

private struct CaptureRowSuggestionState {
    var isLoading = false
    var suggestion: RenameSuggestion?
    /// True after Auto Organize finished with nothing usable — show empty state once.
    var didCompleteWithoutSuggestion = false
    /// User-edited rename; `nil` falls back to `suggestion.suggestedName`.
    var selectedName: String?
    var selectedProject: String?
    var acceptedSnapshot: CaptureLocationSnapshot?
    var wroteMapping = false
    var windowInfo: WindowSignature?
    /// Accept handoff — slide-up toward these values before the suggestion is cleared.
    var acceptHandoffName: String?
    var acceptHandoffProject: String?
    var slidesNameOnAccept = false
    var slidesProjectOnAccept = false
    /// True while accept motion is running (even if neither field needs a slide).
    var isAccepting = false

    var isAcceptHandoff: Bool {
        isAccepting
    }

    var effectiveName: String? {
        if let selectedName {
            let trimmed = selectedName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return suggestion?.suggestedName
    }

    /// `nil` = fall back to suggestion; `""` = explicitly cleared to None; otherwise the pick.
    var effectiveProject: String? {
        if let selectedProject {
            let trimmed = selectedProject.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return suggestion?.suggestedProject
    }

    var showsNameEditor: Bool {
        guard suggestion != nil else { return false }
        return effectiveName != nil
    }

    var showsProjectPicker: Bool {
        guard suggestion != nil else { return false }
        // Keep the control after clear (`""`) so it can show "None".
        if selectedProject != nil { return true }
        return suggestion?.hasProject == true
    }
}

@MainActor
fileprivate final class CaptureLibrarySessionState: ObservableObject {
    @Published var rowStates: [UUID: CaptureRowSuggestionState] = [:]
    /// Select this capture once the library view appears / reloads.
    @Published var pendingSelectionID: UUID?
    /// In-window intro modal (first open + DEBUG Settings launcher).
    @Published var showsIntro = false
    var markIntroSeenOnDismiss = true
}

// MARK: - SwiftUI

private enum CaptureLibraryGroupBy: String, CaseIterable, Identifiable {
    case none
    case project

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .none: return "None"
        case .project: return "Project"
        }
    }

    var menuSymbol: String {
        switch self {
        case .none: return "list.bullet"
        case .project: return "folder"
        }
    }
}

/// Sidebar media-type filter. Empty selection means show all captures.
private enum CaptureLibraryMediaFilter: String, CaseIterable, Identifiable {
    case image
    case video

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        }
    }

    var menuSymbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "video"
        }
    }

    func matches(_ entry: CaptureEntry) -> Bool {
        switch self {
        case .image: return !entry.isRecording
        case .video: return entry.isRecording
        }
    }

    static func decode(_ raw: String) -> Set<CaptureLibraryMediaFilter> {
        Set(
            raw.split(separator: ",")
                .compactMap { CaptureLibraryMediaFilter(rawValue: String($0)) }
        )
    }

    static func encode(_ filters: Set<CaptureLibraryMediaFilter>) -> String {
        filters.map(\.rawValue).sorted().joined(separator: ",")
    }
}

private struct CaptureLibraryNamedGroup: Identifiable {
    let name: String
    let entries: [CaptureEntry]

    var id: String { name }
}

/// Sidebar list metrics so folder/file names share one text column.
private enum CaptureLibrarySidebarMetrics {
    static let columnWidth: CGFloat = 240
    static let minColumnWidth: CGFloat = 180
    static let maxColumnWidth: CGFloat = 420
    /// Hit target for the resize gutter; visual rule stays centered inside.
    static let resizeHandleWidth: CGFloat = 7
    static let resizeRuleWidth: CGFloat = 1
    static let resizeRuleHoverWidth: CGFloat = 3
    /// Leading inset for Group by + list; trailing list gutter holds the scroller.
    static let contentInset: CGFloat = CaptureLibraryChrome.windowEdgeInset
    /// Trailing strip between row content and the vertical divider (scroller lives here).
    static let scrollbarGutter: CGFloat = contentInset
    /// Overlay knob width — sits in `scrollbarGutter`, not over row labels.
    static let scrollbarWidth: CGFloat = 5
    /// Inset inside the selection pill so labels aren’t flush to its edges.
    static let rowContentInset: CGFloat = DesignTokens.Spacing.sm
    /// Row-to-row gap in the Capture Library sidebar list.
    static let rowSpacing: CGFloat = 2
    /// Vertical inset inside each row’s hover/selection pill.
    /// Half the former 4→2 gap reduction lands here on each side (4 → 5).
    static let rowVerticalPadding: CGFloat = DesignTokens.Spacing.xs + 1
    static let disclosureWidth: CGFloat = 10
    static let groupIconSpacing: CGFloat = 6
    /// Nested capture names align with group header names (disclosure sits left of names).
    static var nestedRowLeading: CGFloat {
        disclosureWidth + groupIconSpacing
    }
}

/// Narrow overlay scroller for the Capture Library sidebar gutter.
private final class CaptureLibrarySidebarScroller: NSScroller {
    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        CaptureLibrarySidebarMetrics.scrollbarWidth
    }

    override func draw(_ dirtyRect: NSRect) {
        // Skip default AppKit chrome; draw only the soft token-colored knob.
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Transparent track — matches sidebar surface.
    }

    override func drawKnob() {
        let thickness = Self.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle)
        var knobRect = rect(for: .knob)
        if knobRect.width > thickness {
            knobRect.origin.x += (knobRect.width - thickness) / 2
            knobRect.size.width = thickness
        }
        guard knobRect.width > 0, knobRect.height > 0 else { return }

        let radius = thickness / 2
        let path = NSBezierPath(roundedRect: knobRect, xRadius: radius, yRadius: radius)
        DesignTokens.Color.scrollbarThumb.ns.setFill()
        path.fill()
    }
}

/// Zeros `NSScrollView` content insets and installs a narrow gutter scroller.
/// Content clears the trailing gutter via SwiftUI padding (not `contentInsets`, which
/// would also inset the scroller away from the divider).
private struct CaptureLibraryScrollInsetZeroer: NSViewRepresentable {
    func makeNSView(context: Context) -> CaptureLibraryScrollInsetZeroerView {
        CaptureLibraryScrollInsetZeroerView()
    }

    func updateNSView(_ nsView: CaptureLibraryScrollInsetZeroerView, context: Context) {
        // Defer — updateNSView can run during an active layout pass.
        DispatchQueue.main.async { [weak nsView] in
            nsView?.configureScrollChrome()
        }
    }
}

private final class CaptureLibraryScrollInsetZeroerView: NSView {
    override var isHidden: Bool {
        get { true }
        set {}
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Configure off the layout pass — mutating NSScrollView insets/scroller
        // from layout() re-enters AppKit layout and can trigger recursion warnings.
        DispatchQueue.main.async { [weak self] in self?.configureScrollChrome() }
    }

    func configureScrollChrome() {
        var current: NSView? = superview
        while let view = current {
            if let scroll = view as? NSScrollView ?? view.enclosingScrollView {
                if scroll.automaticallyAdjustsContentInsets {
                    scroll.automaticallyAdjustsContentInsets = false
                }
                let zero = NSEdgeInsets()
                if scroll.contentInsets.left != 0 || scroll.contentInsets.right != 0
                    || scroll.contentInsets.top != 0 || scroll.contentInsets.bottom != 0 {
                    scroll.contentInsets = zero
                }
                if scroll.contentView.contentInsets.left != 0
                    || scroll.contentView.contentInsets.right != 0 {
                    scroll.contentView.contentInsets = zero
                }
                if scroll.scrollerInsets.left != 0 || scroll.scrollerInsets.right != 0
                    || scroll.scrollerInsets.top != 0 || scroll.scrollerInsets.bottom != 0 {
                    scroll.scrollerInsets = zero
                }
                scroll.scrollerStyle = .overlay
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = true
                if !(scroll.verticalScroller is CaptureLibrarySidebarScroller) {
                    let scroller = CaptureLibrarySidebarScroller()
                    scroller.controlSize = .mini
                    scroll.verticalScroller = scroller
                } else {
                    scroll.verticalScroller?.controlSize = .mini
                }
                return
            }
            current = view.superview
        }
    }
}

/// Soft rule between sidebar and detail — matches surface, not system separator.
private enum CaptureLibraryChrome {
    static var divider: Color {
        DesignTokens.Color.borderOnPanel.swiftUI
    }

    /// Uniform content margin at every window corner (top / leading / trailing / bottom).
    /// Traffic lights are vertically centered to the header row and do not shrink this.
    static let windowEdgeInset = DesignTokens.Spacing.md
    /// Soft-control row height in the preview header (`.grabbit` Auto Organize ≈ 25pt).
    static let headerControlHeight: CGFloat = 25
    /// Top padding for the title + Project/Auto Organize row — same as other corners.
    static let topChromeInset = windowEdgeInset
    /// Clears the header / traffic-light band so sidebar chrome sits below it.
    static let belowTrafficLightsTop: CGFloat =
        windowEdgeInset + headerControlHeight + DesignTokens.Spacing.sm
    /// AppKit strip that owns empty title-chrome window dragging (matches header band).
    static let titleChromeDragHeight: CGFloat =
        topChromeInset + headerControlHeight + DesignTokens.Spacing.md
}

/// Transparent hit target that resizes the sidebar from absolute window mouse X.
/// Width = startWidth + (mouseX − startMouseX), clamped — so the bar sticks to the
/// cursor until min/max, then snaps back when the cursor re-enters range.
private struct CaptureLibrarySidebarResizeHandle: NSViewRepresentable {
    var width: CGFloat
    var minWidth: CGFloat
    var maxWidth: CGFloat
    var onHoverChange: (Bool) -> Void
    var onDragBegan: () -> Void
    var onWidthChange: (CGFloat) -> Void
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> CaptureLibrarySidebarResizeHandleView {
        let view = CaptureLibrarySidebarResizeHandleView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: CaptureLibrarySidebarResizeHandleView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: CaptureLibrarySidebarResizeHandleView) {
        view.currentWidth = width
        view.minWidth = minWidth
        view.maxWidth = maxWidth
        view.onHoverChange = onHoverChange
        view.onDragBegan = onDragBegan
        view.onWidthChange = onWidthChange
        view.onDragEnded = onDragEnded
    }
}

private final class CaptureLibrarySidebarResizeHandleView: NSView {
    var currentWidth: CGFloat = CaptureLibrarySidebarMetrics.columnWidth
    var minWidth: CGFloat = CaptureLibrarySidebarMetrics.minColumnWidth
    var maxWidth: CGFloat = CaptureLibrarySidebarMetrics.maxColumnWidth
    var onHoverChange: ((Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStartWidth: CGFloat?
    private var dragStartMouseX: CGFloat?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
        guard dragStartWidth == nil else { return }
        NSCursor.arrow.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStartWidth = currentWidth
        dragStartMouseX = event.locationInWindow.x
        onDragBegan?()
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        applyWidth(for: event)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseUp(with event: NSEvent) {
        applyWidth(for: event)
        dragStartWidth = nil
        dragStartMouseX = nil
        onDragEnded?()
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local) {
            onHoverChange?(true)
            NSCursor.resizeLeftRight.set()
        } else {
            onHoverChange?(false)
            NSCursor.arrow.set()
        }
    }

    private func applyWidth(for event: NSEvent) {
        guard let startWidth = dragStartWidth, let startX = dragStartMouseX else { return }
        // Window-space delta is independent of this view moving as the sidebar grows.
        let proposed = startWidth + (event.locationInWindow.x - startX)
        let clamped = min(max(proposed, minWidth), maxWidth)
        onWidthChange?(clamped)
    }
}

private struct CaptureLibraryView: View {
    let entries: [CaptureEntry]
    @ObservedObject var sessionState: CaptureLibrarySessionState

    @AppStorage("captureLibraryGroupBy") private var groupByRaw = CaptureLibraryGroupBy.none.rawValue
    /// Comma-separated `CaptureLibraryMediaFilter` raw values; empty = show all.
    @AppStorage("captureLibraryMediaFilter") private var mediaFilterRaw = ""
    @AppStorage("captureLibrarySidebarWidth") private var persistedSidebarWidth =
        Double(CaptureLibrarySidebarMetrics.columnWidth)
    @State private var sidebarWidth = CaptureLibrarySidebarMetrics.columnWidth
    @State private var selection = Set<UUID>()
    /// Last plain (or cmd) click — shift-click selects the contiguous range from here.
    @State private var selectionAnchor: UUID?
    @State private var visibleCount = CaptureLibraryView.initialPageSize
    @State private var renameTarget: CaptureEntry?
    @State private var renameDraft = ""
    /// Only one inline field may mount — sidebar and preview both used to, and
    /// the second `makeFirstResponder` immediately ended editing on the first.
    @State private var renameSite: CaptureRenameSite = .sidebar
    /// Inline rename for a project group header (Group by → Project).
    @State private var projectRenameTarget: String?
    @State private var projectRenameDraft = ""
    @State private var createProjectTarget: UUID?
    @State private var createProjectDraft = ""
    /// Groups start collapsed; membership means the section is expanded.
    @State private var expandedGroupIDs = Set<String>()
    /// Manual double-click detection so rename does not use TapGesture(count: 2),
    /// which can swallow the first click and leave selection unchanged.
    @State private var lastRowClick: (id: UUID, date: Date)?

    @State private var hoveredCaptureID: UUID?
    @State private var isSidebarResizing = false
    @State private var isSidebarResizeHandleHovered = false
    /// Project group currently targeted by a capture drag.
    @State private var dropTargetGroupID: String?
    /// FIFO of captures waiting for an Auto Organize slot (cap: `suggestionConcurrencyLimit`).
    @State private var suggestionQueue: [UUID] = []
    /// Per-capture in-flight classification tasks (token invalidates stale completions).
    @State private var suggestionInFlight: [UUID: SuggestionInFlight] = [:]
    /// In-flight accept handoff tasks (slide-up before filesystem apply).
    @State private var suggestionAcceptTasks: [UUID: Task<Void, Never>] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let initialPageSize = 40
    private static let pageSize = 40
    /// Same-process drag payload for moving captures between project groups.
    private static let captureDragTypeIdentifier = "com.grabbit.capture-library.ids"
    private static let captureDragUTType = UTType(exportedAs: captureDragTypeIdentifier)

    private var groupBy: CaptureLibraryGroupBy {
        CaptureLibraryGroupBy(rawValue: groupByRaw) ?? .none
    }

    private var mediaFilters: Set<CaptureLibraryMediaFilter> {
        CaptureLibraryMediaFilter.decode(mediaFilterRaw)
    }

    private var isMediaFilterActive: Bool {
        !mediaFilters.isEmpty
    }

    /// Captures visible under the current media-type filter.
    private var filteredEntries: [CaptureEntry] {
        guard !mediaFilters.isEmpty else { return entries }
        return entries.filter { entry in
            mediaFilters.contains { $0.matches(entry) }
        }
    }

    private var clampedSidebarWidth: CGFloat {
        min(
            max(sidebarWidth, CaptureLibrarySidebarMetrics.minColumnWidth),
            CaptureLibrarySidebarMetrics.maxColumnWidth
        )
    }

    private func setSidebarWidth(_ width: CGFloat, persist: Bool) {
        // Live drag stays continuous; only snap to whole points when persisting.
        let raw = persist ? width.rounded() : width
        let clamped = min(
            max(raw, CaptureLibrarySidebarMetrics.minColumnWidth),
            CaptureLibrarySidebarMetrics.maxColumnWidth
        )
        // Skip no-op writes at the clamp edges so layout doesn't thrash.
        if !persist, sidebarWidth == clamped { return }
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            sidebarWidth = clamped
            if persist {
                persistedSidebarWidth = Double(clamped)
            }
        }
    }

    private var visibleEntries: [CaptureEntry] {
        Array(filteredEntries.prefix(visibleCount))
    }

    private var projectGroups: [CaptureLibraryNamedGroup] {
        var grouped: [String: [CaptureEntry]] = [:]
        // Seed with on-disk destination folders so empty projects still appear.
        for name in CaptureLibraryOrganizer.existingProjectNames() {
            grouped[name] = []
        }
        for entry in filteredEntries {
            let name = CaptureLibraryProject.currentName(for: entry) ?? "None"
            grouped[name, default: []].append(entry)
        }
        return grouped.keys
            .sorted { lhs, rhs in
                if lhs == "None" { return false }
                if rhs == "None" { return true }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            .map { key in
                CaptureLibraryNamedGroup(name: key, entries: grouped[key] ?? [])
            }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarColumn
            sidebarResizeHandle
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignTokens.Color.background.swiftUI)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignTokens.Color.background.swiftUI)
        // Sidebar width must never interpolate — preview/detail follow the
        // divider immediately (geometryGroup + inherited springs were lagging).
        .animation(nil, value: sidebarWidth)
        .transaction { transaction in
            if isSidebarResizing {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        // Edge-to-edge under the transparent titlebar; headers hug the top band.
        .ignoresSafeArea()
        .libraryIntroModal(
            isPresented: Binding(
                get: { sessionState.showsIntro },
                set: { sessionState.showsIntro = $0 }
            ),
            markSeenOnDismiss: sessionState.markIntroSeenOnDismiss
        )
        .alert("New Project", isPresented: createProjectAlertBinding) {
            TextField("Project name", text: $createProjectDraft)
            Button("Cancel", role: .cancel) {
                createProjectTarget = nil
            }
            Button("Create") {
                if let targetID = createProjectTarget,
                   let name = CaptureLibraryOrganizer.sanitizedProjectName(createProjectDraft) {
                    if sessionState.rowStates[targetID]?.suggestion != nil {
                        setProject(name, for: targetID)
                    } else {
                        _ = CaptureHistory.shared.addTag(id: targetID, kind: .project, name: name)
                    }
                }
                createProjectTarget = nil
            }
        }
        .onAppear {
            setSidebarWidth(CGFloat(persistedSidebarWidth), persist: false)
            resetVisibleWindow()
            if !applyPendingSelectionIfNeeded(), selection.isEmpty, let first = filteredEntries.first {
                selection = [first.id]
                selectionAnchor = first.id
            }
        }
        .onChange(of: sessionState.pendingSelectionID) { _, _ in
            _ = applyPendingSelectionIfNeeded()
        }
        .onChange(of: groupByRaw) { _, _ in
            cancelProjectRename()
            expandedGroupIDs = []
        }
        .onChange(of: mediaFilterRaw) { _, _ in
            resetVisibleWindow()
            pruneSelectionToFilteredEntries()
        }
        .onChange(of: selection) { oldSelection, newSelection in
            // Temporary undo affordance after accept — dismiss when selection changes.
            let deselected = oldSelection.subtracting(newSelection)
            dismissOrganizedConfirmation(for: deselected)
        }
        .onChange(of: entries.map(\.id)) { oldIDs, newIDs in
            let newIDSet = Set(newIDs)
            let remaining = selection.intersection(newIDSet)
            if !remaining.isEmpty {
                if remaining.count != selection.count {
                    selection = remaining
                }
                if let anchor = selectionAnchor, !remaining.contains(anchor) {
                    selectionAnchor = remaining.first
                }
                ensureSelectionVisible()
                pruneSelectionToFilteredEntries()
                return
            }

            // Active item was removed — stay on the next row down (or up if last).
            if let anchor = oldIDs.first(where: { selection.contains($0) }),
               let oldIndex = oldIDs.firstIndex(of: anchor) {
                if oldIndex + 1 < oldIDs.count, newIDSet.contains(oldIDs[oldIndex + 1]) {
                    selection = [oldIDs[oldIndex + 1]]
                    selectionAnchor = oldIDs[oldIndex + 1]
                } else if oldIndex > 0, newIDSet.contains(oldIDs[oldIndex - 1]) {
                    selection = [oldIDs[oldIndex - 1]]
                    selectionAnchor = oldIDs[oldIndex - 1]
                } else if let first = newIDs.first {
                    selection = [first]
                    selectionAnchor = first
                } else {
                    selection = []
                    selectionAnchor = nil
                }
            } else if selection.isEmpty, let first = newIDs.first {
                selection = [first]
                selectionAnchor = first
            } else {
                selection = []
                selectionAnchor = nil
            }
            ensureSelectionVisible()
            pruneSelectionToFilteredEntries()
        }
    }

    private var sidebarResizeHandle: some View {
        let isActive = isSidebarResizeHandleHovered || isSidebarResizing
        return ZStack {
            Color.clear
            Rectangle()
                .fill(CaptureLibraryChrome.divider)
                .frame(
                    width: isActive
                        ? CaptureLibrarySidebarMetrics.resizeRuleHoverWidth
                        : CaptureLibrarySidebarMetrics.resizeRuleWidth
                )
                // Hover thicken only — never animate while the column is moving.
                .animation(
                    isSidebarResizing ? nil : .easeInOut(duration: 0.12),
                    value: isActive
                )
            // AppKit tracks window-space mouse X so the divider stays glued to the
            // cursor; SwiftUI DragGesture drifts as the handle's frame moves.
            CaptureLibrarySidebarResizeHandle(
                width: clampedSidebarWidth,
                minWidth: CaptureLibrarySidebarMetrics.minColumnWidth,
                maxWidth: CaptureLibrarySidebarMetrics.maxColumnWidth,
                onHoverChange: { isSidebarResizeHandleHovered = $0 },
                onDragBegan: {
                    var transaction = Transaction()
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        isSidebarResizing = true
                    }
                },
                onWidthChange: { setSidebarWidth($0, persist: false) },
                onDragEnded: {
                    setSidebarWidth(clampedSidebarWidth, persist: true)
                    var transaction = Transaction()
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        isSidebarResizing = false
                    }
                }
            )
        }
        .frame(width: CaptureLibrarySidebarMetrics.resizeHandleWidth)
        .frame(maxHeight: .infinity)
        .help("Drag to resize")
    }

    private var selectedEntry: CaptureEntry? {
        entries.first { selection.contains($0.id) }
    }

    private var selectedEntries: [CaptureEntry] {
        entries.filter { selection.contains($0.id) }
    }

    @ViewBuilder
    private var sidebarColumn: some View {
        Group {
            if entries.isEmpty {
                Color.clear
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                        groupByPicker
                        Spacer(minLength: 0)
                        mediaFilterButton
                    }
                        .padding(.top, CaptureLibraryChrome.belowTrafficLightsTop)
                        .padding(.bottom, DesignTokens.Spacing.xs)
                        // Match list content: trailing gutter is for the scroller only.
                        .padding(.trailing, CaptureLibrarySidebarMetrics.scrollbarGutter)

                    GeometryReader { geo in
                        captureList
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showsAutoOrganizeSidebarBanner {
                        autoOrganizeSidebarBanner
                            .padding(.trailing, CaptureLibrarySidebarMetrics.scrollbarGutter)
                            .padding(.bottom, DesignTokens.Spacing.sm)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                // Leading content inset only — scroll view reaches the divider so the
                // narrow scroller can sit in the trailing gutter, not over row labels.
                .padding(.leading, CaptureLibrarySidebarMetrics.contentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .animation(.easeInOut(duration: 0.22), value: showsAutoOrganizeSidebarBanner)
            }
        }
        .frame(width: clampedSidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Color.background.swiftUI)
    }

    /// In-flight Auto Organize (queued or classifying) + suggestions awaiting accept/dismiss.
    private var autoOrganizeInProgressCount: Int {
        sessionState.rowStates.values.filter(\.isLoading).count
    }

    private var autoOrganizeAwaitingCount: Int {
        sessionState.rowStates.values.filter { $0.suggestion != nil }.count
    }

    private var autoOrganizeActivityIDs: Set<UUID> {
        Set(
            sessionState.rowStates.compactMap { id, state in
                (state.isLoading || state.suggestion != nil) ? id : nil
            }
        )
    }

    private var showsAutoOrganizeSidebarBanner: Bool {
        autoOrganizeInProgressCount > 0 || autoOrganizeAwaitingCount > 0
    }

    private var autoOrganizeSidebarBanner: some View {
        Button(action: openAutoOrganizeActivityInBulk) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    if autoOrganizeInProgressCount > 0 {
                        Text(autoOrganizeInProgressLabel)
                            .font(.grabbit(.caption))
                            .foregroundStyle(DesignTokens.Color.sidebarTextPrimary.swiftUI)
                    }
                    if autoOrganizeAwaitingCount > 0 {
                        Text(autoOrganizeAwaitingLabel)
                            .font(.grabbit(.caption))
                            .foregroundStyle(
                                autoOrganizeInProgressCount > 0
                                    ? DesignTokens.Color.sidebarTextSecondary.swiftUI
                                    : DesignTokens.Color.sidebarTextPrimary.swiftUI
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if autoOrganizeAwaitingCount > 0 {
                    Circle()
                        .fill(DesignTokens.Palette.gold[.t500].swiftUI)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                    .fill(DesignTokens.Color.sidebarBannerFill.swiftUI)
                    .shadow(
                        color: DesignTokens.Color.subtleElevationShadow.swiftUI,
                        radius: DesignTokens.Elevation.subtle.radius,
                        x: 0,
                        y: DesignTokens.Elevation.subtle.swiftUIYOffset
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                    .stroke(DesignTokens.Color.border.swiftUI.opacity(0.55), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Review auto-organize activity in bulk")
        .accessibilityLabel(autoOrganizeBannerAccessibilityLabel)
    }

    private var autoOrganizeInProgressLabel: String {
        let n = autoOrganizeInProgressCount
        return n == 1 ? "1 in progress" : "\(n) in progress"
    }

    private var autoOrganizeAwaitingLabel: String {
        let n = autoOrganizeAwaitingCount
        return n == 1 ? "1 waiting for confirmation" : "\(n) waiting for confirmation"
    }

    private var autoOrganizeBannerAccessibilityLabel: String {
        var parts: [String] = []
        if autoOrganizeInProgressCount > 0 { parts.append(autoOrganizeInProgressLabel) }
        if autoOrganizeAwaitingCount > 0 { parts.append(autoOrganizeAwaitingLabel) }
        return parts.joined(separator: ", ") + ". Open in bulk review."
    }

    private func openAutoOrganizeActivityInBulk() {
        let ids = autoOrganizeActivityIDs
        guard !ids.isEmpty else { return }
        // Prefer library order so bulk grouping matches the sidebar sequence.
        let ordered = entries.map(\.id).filter(ids.contains)
        let selected = Set(ordered.isEmpty ? Array(ids) : ordered)
        selection = selected
        selectionAnchor = ordered.first ?? selected.first
        ensureSelectionVisible()
        // Expand project groups that contain activity so rows stay discoverable.
        if groupBy == .project {
            for group in projectGroups where group.entries.contains(where: { selected.contains($0.id) }) {
                expandedGroupIDs.insert(group.id)
            }
        }
    }

    private var groupByPicker: some View {
        SoftControlDropdown(
            leadingLabel: "Group by",
            title: groupBy.menuLabel,
            help: "Group captures in the sidebar",
            primaryForeground: DesignTokens.Color.sidebarTextPrimary.swiftUI,
            secondaryForeground: DesignTokens.Color.sidebarTextSecondary.swiftUI,
            menuAlignment: .leading
        ) {
            ForEach(CaptureLibraryGroupBy.allCases) { option in
                SoftDropdownRow(
                    title: option.menuLabel,
                    systemImage: option.menuSymbol,
                    isSelected: option == groupBy
                ) {
                    groupByRaw = option.rawValue
                }
            }
        }
        .libraryTitlebarInteractive()
    }

    private var mediaFilterButton: some View {
        SoftControlIconDropdown(
            systemImage: "line.3.horizontal.decrease",
            isActive: isMediaFilterActive,
            help: "Filter by media type",
            foreground: DesignTokens.Color.sidebarTextPrimary.swiftUI
        ) {
            ForEach(CaptureLibraryMediaFilter.allCases) { option in
                SoftDropdownRow(
                    title: option.menuLabel,
                    systemImage: option.menuSymbol,
                    isSelected: mediaFilters.contains(option),
                    dismissesMenu: false
                ) {
                    toggleMediaFilter(option)
                }
            }
        }
        .libraryTitlebarInteractive()
    }

    private func toggleMediaFilter(_ filter: CaptureLibraryMediaFilter) {
        var next = mediaFilters
        if next.contains(filter) {
            next.remove(filter)
        } else {
            next.insert(filter)
        }
        mediaFilterRaw = CaptureLibraryMediaFilter.encode(next)
    }

    /// Drop selection that is hidden by the media filter; fall back to the first visible row.
    private func pruneSelectionToFilteredEntries() {
        let visibleIDs = Set(filteredEntries.map(\.id))
        let remaining = selection.intersection(visibleIDs)
        if remaining.isEmpty {
            if let first = filteredEntries.first {
                selection = [first.id]
                selectionAnchor = first.id
            } else {
                selection = []
                selectionAnchor = nil
            }
        } else if remaining.count != selection.count {
            selection = remaining
            if let anchor = selectionAnchor, !remaining.contains(anchor) {
                selectionAnchor = remaining.first
            }
        }
    }

    @ViewBuilder
    private var captureList: some View {
        // ScrollView (not List). Leading gutter is on the column; trailing
        // `scrollbarGutter` padding clears row content so the narrow overlay
        // scroller sits against the divider instead of on labels.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CaptureLibrarySidebarMetrics.rowSpacing) {
                switch groupBy {
                case .project:
                    groupedCaptureSections(projectGroups)
                case .none:
                    ForEach(visibleEntries) { entry in
                        captureListRow(for: entry)
                            .onAppear {
                                loadMoreIfNeeded(entry)
                            }
                    }
                }
            }
            .padding(.trailing, CaptureLibrarySidebarMetrics.scrollbarGutter)
            .padding(.bottom, CaptureLibraryChrome.windowEdgeInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .contentMargins(.horizontal, 0, for: .scrollIndicators)
        .contentMargins(.horizontal, 0)
        .scrollContentBackground(.hidden)
        .background(DesignTokens.Color.background.swiftUI)
        .background(CaptureLibraryScrollInsetZeroer())
    }

    @ViewBuilder
    private func groupedCaptureSections(
        _ groups: [CaptureLibraryNamedGroup]
    ) -> some View {
        ForEach(groups) { group in
            VStack(alignment: .leading, spacing: CaptureLibrarySidebarMetrics.rowSpacing) {
                namedGroupHeader(for: group)
                    .padding(.vertical, CaptureLibrarySidebarMetrics.rowVerticalPadding)

                // Expanded: full membership. Collapsed: still show the active
                // selection (Cursor-style) so the open capture stays findable.
                ForEach(visibleEntries(in: group)) { entry in
                    captureListRow(for: entry, nested: true)
                }
            }
            .onDrop(
                of: [Self.captureDragUTType],
                isTargeted: dropTargetBinding(for: group.id)
            ) { providers in
                handleCaptureDrop(providers, onto: group)
            }
        }
    }

    private func dropTargetBinding(for groupID: String) -> Binding<Bool> {
        Binding(
            get: { dropTargetGroupID == groupID },
            set: { targeted in
                if targeted {
                    dropTargetGroupID = groupID
                } else if dropTargetGroupID == groupID {
                    dropTargetGroupID = nil
                }
            }
        )
    }

    /// Rows shown under a project header — all when expanded, only selection when collapsed.
    private func visibleEntries(in group: CaptureLibraryNamedGroup) -> [CaptureEntry] {
        if expandedGroupIDs.contains(group.id) {
            return group.entries
        }
        return group.entries.filter { selection.contains($0.id) }
    }

    private func namedGroupHeader(
        for group: CaptureLibraryNamedGroup
    ) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)
        let isRenaming = projectRenameTarget == group.name
        let canRename = group.name != "None"
        let isDropTarget = dropTargetGroupID == group.id

        return Group {
            if isRenaming {
                projectRenameHeader(isExpanded: isExpanded)
            } else {
                Button {
                    toggleGroupExpanded(group.id)
                } label: {
                    projectHeaderLabel(
                        name: group.name,
                        isExpanded: isExpanded,
                        isDropTarget: isDropTarget
                    )
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .contextMenu {
                    if canRename {
                        Button {
                            beginProjectRename(group.name)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
    }

    private func projectHeaderLabel(
        name: String,
        isExpanded: Bool,
        isDropTarget: Bool
    ) -> some View {
        HStack(spacing: CaptureLibrarySidebarMetrics.groupIconSpacing) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignTokens.Color.sidebarTextSecondary.swiftUI)
                .frame(width: CaptureLibrarySidebarMetrics.disclosureWidth, alignment: .center)

            InlineStableNameLabel(text: name)
                .padding(.horizontal, CaptureInlineRenameChrome.horizontalPadding)
                .padding(.vertical, CaptureInlineRenameChrome.verticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(
                    DesignTokens.Color.listSelectionFill.swiftUI
                        .opacity(isDropTarget ? 0.85 : 0)
                )
                .padding(.trailing, CaptureLibrarySidebarMetrics.rowContentInset)
        )
        .contentShape(Rectangle())
    }

    private func projectRenameHeader(isExpanded: Bool) -> some View {
        HStack(spacing: CaptureLibrarySidebarMetrics.groupIconSpacing) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignTokens.Color.sidebarTextSecondary.swiftUI)
                .frame(width: CaptureLibrarySidebarMetrics.disclosureWidth, alignment: .center)

            InlineRenameTextField(
                text: $projectRenameDraft,
                onSubmit: commitProjectRename,
                onCancel: cancelProjectRename
            )
            .frame(
                minWidth: 0,
                maxWidth: .infinity,
                minHeight: CaptureInlineRenameChrome.sidebarNameLineHeight,
                maxHeight: CaptureInlineRenameChrome.sidebarNameLineHeight,
                alignment: .leading
            )
            .padding(.horizontal, CaptureInlineRenameChrome.horizontalPadding)
            .padding(.vertical, CaptureInlineRenameChrome.verticalPadding)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .strokeBorder(
                        DesignTokens.Color.softControlBorder.swiftUI,
                        lineWidth: CaptureInlineRenameChrome.focusLineWidth
                    )
            }
            .focusEffectDisabled()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleGroupExpanded(_ id: String) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if selection.count >= 2 {
            CaptureMultiSelectPane(
                entries: selectedEntries,
                rowStates: sessionState.rowStates,
                onAutoOrganize: { requestSuggestions(for: selection) },
                onAcceptAll: { acceptAllSuggestions(for: selection) },
                onDismissAll: { dismissAllSuggestions(for: selection) },
                onAcceptSuggestion: { acceptSuggestionWithMotion(for: $0) },
                onDismissSuggestion: { dismissSuggestion(for: $0) },
                onRevertSuggestion: { revertSuggestion(for: $0) },
                onSelectName: { setSuggestedName($0, for: $1) },
                onSelectProject: { setProject($0, for: $1) },
                onCreateProject: { beginCreateProject(for: $0) },
                onClearProject: { clearSuggestedProject(for: $0) },
                onOpenCapture: { entry in
                    selection = [entry.id]
                    selectionAnchor = entry.id
                },
                onRemoveTag: { entry, tag in
                    if entry.tags.contains(where: { $0.id == tag.id }) {
                        _ = CaptureHistory.shared.removeTag(id: entry.id, tagID: tag.id)
                    } else if tag.kind == .project {
                        _ = CaptureHistory.shared.clearProjectTag(id: entry.id)
                    }
                },
                onReplaceTag: { entry, tag, name in
                    if tag.kind == .project {
                        _ = CaptureHistory.shared.addTag(id: entry.id, kind: .project, name: name)
                    } else if entry.tags.contains(where: { $0.id == tag.id }) {
                        _ = CaptureHistory.shared.removeTag(id: entry.id, tagID: tag.id)
                        _ = CaptureHistory.shared.addTag(id: entry.id, kind: tag.kind, name: name)
                    } else {
                        _ = CaptureHistory.shared.addTag(id: entry.id, kind: tag.kind, name: name)
                    }
                }
            )
        } else if let entry = selectedEntry {
            CapturePreviewPane(
                entry: entry,
                sessionState: sessionState,
                isRenaming: renameTarget?.id == entry.id && renameSite == .preview,
                renameDraft: $renameDraft,
                onBeginRename: { beginRename(entry, site: .preview) },
                onCommitRename: commitRename,
                onCancelRename: cancelRename,
                onAutoOrganize: { requestSuggestion(for: entry) },
                onAcceptSuggestion: { acceptSuggestion(for: entry) },
                onDismissSuggestion: { dismissSuggestion(for: entry) },
                onSelectName: { setSuggestedName($0, for: entry.id) },
                onSelectProject: { setProject($0, for: entry.id) },
                onCreateProject: { beginCreateProject(for: entry.id) },
                onClearProject: { clearSuggestedProject(for: entry.id) },
                onRemoveTag: { tag in
                    if entry.tags.contains(where: { $0.id == tag.id }) {
                        _ = CaptureHistory.shared.removeTag(id: entry.id, tagID: tag.id)
                    } else if tag.kind == .project {
                        _ = CaptureHistory.shared.clearProjectTag(id: entry.id)
                    }
                },
                onReplaceTag: { tag, name in
                    if tag.kind == .project {
                        _ = CaptureHistory.shared.addTag(id: entry.id, kind: .project, name: name)
                    } else if entry.tags.contains(where: { $0.id == tag.id }) {
                        _ = CaptureHistory.shared.removeTag(id: entry.id, tagID: tag.id)
                        _ = CaptureHistory.shared.addTag(id: entry.id, kind: tag.kind, name: name)
                    } else {
                        _ = CaptureHistory.shared.addTag(id: entry.id, kind: tag.kind, name: name)
                    }
                }
            )
        } else {
            VStack(spacing: DesignTokens.Spacing.md) {
                RabbitIcon(width: 56)
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)

                Text("Select a Capture")
                    .font(.grabbit(.panelTitle))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)

                Text("Choose a screenshot or recording from the sidebar.")
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignTokens.Spacing.xl)
        }
    }

    @ViewBuilder
    private func captureListRow(for entry: CaptureEntry, nested: Bool = false) -> some View {
        let isRenamingInline = renameTarget?.id == entry.id && renameSite == .sidebar
        let isSelected = selection.contains(entry.id)
        let row = CaptureSidebarRow(
            entry: entry,
            rowState: sessionState.rowStates[entry.id] ?? CaptureRowSuggestionState(),
            isSelected: isSelected,
            isRenaming: isRenamingInline,
            renameDraft: $renameDraft,
            onCommitRename: commitRename,
            onCancelRename: cancelRename,
            onRevertSuggestion: { revertSuggestion(for: entry) }
        )

        // Keep the TextField out of a Button while renaming — otherwise macOS
        // shows an empty edit chrome until a second click focuses the field.
        Group {
            if isRenamingInline {
                row
            } else {
                Button {
                    handleCaptureRowClick(entry)
                } label: {
                    row
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
        // Column has the leading gutter. Flat rows need rowContentInset on both sides
        // inside the selection pill; nested rows keep disclosure indent on leading.
        // Trailing list gutter (scrollbar) is on the LazyVStack, not here.
        .padding(
            .leading,
            nested
                ? CaptureLibrarySidebarMetrics.nestedRowLeading
                : CaptureLibrarySidebarMetrics.rowContentInset
        )
        .padding(.trailing, CaptureLibrarySidebarMetrics.rowContentInset)
        .padding(.vertical, CaptureLibrarySidebarMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            listRowBackground(
                isSelected: isSelected,
                isHovered: hoveredCaptureID == entry.id
            )
        )
        // Inactive files sit one step lighter than folders / the active row.
        .foregroundStyle(
            isSelected
                ? DesignTokens.Color.sidebarTextPrimary.swiftUI
                : DesignTokens.Color.sidebarTextSecondary.swiftUI
        )
        .onHover { hovering in
            if hovering {
                hoveredCaptureID = entry.id
            } else if hoveredCaptureID == entry.id {
                hoveredCaptureID = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredCaptureID == entry.id)
        .modifier(CaptureRowDragModifier(
            isEnabled: !isRenamingInline && groupBy == .project,
            provider: { captureDragProvider(for: entry) }
        ))
        .contextMenu {
            Button {
                requestSuggestion(for: entry)
            } label: {
                Label("Auto-Rename", systemImage: "sparkles")
            }
            Button {
                showInFinder(entry)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Button {
                beginRename(entry, site: .sidebar)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                moveToTrash(entry)
            }
        }
    }

    private func captureDragProvider(for entry: CaptureEntry) -> NSItemProvider {
        let ids: [UUID]
        if selection.contains(entry.id) {
            ids = Array(selection)
        } else {
            ids = [entry.id]
        }
        let payload = (try? JSONEncoder().encode(ids.map(\.uuidString))) ?? Data()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: Self.captureDragTypeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    private func handleCaptureDrop(
        _ providers: [NSItemProvider],
        onto group: CaptureLibraryNamedGroup
    ) -> Bool {
        guard let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(Self.captureDragTypeIdentifier)
        else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: Self.captureDragTypeIdentifier) { data, _ in
            guard let data,
                  let strings = try? JSONDecoder().decode([String].self, from: data)
            else {
                return
            }
            let ids = strings.compactMap(UUID.init(uuidString:))
            DispatchQueue.main.async {
                moveCaptures(ids, toProject: group.name)
            }
        }
        return true
    }

    private func moveCaptures(_ ids: [UUID], toProject groupName: String) {
        guard !ids.isEmpty else { return }

        for id in ids {
            guard let entry = entries.first(where: { $0.id == id }) else { continue }
            let current = CaptureLibraryProject.currentName(for: entry)
            if groupName == "None" {
                if current != nil {
                    _ = CaptureHistory.shared.clearProjectTag(id: id)
                }
            } else if current != groupName {
                _ = CaptureHistory.shared.setProjectTag(id: id, name: groupName)
            }
        }

        expandedGroupIDs.insert(groupName)
        dropTargetGroupID = nil
    }

    private func handleCaptureRowClick(_ entry: CaptureEntry) {
        let now = Date()
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Double-click to rename only when not using selection modifiers.
        if modifiers.isEmpty,
           let last = lastRowClick,
           last.id == entry.id,
           now.timeIntervalSince(last.date) <= NSEvent.doubleClickInterval {
            lastRowClick = nil
            beginRename(entry, site: .sidebar)
            return
        }
        lastRowClick = (id: entry.id, date: now)

        if modifiers.contains(.shift) {
            selectRange(to: entry.id)
        } else if modifiers.contains(.command) {
            if selection.contains(entry.id) {
                selection.remove(entry.id)
            } else {
                selection.insert(entry.id)
            }
            selectionAnchor = entry.id
        } else {
            selection = [entry.id]
            selectionAnchor = entry.id
        }
    }

    /// Contiguous IDs in the order currently shown in the sidebar.
    private var selectableRowIDs: [UUID] {
        switch groupBy {
        case .none:
            return filteredEntries.map(\.id)
        case .project:
            return projectGroups.flatMap { visibleEntries(in: $0).map(\.id) }
        }
    }

    private func selectRange(to endID: UUID) {
        let orderedIDs = selectableRowIDs
        guard let endIndex = orderedIDs.firstIndex(of: endID) else {
            selection = [endID]
            selectionAnchor = endID
            return
        }

        let startID = selectionAnchor
            ?? selection.compactMap { orderedIDs.firstIndex(of: $0) }.min().map { orderedIDs[$0] }
            ?? endID
        guard let startIndex = orderedIDs.firstIndex(of: startID) else {
            selection = [endID]
            selectionAnchor = endID
            return
        }

        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        selection = Set(orderedIDs[lower...upper])
        // Keep the original anchor so repeated shift-clicks extend from the same start.
        if selectionAnchor == nil {
            selectionAnchor = startID
        }
    }

    private func listRowBackground(isSelected: Bool, isHovered: Bool) -> some View {
        // Hover sits one step below selection (was 0.55 — too light on the sidebar).
        let fillOpacity: CGFloat = isSelected ? 1 : (isHovered ? 0.75 : 0)
        return RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
            .fill(DesignTokens.Color.listSelectionFill.swiftUI.opacity(fillOpacity))
            // Gap between adjacent row backgrounds comes from stack `rowSpacing`.
    }

    private var createProjectAlertBinding: Binding<Bool> {
        Binding(
            get: { createProjectTarget != nil },
            set: { if !$0 { createProjectTarget = nil } }
        )
    }

    private func resetVisibleWindow() {
        visibleCount = min(Self.initialPageSize, max(filteredEntries.count, 0))
        ensureSelectionVisible()
    }

    @discardableResult
    private func applyPendingSelectionIfNeeded() -> Bool {
        guard let id = sessionState.pendingSelectionID else { return false }
        guard entries.contains(where: { $0.id == id }) else { return false }
        selection = [id]
        selectionAnchor = id
        sessionState.pendingSelectionID = nil
        ensureSelectionVisible()
        return true
    }

    private func ensureSelectionVisible() {
        let list = filteredEntries
        guard let farthestIndex = list.indices.reversed().first(where: { selection.contains(list[$0].id) }) else {
            visibleCount = min(max(visibleCount, Self.initialPageSize), list.count)
            return
        }
        let needed = farthestIndex + 1
        if needed > visibleCount {
            visibleCount = min(max(needed, Self.initialPageSize), list.count)
        } else {
            visibleCount = min(max(visibleCount, Self.initialPageSize), list.count)
        }
    }

    private func loadMoreIfNeeded(_ entry: CaptureEntry) {
        guard let index = visibleEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        let threshold = max(visibleEntries.count - 8, 0)
        guard index >= threshold else { return }
        guard visibleCount < filteredEntries.count else { return }
        visibleCount = min(visibleCount + Self.pageSize, filteredEntries.count)
    }

    private func beginCreateProject(for id: UUID) {
        createProjectTarget = id
        if let suggested = sessionState.rowStates[id]?.effectiveProject, !suggested.isEmpty {
            createProjectDraft = suggested
        } else if let entry = entries.first(where: { $0.id == id }) {
            createProjectDraft = CaptureLibraryProject.currentName(for: entry)
                ?? entry.tags.first(where: { $0.kind == .project })?.name
                ?? ""
        } else {
            createProjectDraft = ""
        }
    }

    private func setProject(_ project: String, for id: UUID) {
        updateRowState(id) { state in
            state.selectedProject = project
        }
    }

    private func clearSuggestedProject(for id: UUID) {
        updateRowState(id) { state in
            // Empty string = explicit None; keeps the picker visible.
            state.selectedProject = ""
        }
    }

    private func beginRename(_ entry: CaptureEntry, site: CaptureRenameSite) {
        cancelProjectRename()
        selection = [entry.id]
        selectionAnchor = entry.id
        // Seed the draft before flipping into edit mode so the field never
        // mounts against an empty string.
        renameDraft = entry.displayName
        renameSite = site
        renameTarget = entry
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != target.displayName {
            _ = CaptureHistory.shared.renameCapture(id: target.id, to: trimmed)
        }
        renameTarget = nil
    }

    private func cancelRename() {
        renameTarget = nil
    }

    private func beginProjectRename(_ name: String) {
        guard name != "None" else { return }
        cancelRename()
        projectRenameDraft = name
        projectRenameTarget = name
    }

    private func commitProjectRename() {
        guard let oldName = projectRenameTarget else { return }
        let draft = projectRenameDraft
        projectRenameTarget = nil

        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        guard let newName = CaptureLibraryOrganizer.sanitizedProjectName(trimmed) else { return }
        let normalizedNew = CaptureTag.normalizeName(newName)
        guard CaptureLibraryOrganizer.renameProject(from: oldName, to: normalizedNew) else {
            return
        }

        if expandedGroupIDs.contains(oldName) {
            expandedGroupIDs.remove(oldName)
            expandedGroupIDs.insert(normalizedNew)
        }
        rewriteSuggestionProjects(from: oldName, to: normalizedNew)
    }

    private func cancelProjectRename() {
        projectRenameTarget = nil
    }

    /// Keep in-flight Auto Organize pickers aligned with the renamed folder.
    private func rewriteSuggestionProjects(from oldName: String, to newName: String) {
        var states = sessionState.rowStates
        var didChange = false
        for id in states.keys {
            var state = states[id] ?? CaptureRowSuggestionState()
            var rowChanged = false
            if let selected = state.selectedProject,
               selected.caseInsensitiveCompare(oldName) == .orderedSame {
                state.selectedProject = newName
                rowChanged = true
            }
            if let suggestion = state.suggestion,
               let project = suggestion.suggestedProject,
               project.caseInsensitiveCompare(oldName) == .orderedSame {
                state.suggestion = RenameSuggestion(
                    suggestedName: suggestion.suggestedName,
                    suggestedProject: newName,
                    confidence: suggestion.confidence
                )
                rowChanged = true
            }
            if rowChanged {
                states[id] = state
                didChange = true
            }
        }
        if didChange {
            sessionState.rowStates = states
        }
    }

    private func showInFinder(_ entry: CaptureEntry) {
        // Fall back to the stored path so Finder still opens after iCloud/move races
        // where fileExists briefly fails.
        guard let url = CaptureHistory.shared.fileURL(for: entry.id)
            ?? CaptureHistory.shared.storedFileURL(for: entry.id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func moveToTrash(_ entry: CaptureEntry) {
        // Prefer the next row down before history reloads; otherwise
        // the entries onChange falls back to the latest capture.
        if selection.contains(entry.id) {
            if let nextID = selectionNeighbor(afterRemoving: entry.id) {
                selection = [nextID]
                selectionAnchor = nextID
            } else {
                selection = []
                selectionAnchor = nil
            }
        }
        if renameTarget?.id == entry.id {
            renameTarget = nil
        }
        cancelSuggestions(for: [entry.id])
        CaptureHistory.shared.remove(id: entry.id)
        removeRowState(entry.id)
    }

    /// Sidebar neighbor after deleting `id`: one down, or one up if it was last.
    private func selectionNeighbor(afterRemoving id: UUID) -> UUID? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < entries.count {
            return entries[index + 1].id
        }
        if index > 0 {
            return entries[index - 1].id
        }
        return nil
    }

    /// Assign a new dictionary so `@Published` always fires. In-place subscript
    /// / `removeValue` can use `_modify` and skip the wrapper setter — which made
    /// dismiss look like a no-op (accept still refreshed via history reload).
    private func updateRowState(_ id: UUID, _ transform: (inout CaptureRowSuggestionState) -> Void) {
        var states = sessionState.rowStates
        var state = states[id] ?? CaptureRowSuggestionState()
        transform(&state)
        states[id] = state
        sessionState.rowStates = states
    }

    private func removeRowState(_ id: UUID) {
        var states = sessionState.rowStates
        states.removeValue(forKey: id)
        sessionState.rowStates = states
    }

    private func removeRowStates(where shouldRemove: (UUID, CaptureRowSuggestionState) -> Bool) {
        let states = sessionState.rowStates.filter { !shouldRemove($0.key, $0.value) }
        sessionState.rowStates = states
    }

    // MARK: - Inline AI suggestion (batch evaluator → triage; never auto-apply)

    /// Cap parallel Foundation Models / OCR work so bulk Auto Organize stays responsive.
    fileprivate static let suggestionConcurrencyLimit = 3
    /// Accept All only commits suggestions the model marked reasonably sure about.
    fileprivate static let acceptAllMinimumConfidence = 0.7

    private func requestSuggestions(for ids: Set<UUID>) {
        let targets = entries.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let targetIDs = Set(targets.map(\.id))

        // Second click on a loading/queued target cancels only those IDs —
        // other in-flight Auto Organize work keeps running.
        let activeIDs = targetIDs.filter { isSuggestionActive($0) }
        if !activeIDs.isEmpty {
            cancelSuggestions(for: activeIDs)
            return
        }

        for entry in targets {
            guard !isSuggestionActive(entry.id) else { continue }
            let windowInfo = CaptureOrganizer.windowInfo(for: entry.id)
            updateRowState(entry.id) { state in
                state.isLoading = true
                state.suggestion = nil
                state.didCompleteWithoutSuggestion = false
                state.selectedName = nil
                state.selectedProject = nil
                state.acceptedSnapshot = nil
                state.wroteMapping = false
                state.windowInfo = windowInfo
            }
            suggestionQueue.append(entry.id)
        }

        pumpSuggestionQueue()
    }

    private func isSuggestionActive(_ id: UUID) -> Bool {
        suggestionInFlight[id] != nil || suggestionQueue.contains(id)
    }

    /// Cancel queued and/or in-flight Auto Organize for the given captures, then
    /// free slots for anything still waiting.
    private func cancelSuggestions(for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        suggestionQueue.removeAll { ids.contains($0) }
        for id in ids {
            suggestionInFlight.removeValue(forKey: id)?.task.cancel()
            updateRowState(id) { state in
                state.isLoading = false
            }
        }
        pumpSuggestionQueue()
    }

    /// Start up to `suggestionConcurrencyLimit` queued classifications.
    private func pumpSuggestionQueue() {
        while suggestionInFlight.count < Self.suggestionConcurrencyLimit,
              !suggestionQueue.isEmpty {
            let id = suggestionQueue.removeFirst()
            guard let entry = entries.first(where: { $0.id == id }) else {
                updateRowState(id) { state in
                    state.isLoading = false
                }
                continue
            }

            let token = UUID()
            let task = Task {
                await runSuggestion(for: entry)
                await MainActor.run {
                    guard suggestionInFlight[id]?.token == token else { return }
                    suggestionInFlight.removeValue(forKey: id)
                    pumpSuggestionQueue()
                }
            }
            suggestionInFlight[id] = SuggestionInFlight(token: token, task: task)
        }
    }

    private func runSuggestion(for entry: CaptureEntry) async {
        guard !Task.isCancelled else { return }

        guard let image = CaptureClassifier.imageForClassification(from: entry) else {
            await MainActor.run {
                guard !Task.isCancelled else { return }
                updateRowState(entry.id) { state in
                    state.isLoading = false
                    state.didCompleteWithoutSuggestion = true
                }
            }
            return
        }

        let windowInfo = CaptureOrganizer.windowInfo(for: entry.id)
        let request = CaptureSuggestionRequest(entry: entry, image: image, windowInfo: windowInfo)
        let suggestion = await CaptureClassifier.suggestRenameAndProject(for: request)
        await MainActor.run {
            guard !Task.isCancelled else { return }
            updateRowState(entry.id) { state in
                state.isLoading = false
                // Present when project and/or a strong rename was determined —
                // never blank schema placeholders (filename / project).
                let usable = (suggestion?.hasProject == true || suggestion?.hasRename == true)
                    ? suggestion
                    : nil
                state.suggestion = usable
                state.didCompleteWithoutSuggestion = usable == nil
                state.selectedName = usable?.suggestedName
                state.selectedProject = usable?.suggestedProject
                state.windowInfo = windowInfo
            }
        }
    }

    private func requestSuggestion(for entry: CaptureEntry) {
        requestSuggestions(for: [entry.id])
    }

    private func setSuggestedName(_ name: String, for id: UUID) {
        updateRowState(id) { state in
            state.selectedName = name
        }
    }

    private func acceptAllSuggestions(for ids: Set<UUID>, minimumConfidence: Double = acceptAllMinimumConfidence) {
        for entry in entries where ids.contains(entry.id) {
            guard let state = sessionState.rowStates[entry.id],
                  let suggestion = state.suggestion,
                  suggestion.confidence >= minimumConfidence else {
                continue
            }
            acceptSuggestionWithMotion(for: entry)
        }
    }

    private func dismissAllSuggestions(for ids: Set<UUID>) {
        for id in ids {
            suggestionAcceptTasks[id]?.cancel()
            suggestionAcceptTasks[id] = nil
        }
        var states = sessionState.rowStates
        var changed = false
        for id in ids {
            guard var state = states[id],
                  state.suggestion != nil
                    || state.didCompleteWithoutSuggestion
                    || state.isAcceptHandoff else { continue }
            state.suggestion = nil
            state.didCompleteWithoutSuggestion = false
            state.selectedName = nil
            state.selectedProject = nil
            state.isLoading = false
            state.acceptHandoffName = nil
            state.acceptHandoffProject = nil
            state.slidesNameOnAccept = false
            state.slidesProjectOnAccept = false
            state.isAccepting = false
            states[id] = state
            changed = true
        }
        guard changed else { return }
        sessionState.rowStates = states
    }

    /// Bulk / multi-select accept — slide-up changed fields, then apply.
    private func acceptSuggestionWithMotion(for entry: CaptureEntry) {
        guard let state = sessionState.rowStates[entry.id],
              state.suggestion != nil,
              !state.isAcceptHandoff else {
            return
        }

        let nextName = state.showsNameEditor ? state.effectiveName : nil
        let nextProject = state.showsProjectPicker
            ? (state.effectiveProject ?? "None")
            : nil
        let currentProject = CaptureLibraryProject.currentName(for: entry)
            ?? entry.tags.first(where: { $0.kind == .project })?.name
            ?? "None"

        let nameChanges = nextName.map {
            $0.caseInsensitiveCompare(entry.displayName) != .orderedSame
        } ?? false
        let projectChanges = nextProject.map {
            $0.caseInsensitiveCompare(currentProject) != .orderedSame
        } ?? false

        updateRowState(entry.id) { row in
            row.isAccepting = true
            row.slidesNameOnAccept = nameChanges
            row.slidesProjectOnAccept = projectChanges
        }

        suggestionAcceptTasks[entry.id]?.cancel()
        suggestionAcceptTasks[entry.id] = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            if nameChanges || projectChanges {
                withAnimation(DesignMotion.suggestionAccept(reduceMotion: reduceMotion)) {
                    updateRowState(entry.id) { row in
                        if nameChanges {
                            row.acceptHandoffName = nextName
                        }
                        if projectChanges {
                            row.acceptHandoffProject = nextProject
                        }
                    }
                }

                let settleNanos: UInt64 = reduceMotion
                    ? UInt64(DesignMotion.suggestionAcceptReducedDuration * 1_000_000_000)
                    : DesignMotion.suggestionAcceptSettlingNanoseconds
                try? await Task.sleep(nanoseconds: settleNanos)
                guard !Task.isCancelled else { return }
            }

            acceptSuggestion(for: entry)
            suggestionAcceptTasks[entry.id] = nil
        }
    }

    private func acceptSuggestion(for entry: CaptureEntry) {
        guard let state = sessionState.rowStates[entry.id],
              let suggestion = state.suggestion,
              let snapshot = CaptureLibraryOrganizer.snapshot(for: entry) else {
            return
        }

        let effectiveSuggestion = RenameSuggestion(
            suggestedName: state.effectiveName,
            suggestedProject: state.effectiveProject,
            confidence: suggestion.confidence
        )

        _ = CaptureLibraryOrganizer.apply(
            suggestion: effectiveSuggestion,
            to: entry,
            windowInfo: state.windowInfo
        )

        updateRowState(entry.id) { row in
            row.acceptedSnapshot = snapshot
            row.wroteMapping = effectiveSuggestion.hasProject && row.windowInfo != nil
            row.suggestion = nil
            row.didCompleteWithoutSuggestion = false
            row.selectedName = nil
            row.selectedProject = nil
            row.isLoading = false
            row.acceptHandoffName = nil
            row.acceptHandoffProject = nil
            row.slidesNameOnAccept = false
            row.slidesProjectOnAccept = false
            row.isAccepting = false
        }
    }

    private func dismissSuggestion(for entry: CaptureEntry) {
        updateRowState(entry.id) { state in
            state.suggestion = nil
            state.didCompleteWithoutSuggestion = false
            state.selectedName = nil
            state.selectedProject = nil
            state.isLoading = false
        }
    }

    private func revertSuggestion(for entry: CaptureEntry) {
        guard let state = sessionState.rowStates[entry.id],
              let snapshot = state.acceptedSnapshot else {
            return
        }

        CaptureLibraryOrganizer.revert(snapshot: snapshot, captureID: entry.id)
        if state.wroteMapping, let signature = state.windowInfo {
            CaptureDestinationMappingCache.shared.remove(signature: signature)
        }
        removeRowState(entry.id)
    }

    /// Drops the post-accept undo chrome without undoing the organize.
    private func dismissOrganizedConfirmation(for ids: Set<UUID>) {
        removeRowStates { id, state in
            ids.contains(id) && state.acceptedSnapshot != nil
        }
    }

}

private enum CaptureRenameSite {
    case sidebar
    case preview
}

/// Read-only AppKit label that shares `StableTextFieldCell` metrics with
/// `InlineRenameTextField`, so display→edit does not change glyph origin.
private struct InlineStableNameLabel: NSViewRepresentable {
    let text: String
    var textColor: NSColor = DesignTokens.Color.sidebarTextPrimary.ns
    var lineBreakMode: NSLineBreakMode = .byTruncatingTail
    /// Auto Organize sheen — drawn in-cell so glyphs never swap renderers.
    var isShimmering: Bool = false
    var shimmerHighlightColor: NSColor = DesignTokens.Color.sidebarTextPrimary.ns

    func makeNSView(context: Context) -> NSTextField {
        let field = StableFlippedTextField(string: text)
        field.installStableEditingCell()
        field.font = NSFont.grabbit(.caption)
        field.textColor = textColor
        field.isEditable = false
        field.isSelectable = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let cell = field.cell as? StableTextFieldCell {
            cell.lineBreakMode = lineBreakMode
            cell.isEditable = false
            cell.isSelectable = false
        }
        field.updateStableTextShimmer(
            isActive: isShimmering,
            highlightColor: isShimmering ? shimmerHighlightColor : nil
        )
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.textColor != textColor {
            nsView.textColor = textColor
            (nsView.cell as? StableTextFieldCell)?.textColor = textColor
        }
        if let cell = nsView.cell as? StableTextFieldCell, cell.lineBreakMode != lineBreakMode {
            cell.lineBreakMode = lineBreakMode
        }
        nsView.updateStableTextShimmer(
            isActive: isShimmering,
            highlightColor: isShimmering ? shimmerHighlightColor : nil
        )
    }
}

/// AppKit-backed rename field so the current name is visible immediately and
/// the field becomes first responder without an extra click.
private struct InlineRenameTextField: NSViewRepresentable {
    @Binding var text: String
    var textColor: NSColor = DesignTokens.Color.sidebarTextPrimary.ns
    /// When false, stays mounted as a read-only label (same cell metrics as edit).
    var isEditing: Bool = true
    /// Shown while `isEditing` is false (e.g. committed `displayName`).
    var displayText: String? = nil
    var isShimmering: Bool = false
    var shimmerHighlightColor: NSColor = DesignTokens.Color.sidebarTextPrimary.ns
    var lineBreakMode: NSLineBreakMode = .byTruncatingTail
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = RenameNSTextField(string: displayText ?? text)
        field.installStableEditingCell()
        field.font = NSFont.grabbit(.caption)
        field.textColor = textColor
        field.placeholderString = "Name"
        field.allowsEditingTextAttributes = false
        // Fill the SwiftUI-proposed slot — never hug the string width (that
        // made the edit ring jump to a tight box around the glyphs).
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.cancel()
        }
        applyEditingState(to: field, context: context, selectAll: false)
        return field
    }

    /// Take the full proposed width so read/edit share one slot (no hug-sizing).
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextField,
        context: Context
    ) -> CGSize? {
        let height = CaptureInlineRenameChrome.sidebarNameLineHeight
        if let width = proposal.width, width.isFinite, width >= 0 {
            return CGSize(width: width, height: height)
        }
        let fallback = nsView.bounds.width
        return CGSize(width: fallback > 0 ? fallback : 0, height: height)
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        if nsView.textColor != textColor {
            nsView.textColor = textColor
            (nsView.cell as? StableTextFieldCell)?.textColor = textColor
        }
        if let cell = nsView.cell as? StableTextFieldCell, cell.lineBreakMode != lineBreakMode {
            cell.lineBreakMode = lineBreakMode
        }
        nsView.font = NSFont.grabbit(.caption)
        (nsView.cell as? StableTextFieldCell)?.font = NSFont.grabbit(.caption)

        let wasEditing = context.coordinator.wasEditing
        applyEditingState(to: nsView, context: context, selectAll: false)

        if !isEditing {
            let shown = displayText ?? text
            if nsView.stringValue != shown {
                nsView.stringValue = shown
            }
            nsView.updateStableTextShimmer(
                isActive: isShimmering,
                highlightColor: isShimmering ? shimmerHighlightColor : nil
            )
        } else if nsView.stringValue != text, nsView.currentEditor() == nil {
            nsView.stringValue = text
            nsView.updateStableTextShimmer(isActive: false, highlightColor: nil)
        }
    }

    private func applyEditingState(
        to field: NSTextField,
        context: Context,
        selectAll: Bool
    ) {
        let editable = isEditing
        if editable && !context.coordinator.wasEditing {
            context.coordinator.didFinish = false
        }
        field.isEditable = editable
        field.isSelectable = editable
        (field.cell as? StableTextFieldCell)?.isEditable = editable
        (field.cell as? StableTextFieldCell)?.isSelectable = editable
        context.coordinator.wasEditing = editable

        guard editable else { return }
        DispatchQueue.main.async {
            guard context.coordinator.wasEditing else { return }
            guard let window = field.window else { return }
            if Self.isRenameEditor(window.firstResponder),
               window.firstResponder !== field,
               (window.firstResponder as? NSTextView)?.delegate as AnyObject? !== field {
                return
            }
            if window.firstResponder !== field,
               (window.firstResponder as? NSTextView)?.delegate as AnyObject? !== field {
                window.makeFirstResponder(field)
            }
            field.stabilizeFocusedEditor(selectAll: selectAll)
            // Keep the leading glyphs where idle truncation showed them —
            // select-all can otherwise scroll the field editor rightward.
            if selectAll, let editor = field.currentEditor() as? NSTextView {
                editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }

    private static func isRenameEditor(_ responder: NSResponder?) -> Bool {
        renameField(from: responder) != nil
    }

    /// Owning `RenameNSTextField` for a first responder (field or its editor).
    private static func renameField(from responder: NSResponder?) -> RenameNSTextField? {
        if let field = responder as? RenameNSTextField { return field }
        // Field editor delegate is typed as NSTextViewDelegate — bridge via AnyObject.
        if let textView = responder as? NSTextView,
           let field = textView.delegate as AnyObject? as? RenameNSTextField {
            return field
        }
        return nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onCancel: () -> Void
        var wasEditing = false
        var didFinish = false

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        @objc func submit(_ sender: NSTextField) {
            finish(commit: true)
        }

        func cancel() {
            finish(commit: false)
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            didFinish = false
            (obj.object as? NSTextField)?.stabilizeFocusedEditor(selectAll: false)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else {
                finish(commit: true)
                return
            }
            // Keep the latest string even if the last change notification was missed.
            text.wrappedValue = field.stringValue
            // Click-away calls endEditing while this field is still first responder.
            // Only skip commit when focus actually moved to a *different* rename field
            // (otherwise the blue ring stays and the name never saves).
            if let window = field.window,
               let other = InlineRenameTextField.renameField(from: window.firstResponder),
               other !== field {
                return
            }
            finish(commit: true)
        }

        private func finish(commit: Bool) {
            guard !didFinish else { return }
            didFinish = true
            if commit {
                onSubmit()
            } else {
                onCancel()
            }
        }
    }
}

private final class RenameNSTextField: StableFlippedTextField {
    var onEscape: (() -> Void)?

    override class var cellClass: AnyClass? {
        get { StableTextFieldCell.self }
        set {}
    }

    /// No intrinsic width — SwiftUI's frame / sizeThatFits owns the slot.
    /// Default NSTextField intrinsic hugs the string and collapses edit chrome.
    override var intrinsicContentSize: NSSize {
        let font = self.font ?? NSFont.grabbit(.caption)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(NSLayoutManager().defaultLineHeight(for: font))
        )
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            // Shared field editor resets lineFragmentPadding to 5 — lock it back.
            stabilizeFocusedEditor(selectAll: false)
        }
        return ok
    }

    override func layout() {
        super.layout()
        guard let editor = currentEditor() as? NSTextView else { return }
        (cell as? StableTextFieldCell)?.applyStableInsets(to: editor)
        (cell as? StableTextFieldCell)?.positionFieldEditor(editor, in: self, cellBounds: bounds)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Shared chrome so idle labels and rename fields share one text origin.
private enum CaptureInlineRenameChrome {
    static let horizontalPadding: CGFloat = 4
    static let verticalPadding: CGFloat = 1
    /// Preview header name field — match `TagKindDropdown` / soft-control padding.
    static let previewHorizontalPadding: CGFloat = 10
    static let previewVerticalPadding: CGFloat = 4
    /// Focus ring width — always reserved via clear stroke when idle so
    /// activating rename cannot consume layout insets and nudge glyphs.
    static let focusLineWidth: CGFloat = 1.5

    /// Fixed content line height for sidebar read/edit (caption + typesetter).
    static var sidebarNameLineHeight: CGFloat {
        let font = NSFont.grabbit(.caption)
        return ceil(NSLayoutManager().defaultLineHeight(for: font))
    }
}

private struct CaptureRowDragModifier: ViewModifier {
    let isEnabled: Bool
    let provider: () -> NSItemProvider

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrag(provider)
        } else {
            content
        }
    }
}

private struct CaptureSidebarRow: View {
    let entry: CaptureEntry
    let rowState: CaptureRowSuggestionState
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onRevertSuggestion: () -> Void

    /// Folder headers stay on `sidebarTextPrimary`. File names step to secondary
    /// when idle; the selected / renaming row keeps primary for hierarchy.
    private var filenameTextColor: NSColor {
        if rowState.isLoading {
            return DesignTokens.Color.sidebarTextSecondary.ns
        }
        if isSelected || isRenaming {
            return DesignTokens.Color.sidebarTextPrimary.ns
        }
        return DesignTokens.Color.sidebarTextSecondary.ns
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            filenameLabel
                .frame(maxWidth: .infinity, alignment: .leading)

            trailingMeta
                .layoutPriority(1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var filenameLabel: some View {
        // One AppKit field for read + edit. minWidth 0 + sizeThatFits fill the
        // name column; chrome wraps that slot so edit never hug-sizes glyphs.
        InlineRenameTextField(
            text: $renameDraft,
            textColor: filenameTextColor,
            isEditing: isRenaming,
            displayText: entry.displayName,
            isShimmering: rowState.isLoading,
            shimmerHighlightColor: DesignTokens.Color.sidebarTextPrimary.ns,
            onSubmit: onCommitRename,
            onCancel: onCancelRename
        )
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: CaptureInlineRenameChrome.sidebarNameLineHeight,
            maxHeight: CaptureInlineRenameChrome.sidebarNameLineHeight,
            alignment: .leading
        )
        .padding(.horizontal, CaptureInlineRenameChrome.horizontalPadding)
        .padding(.vertical, CaptureInlineRenameChrome.verticalPadding)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .fill(
                    isRenaming
                        ? Color(nsColor: .textBackgroundColor)
                        : Color.clear
                )
        }
        .overlay { filenameChrome }
        .focusEffectDisabled()
        .clipped()
        .contentShape(Rectangle())
        .accessibilityLabel(
            rowState.isLoading
                ? "\(entry.displayName), auto-organizing"
                : entry.displayName
        )
        .transaction { $0.animation = nil }
    }

    /// Same ring metrics idle and editing — clear while idle, soft border while renaming.
    private var filenameChrome: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
            .strokeBorder(
                isRenaming
                    ? DesignTokens.Color.softControlBorder.swiftUI
                    : Color.clear,
                lineWidth: CaptureInlineRenameChrome.focusLineWidth
            )
    }

    @ViewBuilder
    private var trailingMeta: some View {
        if rowState.isLoading {
            RabbitHopLoader(size: .compact)
                .foregroundStyle(DesignTokens.Color.sidebarTextSecondary.swiftUI)
                .help("Auto-organizing…")
        } else if rowState.suggestion != nil {
            // Same trailing slot as the hop loader — yellow means suggestion is
            // open and waiting for accept/dismiss (replaces the relative date).
            Circle()
                .fill(DesignTokens.Palette.gold[.t500].swiftUI)
                .frame(width: 7, height: 7)
                .frame(
                    width: RabbitHopLoader.Size.compact.pointSize.width,
                    height: RabbitHopLoader.Size.compact.pointSize.height
                )
                .help("Suggestion ready — accept or dismiss in the preview")
                .accessibilityLabel("Suggestion awaiting confirmation")
        } else if rowState.acceptedSnapshot != nil {
            HStack(spacing: 4) {
                Text("Undo?")
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.sidebarTextSecondary.swiftUI)
                    .help("Just organized — click undo to revert, or select another capture to dismiss")
                Button(action: onRevertSuggestion) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignTokens.Color.sidebarTextSecondary.swiftUI)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Undo rename and move")
            }
        } else if rowState.didCompleteWithoutSuggestion {
            Text("No suggestions")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.sidebarTextSecondary.swiftUI)
                .help("Auto Organize couldn’t find a name or project for this capture")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Text(entry.createdAt.compactRelativeLabel)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.sidebarTextSecondary.swiftUI)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private enum CaptureLibraryProject {
    static func currentName(for entry: CaptureEntry) -> String? {
        guard !CaptureHistory.shared.isAtRootCapture(id: entry.id),
              let parent = CaptureHistory.shared.parentDirectoryURL(for: entry.id) else {
            return nil
        }
        return parent.lastPathComponent
    }
}

/// Idle Auto Organize label (rabbit + text), or centered hop loader while requesting.
/// Loader is overlaid so its taller frame can't grow the button and nudge the preview.
/// One rabbit view slides from the leading icon slot into the center — no crossfade.
private struct AutoOrganizeButtonLabel: View {
    let isLoading: Bool

    private static let spacing: CGFloat = 6
    private static let idleSize = CGSize(width: 18, height: 18 * 12 / 25)
    private static let loadingSize = RabbitHopLoader.Size.compact.pointSize

    var body: some View {
        HStack(spacing: Self.spacing) {
            Color.clear
                .frame(width: Self.idleSize.width, height: Self.idleSize.height)
            Text("Auto Organize")
                .opacity(isLoading ? 0 : 1)
                // Label drops out instantly; only the rabbit motion should read.
                .animation(nil, value: isLoading)
        }
        .overlay {
            GeometryReader { geo in
                let rabbitSize = isLoading ? Self.loadingSize : Self.idleSize
                let x = isLoading ? (geo.size.width - rabbitSize.width) / 2 : 0
                let y = (geo.size.height - rabbitSize.height) / 2

                RabbitHopLoader(
                    size: .compact,
                    isAnimating: isLoading,
                    pointSizeOverride: rabbitSize
                )
                .offset(x: x, y: y)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: isLoading)
    }
}

private enum CaptureMultiSelectLayoutMode: String, CaseIterable, Identifiable {
    case cards
    case list

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .cards: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }

    var help: String {
        switch self {
        case .cards: return "Card view"
        case .list: return "List view"
        }
    }
}

private enum CaptureMultiSelectCardMetrics {
    /// Wrap to fewer columns when a card would be narrower than this.
    static let minWidth: CGFloat = 200
    static let spacing: CGFloat = DesignTokens.Spacing.md
    static let imageAspect: CGFloat = 4.0 / 3.0
    /// Retina-sharp card previews (list thumbs are only 240px).
    static let previewMaxPixelSize: CGFloat = 720
    /// Status row (“Confirm Suggestion” + check/X).
    static let statusRowHeight: CGFloat = 22

    /// 1 / 2 / 3 columns from available width — wraps when cards would be < `minWidth`.
    static func columnCount(forAvailableWidth width: CGFloat) -> Int {
        let fitted = Int(floor((width + spacing) / (minWidth + spacing)))
        return min(3, max(1, fitted))
    }

    /// Equal-width columns that fill the row (no max card width).
    /// `.top` keeps shorter idle/loading cards flush with taller suggestion siblings.
    static func columns(forAvailableWidth width: CGFloat) -> [GridItem] {
        let count = columnCount(forAvailableWidth: width)
        let gaps = CGFloat(count - 1) * spacing
        let cardWidth = max(0, (width - gaps) / CGFloat(count))
        return Array(
            repeating: GridItem(.fixed(cardWidth), spacing: spacing, alignment: .top),
            count: count
        )
    }
}

private struct CaptureMultiSelectPane: View {
    let entries: [CaptureEntry]
    let rowStates: [UUID: CaptureRowSuggestionState]
    let onAutoOrganize: () -> Void
    let onAcceptAll: () -> Void
    let onDismissAll: () -> Void
    let onAcceptSuggestion: (CaptureEntry) -> Void
    let onDismissSuggestion: (CaptureEntry) -> Void
    let onRevertSuggestion: (CaptureEntry) -> Void
    let onSelectName: (String, UUID) -> Void
    let onSelectProject: (String, UUID) -> Void
    let onCreateProject: (UUID) -> Void
    let onClearProject: (UUID) -> Void
    /// Thumbnail / preview click → leave multi-select into that capture’s detail.
    let onOpenCapture: (CaptureEntry) -> Void
    let onRemoveTag: (CaptureEntry, CaptureTag) -> Void
    let onReplaceTag: (CaptureEntry, CaptureTag, String) -> Void

    @AppStorage("captureLibraryMultiSelectLayout") private var layoutModeRaw =
        CaptureMultiSelectLayoutMode.cards.rawValue

    private var selectedLayoutMode: CaptureMultiSelectLayoutMode {
        CaptureMultiSelectLayoutMode(rawValue: layoutModeRaw) ?? .cards
    }

    private var layoutMode: Binding<CaptureMultiSelectLayoutMode> {
        Binding(
            get: { selectedLayoutMode },
            set: { layoutModeRaw = $0.rawValue }
        )
    }

    private var isAnyLoading: Bool {
        entries.contains { rowStates[$0.id]?.isLoading == true }
    }

    private var pendingSuggestionCount: Int {
        entries.reduce(0) { count, entry in
            count + (rowStates[entry.id]?.suggestion != nil ? 1 : 0)
        }
    }

    private var acceptAllCount: Int {
        entries.reduce(0) { count, entry in
            guard let suggestion = rowStates[entry.id]?.suggestion,
                  suggestion.confidence >= CaptureLibraryView.acceptAllMinimumConfidence else {
                return count
            }
            return count + 1
        }
    }

    private var projectOptions: [String] {
        CaptureLibraryOrganizer.existingProjectNames()
    }

    private struct ProjectGroup: Identifiable {
        let id: String
        let title: String
        let entries: [CaptureEntry]
    }

    /// Group triage rows by suggested (or committed) project so bulk review scans faster.
    private var groupedEntries: [ProjectGroup] {
        var buckets: [String: [CaptureEntry]] = [:]
        var order: [String] = []

        for entry in entries {
            let key = triageProjectKey(for: entry)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key, default: []].append(entry)
        }

        return order.map { key in
            let title = key.isEmpty ? "No project" : key
            return ProjectGroup(id: key.isEmpty ? "__none__" : key, title: title, entries: buckets[key] ?? [])
        }
    }

    private func triageProjectKey(for entry: CaptureEntry) -> String {
        let state = rowStates[entry.id] ?? CaptureRowSuggestionState()
        if let suggested = state.effectiveProject?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            return suggested
        }
        if let committed = entry.tags.first(where: { $0.kind == .project })?.name {
            return committed
        }
        return CaptureLibraryProject.currentName(for: entry) ?? ""
    }

    /// e.g. “3 images”, “2 images, 1 video”.
    private var selectionMediaCountLabel: String {
        let imageCount = entries.filter { !$0.isRecording }.count
        let videoCount = entries.filter(\.isRecording).count
        var parts: [String] = []
        if imageCount > 0 {
            parts.append(imageCount == 1 ? "1 image" : "\(imageCount) images")
        }
        if videoCount > 0 {
            parts.append(videoCount == 1 ? "1 video" : "\(videoCount) videos")
        }
        return parts.isEmpty ? "0 images" : parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    onAutoOrganize()
                } label: {
                    AutoOrganizeButtonLabel(isLoading: isAnyLoading)
                }
                .buttonStyle(.grabbit)
                .fixedSize()
                .disabled(entries.isEmpty)
                .help(isAnyLoading ? "Cancel auto-organizing" : "Auto Organize")
                .libraryTitlebarInteractive()

                Text(selectionMediaCountLabel)
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                    .fixedSize()

                Spacer(minLength: DesignTokens.Spacing.sm)

                Picker("Layout", selection: layoutMode) {
                    ForEach(CaptureMultiSelectLayoutMode.allCases) { mode in
                        Image(systemName: mode.symbolName)
                            .tag(mode)
                            .help(mode.help)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 72)
                .help("Bulk selection layout")
                .libraryTitlebarInteractive()
            }
            .padding(.leading, CaptureLibraryChrome.windowEdgeInset)
            .padding(.trailing, CaptureLibraryChrome.windowEdgeInset)
            .padding(.top, CaptureLibraryChrome.topChromeInset)
            .padding(.bottom, DesignTokens.Spacing.sm)

            Group {
                if selectedLayoutMode == .cards {
                    cardScrollContent
                } else {
                    listScrollContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.Color.background.swiftUI)
        }
        .overlay(alignment: .bottom) {
            if pendingSuggestionCount > 0 {
                bulkSuggestionActionBar
                    .padding(.bottom, DesignTokens.Spacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: pendingSuggestionCount > 0)
    }

    /// Floating bottom chrome — Accept All before Dismiss All (Auto Organize stays top).
    private var bulkSuggestionActionBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button(acceptAllCount > 0 ? "Accept All (\(acceptAllCount))" : "Accept All") {
                onAcceptAll()
            }
            .buttonStyle(.grabbit)
            .fixedSize()
            .disabled(isAnyLoading || acceptAllCount == 0)
            .help(
                acceptAllCount < pendingSuggestionCount
                    ? "Accepts suggestions with confidence ≥ 0.7 (\(pendingSuggestionCount - acceptAllCount) lower-confidence left for manual review)"
                    : "Accept suggestions with confidence ≥ 0.7"
            )

            Button("Dismiss All") {
                onDismissAll()
            }
            .buttonStyle(.grabbit)
            .fixedSize()
            .disabled(isAnyLoading)
            .help("Dismiss all pending suggestions")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(DesignTokens.Color.panelSurface.swiftUI)
                .shadow(
                    color: .black.opacity(Double(DesignTokens.Elevation.panel.opacity)),
                    radius: DesignTokens.Elevation.panel.radius,
                    x: 0,
                    y: DesignTokens.Elevation.panel.swiftUIYOffset
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Color.borderOnPanel.swiftUI, lineWidth: 1)
        }
    }

    private var listScrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedEntries) { group in
                    if groupedEntries.count > 1 {
                        Text(group.title)
                            .font(.grabbit(.caption))
                            .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                            .padding(.horizontal, DesignTokens.Spacing.lg)
                            .padding(.top, DesignTokens.Spacing.md)
                            .padding(.bottom, DesignTokens.Spacing.xs)
                    }

                    ForEach(group.entries) { entry in
                        multiSelectRow(for: entry)
                    }
                }
            }
            .padding(.vertical, DesignTokens.Spacing.sm)
            .padding(.bottom, pendingSuggestionCount > 0 ? 56 : 0)
        }
    }

    private var cardScrollContent: some View {
        GeometryReader { geo in
            let contentWidth = max(
                0,
                geo.size.width - 2 * CaptureLibraryChrome.windowEdgeInset
            )
            let columns = CaptureMultiSelectCardMetrics.columns(forAvailableWidth: contentWidth)

            ScrollView {
                // One grid in selection order — no in-progress vs confirmation sections.
                LazyVGrid(
                    columns: columns,
                    alignment: .leading,
                    spacing: CaptureMultiSelectCardMetrics.spacing
                ) {
                    ForEach(entries) { entry in
                        multiSelectCard(for: entry)
                            // Fill the row cell and pin content to the top so
                            // shorter idle cards don’t vertically center.
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CaptureLibraryChrome.windowEdgeInset)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .padding(.bottom, pendingSuggestionCount > 0 ? 56 : 0)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func multiSelectRow(for entry: CaptureEntry) -> some View {
        let rowState = rowStates[entry.id] ?? CaptureRowSuggestionState()
        let isAcceptHandoff = rowState.isAcceptHandoff
        let hasSuggestion = rowState.suggestion != nil && !isAcceptHandoff

        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(nsImage: entry.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
                .contentShape(Rectangle())
                .onTapGesture { onOpenCapture(entry) }
                .pointerStyle(.link)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Open \(entry.displayName)")
                .help("Open capture")

            if isAcceptHandoff {
                acceptHandoffPathContent(for: entry, rowState: rowState)
            } else if hasSuggestion {
                suggestionPathContent(for: entry, rowState: rowState)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    CursorStyleShimmerText(
                        text: entry.displayName,
                        isShimmering: rowState.isLoading,
                        font: .grabbit(.bodyEmphasized),
                        baseColor: DesignTokens.Color.textSecondary.swiftUI,
                        highlightColor: DesignTokens.Color.textPrimary.swiftUI,
                        idleColor: DesignTokens.Color.textPrimary.swiftUI,
                        lineLimit: 1,
                        voiceOverLabel: "\(entry.displayName), auto-organizing"
                    )

                    projectAndTags(for: entry, rowState: rowState)
                }
            }

            Spacer(minLength: 0)

            if hasSuggestion {
                Text("Confirm Suggestion")
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                    .fixedSize()
            }

            trailingActions(for: entry, rowState: rowState)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func multiSelectCard(for entry: CaptureEntry) -> some View {
        let rowState = rowStates[entry.id] ?? CaptureRowSuggestionState()
        let isAcceptHandoff = rowState.isAcceptHandoff
        let hasSuggestion = rowState.suggestion != nil && !isAcceptHandoff
        let pathText = cardPathBodyText(for: entry)

        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            MultiSelectCardThumbnail(entry: entry)
                .aspectRatio(CaptureMultiSelectCardMetrics.imageAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                        .strokeBorder(DesignTokens.Color.borderOnPanel.swiftUI, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
                .onTapGesture { onOpenCapture(entry) }
                .pointerStyle(.link)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Open \(entry.displayName)")
                .help("Open capture")

            // Original path → new suggestion controls → Confirm Suggestion + approve/deny.
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                cardOriginalPathLabel(
                    text: pathText,
                    isLoading: rowState.isLoading,
                    isSuggestionReady: hasSuggestion || isAcceptHandoff
                )

                if hasSuggestion {
                    suggestionCardPathContent(for: entry, rowState: rowState)
                    cardStatusRow(for: entry, rowState: rowState, hasSuggestion: true)
                } else if isAcceptHandoff {
                    acceptHandoffCardPathContent(for: entry, rowState: rowState)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    /// Original `Project / Filename` under the thumbnail.
    /// Caption / regular weight (not medium body). Idle: primary. Loading: shimmer.
    /// Suggestion ready: tertiary grey.
    @ViewBuilder
    private func cardOriginalPathLabel(
        text: String,
        isLoading: Bool,
        isSuggestionReady: Bool
    ) -> some View {
        if isLoading {
            CursorStyleShimmerText(
                text: text,
                isShimmering: true,
                font: .grabbit(.caption),
                baseColor: DesignTokens.Color.textSecondary.swiftUI,
                highlightColor: DesignTokens.Color.textPrimary.swiftUI,
                idleColor: DesignTokens.Color.textPrimary.swiftUI,
                lineLimit: 2,
                truncationMode: .middle,
                voiceOverLabel: "\(text), auto-organizing"
            )
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        } else {
            Text(text)
                .font(.grabbit(.caption))
                .fontWeight(.regular)
                .foregroundStyle(
                    isSuggestionReady
                        ? DesignTokens.Color.textTertiary.swiftUI
                        : DesignTokens.Color.textPrimary.swiftUI
                )
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Body-text path under the thumbnail — e.g. `People / Factory Terminal` or `None / current name`.
    private func cardPathBodyText(for entry: CaptureEntry) -> String {
        let project = committedProjectTag(for: entry)?.name ?? "None"
        return "\(project) / \(entry.displayName)"
    }

    /// “Confirm Suggestion” + accept/dismiss — annotation-panel grabbit icon buttons.
    @ViewBuilder
    private func cardStatusRow(
        for entry: CaptureEntry,
        rowState: CaptureRowSuggestionState,
        hasSuggestion: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            Text("Confirm Suggestion")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .opacity(hasSuggestion ? 1 : 0)
                .accessibilityHidden(!hasSuggestion)

            Spacer(minLength: 0)

            trailingActions(for: entry, rowState: rowState)
        }
        .frame(maxWidth: .infinity, minHeight: CaptureMultiSelectCardMetrics.statusRowHeight, alignment: .center)
    }

    /// Confirmation UI: folder dropdown + literal `/`, then filename input on the next line.
    @ViewBuilder
    private func suggestionCardPathContent(
        for entry: CaptureEntry,
        rowState: CaptureRowSuggestionState
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                if rowState.showsProjectPicker {
                    TagKindDropdown(
                        kind: .project,
                        selected: rowState.effectiveProject ?? "None",
                        options: projectOptions,
                        onRemove: rowState.effectiveProject == nil
                            ? nil
                            : { onClearProject(entry.id) },
                        onSelect: { onSelectProject($0, entry.id) },
                        onCreateNew: { onCreateProject(entry.id) }
                    )
                } else {
                    committedProjectDropdown(
                        for: entry,
                        isReadOnly: true
                    )
                }

                Text("/")
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)
            }

            if rowState.showsNameEditor, let name = rowState.effectiveName {
                SuggestedNameField(
                    name: name,
                    onCommit: { onSelectName($0, entry.id) },
                    fillsAvailableWidth: true
                )
            } else {
                Text(entry.displayName)
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    /// Accept handoff for cards — same folder `/` + filename stack as confirmation.
    @ViewBuilder
    private func acceptHandoffCardPathContent(
        for entry: CaptureEntry,
        rowState: CaptureRowSuggestionState
    ) -> some View {
        let displayName = rowState.acceptHandoffName ?? entry.displayName
        let committedProject = committedProjectTag(for: entry)?.name ?? "None"
        let displayProject = rowState.acceptHandoffProject ?? committedProject

        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                TagKindDropdown(
                    kind: .project,
                    selected: displayProject,
                    options: projectOptions,
                    isReadOnly: true,
                    slidesSelectionChanges: rowState.slidesProjectOnAccept,
                    onSelect: { _ in },
                    onCreateNew: {}
                )

                Text("/")
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)
            }

            Group {
                if rowState.slidesNameOnAccept {
                    SlideUpReplaceSlot(value: displayName) {
                        Text(displayName)
                            .font(.grabbit(.body))
                            .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(displayName)
                        .font(.grabbit(.body))
                        .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    /// Project ▾ / filename path used while a suggestion is active (list layout).
    @ViewBuilder
    private func suggestionPathContent(
        for entry: CaptureEntry,
        rowState: CaptureRowSuggestionState
    ) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            if rowState.showsProjectPicker {
                TagKindDropdown(
                    kind: .project,
                    selected: rowState.effectiveProject ?? "None",
                    options: projectOptions,
                    onRemove: rowState.effectiveProject == nil
                        ? nil
                        : { onClearProject(entry.id) },
                    onSelect: { onSelectProject($0, entry.id) },
                    onCreateNew: { onCreateProject(entry.id) }
                )
            }

            if rowState.showsNameEditor, let name = rowState.effectiveName {
                Text("/")
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                    .accessibilityHidden(true)

                SuggestedNameField(name: name) { onSelectName($0, entry.id) }
            }
        }
    }

    /// Committed-style path during accept handoff — only changed fields slide up.
    @ViewBuilder
    private func acceptHandoffPathContent(
        for entry: CaptureEntry,
        rowState: CaptureRowSuggestionState
    ) -> some View {
        let displayName = rowState.acceptHandoffName ?? entry.displayName
        let committedProject = committedProjectTag(for: entry)?.name ?? "None"
        let displayProject = rowState.acceptHandoffProject ?? committedProject

        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            TagKindDropdown(
                kind: .project,
                selected: displayProject,
                options: projectOptions,
                isReadOnly: true,
                slidesSelectionChanges: rowState.slidesProjectOnAccept,
                onSelect: { _ in },
                onCreateNew: {}
            )

            Text("/")
                .font(.grabbit(.body))
                .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                .accessibilityHidden(true)

            if rowState.slidesNameOnAccept {
                SlideUpReplaceSlot(value: displayName) {
                    Text(displayName)
                        .font(.grabbit(.bodyEmphasized))
                        .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(displayName)
                    .font(.grabbit(.bodyEmphasized))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func projectAndTags(
        for entry: CaptureEntry,
        rowState: CaptureRowSuggestionState
    ) -> some View {
        committedProjectDropdown(
            for: entry,
            isReadOnly: rowState.suggestion != nil || rowState.isAcceptHandoff,
            isLoading: rowState.isLoading
        )
    }

    @ViewBuilder
    private func committedProjectDropdown(
        for entry: CaptureEntry,
        isReadOnly: Bool,
        isLoading: Bool = false,
        fillsAvailableWidth: Bool = false
    ) -> some View {
        let project = committedProjectTag(for: entry)
        TagKindDropdown(
            kind: .project,
            selected: project?.name ?? "None",
            options: projectOptions,
            isReadOnly: isReadOnly,
            isLoading: isLoading,
            fillsAvailableWidth: fillsAvailableWidth,
            onRemove: isReadOnly || isLoading
                ? nil
                : project.map { tag in { onRemoveTag(entry, tag) } },
            onSelect: { name in
                guard !isReadOnly, !isLoading else { return }
                if let project, name.caseInsensitiveCompare(project.name) == .orderedSame { return }
                onReplaceTag(entry, project ?? CaptureTag(kind: .project, name: name), name)
            },
            onCreateNew: { onCreateProject(entry.id) }
        )
    }

    private func committedProjectTag(for entry: CaptureEntry) -> CaptureTag? {
        if let tag = entry.tags.first(where: { $0.kind == .project }) {
            return tag
        }
        guard let project = CaptureLibraryProject.currentName(for: entry) else { return nil }
        return CaptureTag(id: entry.id, kind: .project, name: project)
    }

    @ViewBuilder
    private func trailingActions(for entry: CaptureEntry, rowState: CaptureRowSuggestionState) -> some View {
        if rowState.isAcceptHandoff {
            EmptyView()
        } else if rowState.suggestion != nil {
            // Same soft grabbit icon buttons as the preview / annotation accept-reject controls.
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    onAcceptSuggestion(entry)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.grabbit)
                .fixedSize()
                .help("Accept rename and project")

                Button {
                    onDismissSuggestion(entry)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.grabbit)
                .fixedSize()
                .help("Dismiss suggestion")
            }
        } else if rowState.acceptedSnapshot != nil {
            Button {
                onRevertSuggestion(entry)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.grabbit)
            .fixedSize()
            .help("Revert rename and move")
        }
    }
}

/// Shows the list thumb immediately, then upgrades to a Retina-sharp preview from disk.
private struct MultiSelectCardThumbnail: View {
    let entry: CaptureEntry

    @State private var preview: NSImage?

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .overlay {
                Image(nsImage: preview ?? entry.thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .clipped()
            .background(DesignTokens.Color.background.swiftUI)
            .task(id: entry.id) {
                preview = nil
                let id = entry.id
                await Task.yield()
                guard !Task.isCancelled else { return }
                preview = CaptureHistory.shared.previewImage(
                    for: id,
                    maxPixelSize: CaptureMultiSelectCardMetrics.previewMaxPixelSize
                )
            }
    }
}

private enum AutoOrganizeSuggestionPhase: Equatable {
    case idle
    case presented
    case accepting
    case rejecting
}

private struct CapturePreviewPane: View {
    let entry: CaptureEntry
    @ObservedObject var sessionState: CaptureLibrarySessionState
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onAutoOrganize: () -> Void
    let onAcceptSuggestion: () -> Void
    let onDismissSuggestion: () -> Void
    let onSelectName: (String) -> Void
    let onSelectProject: (String) -> Void
    let onCreateProject: () -> Void
    let onClearProject: () -> Void
    let onRemoveTag: (CaptureTag) -> Void
    let onReplaceTag: (CaptureTag, String) -> Void

    @State private var suggestionPhase: AutoOrganizeSuggestionPhase = .idle
    @State private var pendingDisplayProject: String?
    @State private var pendingDisplayName: String?
    /// Which fields will slide on this accept (set before pending values swap).
    @State private var nameWillSlideOnAccept = false
    @State private var projectWillSlideOnAccept = false
    @State private var fullScreenshot: NSImage?
    @State private var loadTask: Task<Void, Never>?
    @State private var suggestionAnimationTask: Task<Void, Never>?
    /// Preview filename idle hover — shows text-input chrome so click-to-rename is obvious.
    @State private var isNameHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rowState: CaptureRowSuggestionState {
        sessionState.rowStates[entry.id] ?? CaptureRowSuggestionState()
    }

    private var showsSuggestionRow: Bool {
        let hasUsable = rowState.suggestion?.hasProject == true
            || rowState.suggestion?.hasRename == true
        return hasUsable
            && (suggestionPhase == .presented || suggestionPhase == .rejecting)
    }

    /// Blocks Auto Organize while a suggestion is on screen (still clickable while loading to cancel).
    private var blocksAutoOrganizeInteraction: Bool {
        suggestionPhase == .presented
            || suggestionPhase == .accepting
            || suggestionPhase == .rejecting
    }

    private var projectOptions: [String] {
        CaptureLibraryOrganizer.existingProjectNames()
    }

    /// Existing name / project stay visible but non-editable while a suggestion is up.
    private var isExistingReadOnly: Bool {
        suggestionPhase != .idle
    }

    private var suggestionInsertAnimation: Animation {
        .spring(response: 0.38, dampingFraction: 0.86)
    }

    private var suggestionAcceptAnimation: Animation {
        DesignMotion.suggestionAccept(reduceMotion: reduceMotion)
    }

    private var suggestionRejectAnimation: Animation {
        .easeOut(duration: 0.28)
    }

    /// Committed filename while idle, or pending accept handoff value.
    private var displayedName: String {
        pendingDisplayName ?? entry.displayName
    }

    private var animatesNameAccept: Bool {
        suggestionPhase == .accepting && nameWillSlideOnAccept
    }

    private var animatesProjectAccept: Bool {
        suggestionPhase == .accepting && projectWillSlideOnAccept
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Both rows: project / filename …… trailing actions
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                committedPathRow

                if showsSuggestionRow, rowState.suggestion != nil {
                    suggestionPathRow
                        .scaleEffect(suggestionPhase == .rejecting ? 0.9 : 1, anchor: .top)
                        .opacity(suggestionPhase == .rejecting ? 0 : 1)
                        .blur(radius: suggestionPhase == .rejecting ? 5 : 0)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CaptureLibraryChrome.windowEdgeInset)
            .padding(.trailing, CaptureLibraryChrome.windowEdgeInset)
            .padding(.top, CaptureLibraryChrome.topChromeInset)
            .padding(.bottom, DesignTokens.Spacing.md)
            // Keep suggestion motion on the header only — animating the whole
            // pane made the preview interpolate when the sidebar was resized.
            .animation(suggestionInsertAnimation, value: showsSuggestionRow)
            .animation(.easeInOut(duration: 0.2), value: rowState.isLoading)
            // Isolate header text layout from detail width changes.
            .geometryGroup()

            if rowState.didCompleteWithoutSuggestion, !rowState.isLoading, rowState.suggestion == nil {
                Text("No suggestions — set Project manually, or try Auto Organize again.")
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                    .padding(.horizontal, CaptureLibraryChrome.windowEdgeInset)
                    .padding(.bottom, DesignTokens.Spacing.sm)
                    .transition(.opacity)
            }

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, CaptureLibraryChrome.windowEdgeInset)
                .padding(.bottom, CaptureLibraryChrome.windowEdgeInset)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
        }
        .background(DesignTokens.Color.background.swiftUI)
        .onAppear {
            syncSuggestionPhaseFromRowState()
            loadPreviewIfNeeded()
        }
        .onChange(of: entry.id) { _, _ in
            resetSuggestionAnimationState()
            loadPreviewIfNeeded()
        }
        .onChange(of: rowState.suggestion != nil) { _, hasSuggestion in
            handleSuggestionPresenceChange(hasSuggestion)
        }
        .onReceive(NotificationCenter.default.publisher(for: .captureHistoryDidChange)) { _ in
            // Pick up flattened image after in-preview Cmd+S without clearing the canvas first.
            refreshScreenshotPreview()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            suggestionAnimationTask?.cancel()
            suggestionAnimationTask = nil
        }
    }

    private var autoOrganizeButton: some View {
        Button {
            onAutoOrganize()
        } label: {
            AutoOrganizeButtonLabel(isLoading: rowState.isLoading)
        }
        .buttonStyle(.grabbit)
        .fixedSize()
        .allowsHitTesting(!blocksAutoOrganizeInteraction)
        .help(autoOrganizeHelp)
        .libraryTitlebarInteractive()
    }

    private var autoOrganizeHelp: String {
        if rowState.isLoading { return "Cancel auto-organizing" }
        if rowState.didCompleteWithoutSuggestion {
            return "No suggestions — try again, rename, or set Project manually"
        }
        return "Auto Organize"
    }

    private var committedProjectTag: CaptureTag? {
        displayTags.first(where: { $0.kind == .project })
    }

    private var headerProjectName: String {
        pendingDisplayProject ?? committedProjectTag?.name ?? "None"
    }

    /// Project ▾ / filename …… Auto Organize
    private var committedPathRow: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            committedProjectDropdown

            Text("/")
                .font(.grabbit(.body))
                .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                .accessibilityHidden(true)

            committedNameCell
                .transaction { transaction in
                    if !animatesNameAccept {
                        transaction.animation = nil
                    }
                }

            autoOrganizeButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var committedNameCell: some View {
        let canEditName = !isExistingReadOnly && !rowState.isLoading
        // Soft-control chrome matches TagKindDropdown height/padding (not sidebar’s tight insets).
        Group {
            if isRenaming {
                InlineRenameTextField(
                    text: $renameDraft,
                    textColor: DesignTokens.Color.textPrimary.ns,
                    onSubmit: onCommitRename,
                    onCancel: onCancelRename
                )
            } else if animatesNameAccept {
                SlideUpReplaceSlot(value: displayedName) {
                    Text(displayedName)
                        .font(.grabbit(.caption))
                        .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                InlineStableNameLabel(
                    text: displayedName,
                    textColor: rowState.isLoading
                        ? DesignTokens.Color.textSecondary.ns
                        : (isExistingReadOnly
                            ? DesignTokens.Color.textSecondary.ns
                            : DesignTokens.Color.textPrimary.ns),
                    lineBreakMode: .byTruncatingMiddle,
                    isShimmering: rowState.isLoading,
                    shimmerHighlightColor: DesignTokens.Color.textPrimary.ns
                )
            }
        }
        .padding(.horizontal, CaptureInlineRenameChrome.previewHorizontalPadding)
        .padding(.vertical, CaptureInlineRenameChrome.previewVerticalPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: CaptureLibraryChrome.headerControlHeight,
            alignment: .leading
        )
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(committedNameChromeFill(canEdit: canEditName))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(
                    committedNameChromeStroke(canEdit: canEditName),
                    lineWidth: CaptureInlineRenameChrome.focusLineWidth
                )
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard canEditName, !isRenaming else {
                isNameHovered = false
                return
            }
            isNameHovered = hovering
        }
        .onTapGesture {
            guard canEditName, !isRenaming else { return }
            onBeginRename()
        }
        .pointerStyle(canEditName && !isRenaming ? .link : .default)
        .help(canEditName && !isRenaming ? "Rename" : "")
        .accessibilityLabel(
            rowState.isLoading
                ? "\(displayedName), auto-organizing"
                : displayedName
        )
        .accessibilityAddTraits(canEditName && !isRenaming ? .isButton : [])
        .focusEffectDisabled()
        .transaction { transaction in
            if !animatesNameAccept {
                transaction.animation = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: isNameHovered)
        .animation(.easeOut(duration: 0.12), value: isRenaming)
        .libraryTitlebarInteractive()
    }

    private func committedNameChromeFill(canEdit: Bool) -> Color {
        if isRenaming {
            return Color(nsColor: .textBackgroundColor)
        }
        if canEdit && isNameHovered {
            return DesignTokens.Color.softControlFill.swiftUI
        }
        return Color.clear
    }

    private func committedNameChromeStroke(canEdit: Bool) -> Color {
        if isRenaming {
            return DesignTokens.Color.softControlBorder.swiftUI
        }
        if canEdit && isNameHovered {
            return DesignTokens.Color.softControlBorder.swiftUI
        }
        // Reserve ring width while idle so hover/edit never nudges glyphs.
        return Color.clear
    }

    @ViewBuilder
    private var committedProjectDropdown: some View {
        let project = committedProjectTag
        TagKindDropdown(
            kind: .project,
            selected: headerProjectName,
            options: projectOptions,
            isReadOnly: isExistingReadOnly,
            isLoading: rowState.isLoading,
            slidesSelectionChanges: animatesProjectAccept,
            onRemove: isExistingReadOnly || rowState.isLoading
                ? nil
                : project.map { tag in { onRemoveTag(tag) } },
            onSelect: { name in
                guard !isExistingReadOnly, !rowState.isLoading else { return }
                if let project, name.caseInsensitiveCompare(project.name) == .orderedSame { return }
                onReplaceTag(project ?? CaptureTag(kind: .project, name: name), name)
            },
            onCreateNew: onCreateProject
        )
        .libraryTitlebarInteractive()
    }

    /// Project ▾ / filename …… Suggesting  [✓][✗]
    private var suggestionPathRow: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            if rowState.showsProjectPicker {
                TagKindDropdown(
                    kind: .project,
                    selected: rowState.effectiveProject ?? "None",
                    options: projectOptions,
                    onRemove: rowState.effectiveProject == nil
                        ? nil
                        : onClearProject,
                    onSelect: onSelectProject,
                    onCreateNew: onCreateProject
                )
                .libraryTitlebarInteractive()
            }

            if rowState.showsNameEditor, let name = rowState.effectiveName {
                Text("/")
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                    .accessibilityHidden(true)

                SuggestedNameField(name: name, onCommit: onSelectName)
                    .libraryTitlebarInteractive()
            } else if !rowState.showsProjectPicker {
                Text("No rename suggested")
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            Text("Suggesting")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .fixedSize()

            suggestionDecisionButtons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestionDecisionButtons: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                confirmSuggestion()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.grabbit)
            .fixedSize()
            .disabled(suggestionPhase != .presented)
            .help("Accept rename and project")

            Button {
                rejectSuggestion()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.grabbit)
            .fixedSize()
            .disabled(suggestionPhase != .presented)
            .help("Dismiss suggestion")
        }
        .libraryTitlebarInteractive()
    }

    private func handleSuggestionPresenceChange(_ hasSuggestion: Bool) {
        if hasSuggestion {
            guard suggestionPhase == .idle else { return }
            withAnimation(suggestionInsertAnimation) {
                suggestionPhase = .presented
            }
        } else if suggestionPhase == .presented || suggestionPhase == .rejecting {
            suggestionPhase = .idle
            clearAcceptHandoffState()
        }
    }

    private func syncSuggestionPhaseFromRowState() {
        if rowState.suggestion != nil, suggestionPhase == .idle {
            suggestionPhase = .presented
        }
    }

    private func resetSuggestionAnimationState() {
        suggestionAnimationTask?.cancel()
        suggestionAnimationTask = nil
        suggestionPhase = rowState.suggestion != nil ? .presented : .idle
        clearAcceptHandoffState()
    }

    private func clearAcceptHandoffState() {
        pendingDisplayName = nil
        pendingDisplayProject = nil
        nameWillSlideOnAccept = false
        projectWillSlideOnAccept = false
    }

    private func confirmSuggestion() {
        guard suggestionPhase == .presented else { return }

        let nextName = rowState.showsNameEditor ? rowState.effectiveName : nil
        let nextProject = rowState.showsProjectPicker
            ? (rowState.effectiveProject ?? "None")
            : nil
        let currentProject = committedProjectTag?.name ?? "None"

        let nameChanges = nextName.map {
            $0.caseInsensitiveCompare(entry.displayName) != .orderedSame
        } ?? false
        let projectChanges = nextProject.map {
            $0.caseInsensitiveCompare(currentProject) != .orderedSame
        } ?? false

        nameWillSlideOnAccept = nameChanges
        projectWillSlideOnAccept = projectChanges

        // Dismiss the suggestion row; committed fields still show the prior values.
        withAnimation(suggestionAcceptAnimation) {
            suggestionPhase = .accepting
        }

        suggestionAnimationTask?.cancel()
        suggestionAnimationTask = Task { @MainActor in
            guard !Task.isCancelled else { return }

            if nameChanges || projectChanges {
                // Mount slide slots on the old strings before swapping identities.
                await Task.yield()
                guard !Task.isCancelled else { return }

                withAnimation(suggestionAcceptAnimation) {
                    if nameChanges {
                        pendingDisplayName = nextName
                    }
                    if projectChanges {
                        pendingDisplayProject = nextProject
                    }
                }

                let settleNanos: UInt64 = reduceMotion
                    ? UInt64(DesignMotion.suggestionAcceptReducedDuration * 1_000_000_000)
                    : DesignMotion.suggestionAcceptSettlingNanoseconds
                try? await Task.sleep(nanoseconds: settleNanos)
                guard !Task.isCancelled else { return }
            }

            onAcceptSuggestion()
            clearAcceptHandoffState()
            suggestionPhase = .idle
        }
    }

    private func rejectSuggestion() {
        guard suggestionPhase == .presented else { return }

        withAnimation(suggestionRejectAnimation) {
            suggestionPhase = .rejecting
        }

        suggestionAnimationTask?.cancel()
        suggestionAnimationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            onDismissSuggestion()
            suggestionPhase = .idle
        }
    }

    /// Prefer persisted tags; always surface the folder-derived project when one is missing.
    private var displayTags: [CaptureTag] {
        var tags = entry.tags
        if !tags.contains(where: { $0.kind == .project }),
           let project = CaptureLibraryProject.currentName(for: entry) {
            // Stable synthetic id so ForEach identity doesn't churn.
            tags.insert(CaptureTag(id: entry.id, kind: .project, name: project), at: 0)
        }
        return CaptureTag.sorted(tags)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch entry.item {
        case .screenshot:
            if let fullScreenshot {
                ScreenshotLibraryAnnotationRepresentable(
                    image: fullScreenshot,
                    captureID: entry.id
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    CaptureLibraryAspectFitImage(image: entry.thumbnail)
                        .blur(radius: 2)
                        .opacity(0.55)
                    ProgressView()
                        .controlSize(.regular)
                }
            }

        case .recording(let url, _):
            // Manifest path wins — rename used to leave entry.item pointing at a moved-away file.
            let resolved = CaptureHistory.shared.fileURL(for: entry.id)
                ?? CaptureHistory.shared.storedFileURL(for: entry.id)
                ?? url
            RecordingTimelinePreviewRepresentable(url: resolved)
                .id(resolved.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadPreviewIfNeeded() {
        loadTask?.cancel()
        fullScreenshot = nil

        guard case .screenshot = entry.item else { return }

        let id = entry.id
        loadTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            fullScreenshot = CaptureHistory.shared.fullImage(for: id)
        }
    }

    private func refreshScreenshotPreview() {
        guard case .screenshot = entry.item else { return }
        if let image = CaptureHistory.shared.fullImage(for: entry.id) {
            fullScreenshot = image
        }
    }
}

/// Aspect-fit screenshot preview backed by a CALayer so frame updates during sidebar
/// resize are not implicitly animated (SwiftUI `Image` + `.aspectRatio` lags the pane).
private struct CaptureLibraryAspectFitImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> CaptureLibraryAspectFitImageView {
        let view = CaptureLibraryAspectFitImageView()
        view.setImage(image)
        return view
    }

    func updateNSView(_ nsView: CaptureLibraryAspectFitImageView, context: Context) {
        nsView.setImage(image)
    }
}

private final class CaptureLibraryAspectFitImageView: NSView {
    private let imageLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        imageLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "contents": NSNull()
        ]
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: NSImage) {
        // Prefer a CGImage snapshot so contentsScale / retina stays sharp while resizing.
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            imageLayer.contents = cgImage
        } else {
            imageLayer.contents = image
        }
        imageLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Centered wrapping layout for suggested tag chips in the overlay.
private struct FlowLayoutCentered: Layout {
    var spacing: CGFloat = 8
    var centered: Bool = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        let xOffset = centered ? max(0, (bounds.width - result.size.width) / 2) : 0
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + xOffset + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }

        return (CGSize(width: totalWidth, height: y + rowHeight), frames)
    }
}

