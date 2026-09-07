//
//  CaptureLibraryWindow.swift
//  Grabbit
//

import SwiftUI
import Combine
import QuartzCore
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
    private var hostingView: NSHostingView<CaptureLibraryView>?
    /// Coalesce titlebar paint so we never mutate chrome mid-layout (AppKit layout-loop crash).
    private var titlebarFillPending = false
    /// System spacing between close → miniaturize / close → zoom, captured once
    /// so repositioning during drag never depends on mid-reset frames.
    private var trafficLightSpacingX: (miniaturize: CGFloat, zoom: CGFloat)?

    static func show() {
        DispatchQueue.main.async {
            if current == nil {
                current = CaptureLibraryWindow()
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
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
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
        let hostingView = NSHostingView(rootView: view)
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
}

/// Hosts SwiftUI edge-to-edge under a transparent titlebar (`fullSizeContentView`).
private final class CaptureLibraryContentContainer: NSView {
    private var hostingView: NSView?
    private var outsideClickMonitor: Any?

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
        needsLayout = true
    }

    func layoutHostingView() {
        guard let hostingView else { return }
        let frame = bounds.integral
        guard !frame.isNull, !frame.isEmpty else { return }
        // Setting an identical frame still dirties layout on some AppKit builds.
        guard !hostingView.frame.equalTo(frame) else { return }
        hostingView.frame = frame
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
        guard let editingView = activeTextEditingView(in: window) else { return }

        let pointInEditor = editingView.convert(event.locationInWindow, from: nil)
        if editingView.bounds.insetBy(dx: -2, dy: -2).contains(pointInEditor) {
            return
        }
        // Field editor lives separately from its NSTextField — keep focus when
        // the click is still on that field's chrome.
        if let textView = window.firstResponder as? NSTextView,
           let field = textView.delegate as? NSTextField {
            let pointInField = field.convert(event.locationInWindow, from: nil)
            if field.bounds.insetBy(dx: -2, dy: -2).contains(pointInField) {
                return
            }
        }

        window.makeFirstResponder(nil)
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
}

// MARK: - Row suggestion state

private struct CaptureRowSuggestionState {
    var isLoading = false
    var suggestion: RenameSuggestion?
    /// User-edited rename; `nil` falls back to `suggestion.suggestedName`.
    var selectedName: String?
    var selectedProject: String?
    var selectedFlow: String?
    var acceptedSnapshot: CaptureLocationSnapshot?
    var wroteMapping = false
    var windowInfo: WindowSignature?

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

    var effectiveFlow: String? {
        if let selectedFlow {
            let trimmed = selectedFlow.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return suggestion?.suggestedFlow
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

    var showsFlowPicker: Bool {
        guard suggestion != nil else { return false }
        if selectedFlow != nil { return true }
        return suggestion?.hasFlow == true
    }
}

@MainActor
fileprivate final class CaptureLibrarySessionState: ObservableObject {
    @Published var rowStates: [UUID: CaptureRowSuggestionState] = [:]
    /// In-window intro modal (first open + DEBUG Settings launcher).
    @Published var showsIntro = false
    var markIntroSeenOnDismiss = true
}

// MARK: - SwiftUI

private enum CaptureLibraryGroupBy: String, CaseIterable, Identifiable {
    case none
    case project
    case flow

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .none: return "None"
        case .project: return "Project"
        case .flow: return "Flow"
        }
    }

    var menuSymbol: String {
        switch self {
        case .none: return "list.bullet"
        case .project: return "folder"
        case .flow: return "arrow.triangle.branch"
        }
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
    /// Soft-control row height in the preview header (`.grabbit` Auto-Tag ≈ 25pt).
    static let headerControlHeight: CGFloat = 25
    /// Top padding for the title + Project/Flow/Auto-Tag row — same as other corners.
    static let topChromeInset = windowEdgeInset
    /// Clears the header / traffic-light band so sidebar chrome sits below it.
    static let belowTrafficLightsTop: CGFloat =
        windowEdgeInset + headerControlHeight + DesignTokens.Spacing.sm
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
    @AppStorage("captureLibrarySidebarWidth") private var persistedSidebarWidth =
        Double(CaptureLibrarySidebarMetrics.columnWidth)
    @State private var sidebarWidth = CaptureLibrarySidebarMetrics.columnWidth
    @State private var selection = Set<UUID>()
    @State private var visibleCount = CaptureLibraryView.initialPageSize
    @State private var renameTarget: CaptureEntry?
    @State private var renameDraft = ""
    @State private var createProjectTarget: UUID?
    @State private var createProjectDraft = ""
    @State private var createFlowTarget: UUID?
    @State private var createFlowDraft = ""
    /// Groups start collapsed; membership means the section is expanded.
    @State private var expandedGroupIDs = Set<String>()
    /// Manual double-click detection so rename does not use TapGesture(count: 2),
    /// which can swallow the first click and leave selection unchanged.
    @State private var lastRowClick: (id: UUID, date: Date)?

    @State private var hoveredCaptureID: UUID?
    @State private var isSidebarResizing = false
    @State private var isSidebarResizeHandleHovered = false

    private static let initialPageSize = 40
    private static let pageSize = 40

    private var groupBy: CaptureLibraryGroupBy {
        CaptureLibraryGroupBy(rawValue: groupByRaw) ?? .none
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
        Array(entries.prefix(visibleCount))
    }

    private var projectGroups: [CaptureLibraryNamedGroup] {
        var grouped: [String: [CaptureEntry]] = [:]
        // Seed with on-disk destination folders so empty projects still appear.
        for name in CaptureLibraryOrganizer.existingProjectNames() {
            grouped[name] = []
        }
        for entry in entries {
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

    private var flowGroups: [CaptureLibraryNamedGroup] {
        namedGroups { entry in
            let flows = entry.tags
                .filter { $0.kind == .flow }
                .map(\.name)
            return flows.isEmpty ? ["None"] : flows
        }
    }

    private func namedGroups(
        namesFor: (CaptureEntry) -> [String]
    ) -> [CaptureLibraryNamedGroup] {
        var grouped: [String: [CaptureEntry]] = [:]
        for entry in entries {
            for name in namesFor(entry) {
                grouped[name, default: []].append(entry)
            }
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
        .alert("Custom Flow", isPresented: createFlowAlertBinding) {
            TextField("Flow name", text: $createFlowDraft)
            Button("Cancel", role: .cancel) {
                createFlowTarget = nil
            }
            Button("Create") {
                if let targetID = createFlowTarget {
                    let name = CaptureTag.normalizeName(createFlowDraft)
                    if !name.isEmpty {
                        if sessionState.rowStates[targetID]?.suggestion != nil {
                            setFlow(name, for: targetID)
                        } else {
                            _ = CaptureHistory.shared.addTag(id: targetID, kind: .flow, name: name)
                        }
                    }
                }
                createFlowTarget = nil
            }
        }
        .onAppear {
            setSidebarWidth(CGFloat(persistedSidebarWidth), persist: false)
            resetVisibleWindow()
            if selection.isEmpty, let first = entries.first {
                selection = [first.id]
            }
        }
        .onChange(of: groupByRaw) { _, _ in
            expandedGroupIDs = []
        }
        .onChange(of: selection) { oldSelection, newSelection in
            // "Organized" is a temporary confirm affordance — dismiss it when
            // the user clicks away to another sidebar item.
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
                ensureSelectionVisible()
                return
            }

            // Active item was removed — stay on the next row down (or up if last).
            if let anchor = oldIDs.first(where: { selection.contains($0) }),
               let oldIndex = oldIDs.firstIndex(of: anchor) {
                if oldIndex + 1 < oldIDs.count, newIDSet.contains(oldIDs[oldIndex + 1]) {
                    selection = [oldIDs[oldIndex + 1]]
                } else if oldIndex > 0, newIDSet.contains(oldIDs[oldIndex - 1]) {
                    selection = [oldIDs[oldIndex - 1]]
                } else if let first = newIDs.first {
                    selection = [first]
                } else {
                    selection = []
                }
            } else if selection.isEmpty, let first = newIDs.first {
                selection = [first]
            } else {
                selection = []
            }
            ensureSelectionVisible()
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
                    groupByPicker
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
                }
                // Leading content inset only — scroll view reaches the divider so the
                // narrow scroller can sit in the trailing gutter, not over row labels.
                .padding(.leading, CaptureLibrarySidebarMetrics.contentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: clampedSidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Color.background.swiftUI)
    }

    private var groupByPicker: some View {
        SoftControlDropdown(
            leadingLabel: "Group by",
            title: groupBy.menuLabel,
            help: "Group captures in the sidebar",
            primaryForeground: DesignTokens.Color.sidebarTextPrimary.swiftUI,
            secondaryForeground: DesignTokens.Color.sidebarTextSecondary.swiftUI
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
    }

    @ViewBuilder
    private var captureList: some View {
        // ScrollView (not List). Leading gutter is on the column; trailing
        // `scrollbarGutter` padding clears row content so the narrow overlay
        // scroller sits against the divider instead of on labels.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch groupBy {
                case .project:
                    groupedCaptureSections(projectGroups)
                case .flow:
                    groupedCaptureSections(flowGroups)
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
            namedGroupHeader(for: group)
                .padding(.vertical, DesignTokens.Spacing.xs)

            if expandedGroupIDs.contains(group.id) {
                ForEach(group.entries) { entry in
                    captureListRow(for: entry, nested: true)
                }
            }
        }
    }

    private func namedGroupHeader(
        for group: CaptureLibraryNamedGroup
    ) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)
        return Button {
            toggleGroupExpanded(group.id)
        } label: {
            HStack(spacing: CaptureLibrarySidebarMetrics.groupIconSpacing) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Color.sidebarTextSecondary.swiftUI)
                    .frame(width: CaptureLibrarySidebarMetrics.disclosureWidth, alignment: .center)

                Text(group.name)
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.sidebarTextPrimary.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
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
                onAutoTag: { requestSuggestions(for: selection) },
                onAcceptSuggestion: { acceptSuggestion(for: $0) },
                onDismissSuggestion: { dismissSuggestion(for: $0) },
                onRevertSuggestion: { revertSuggestion(for: $0) },
                onSelectName: { setSuggestedName($0, for: $1) },
                onSelectProject: { setProject($0, for: $1) },
                onCreateProject: { beginCreateProject(for: $0) },
                onSelectFlow: { setFlow($0, for: $1) },
                onCreateFlow: { beginCreateFlow(for: $0) },
                onClearProject: { clearSuggestedProject(for: $0) },
                onClearFlow: { clearSuggestedFlow(for: $0) },
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
                onAutoTag: { requestSuggestion(for: entry) },
                onAcceptSuggestion: { acceptSuggestion(for: entry) },
                onDismissSuggestion: { dismissSuggestion(for: entry) },
                onSelectName: { setSuggestedName($0, for: entry.id) },
                onSelectProject: { setProject($0, for: entry.id) },
                onCreateProject: { beginCreateProject(for: entry.id) },
                onSelectFlow: { setFlow($0, for: entry.id) },
                onCreateFlow: { beginCreateFlow(for: entry.id) },
                onClearProject: { clearSuggestedProject(for: entry.id) },
                onClearFlow: { clearSuggestedFlow(for: entry.id) },
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
        let isRenaming = renameTarget?.id == entry.id
        let row = CaptureSidebarRow(
            entry: entry,
            rowState: sessionState.rowStates[entry.id] ?? CaptureRowSuggestionState(),
            isRenaming: isRenaming,
            renameDraft: $renameDraft,
            onCommitRename: commitRename,
            onCancelRename: cancelRename,
            onRevertSuggestion: { revertSuggestion(for: entry) }
        )

        // Keep the TextField out of a Button while renaming — otherwise macOS
        // shows an empty edit chrome until a second click focuses the field.
        Group {
            if isRenaming {
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
        .padding(.vertical, DesignTokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            listRowBackground(
                isSelected: selection.contains(entry.id),
                isHovered: hoveredCaptureID == entry.id
            )
        )
        .foregroundStyle(DesignTokens.Color.sidebarTextPrimary.swiftUI)
        .onHover { hovering in
            if hovering {
                hoveredCaptureID = entry.id
            } else if hoveredCaptureID == entry.id {
                hoveredCaptureID = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredCaptureID == entry.id)
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
                beginRename(entry)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                moveToTrash(entry)
            }
        }
    }

    private func handleCaptureRowClick(_ entry: CaptureEntry) {
        let now = Date()
        if let last = lastRowClick,
           last.id == entry.id,
           now.timeIntervalSince(last.date) <= NSEvent.doubleClickInterval {
            lastRowClick = nil
            beginRename(entry)
            return
        }
        lastRowClick = (id: entry.id, date: now)

        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(entry.id) {
                selection.remove(entry.id)
            } else {
                selection.insert(entry.id)
            }
        } else {
            selection = [entry.id]
        }
    }

    private func listRowBackground(isSelected: Bool, isHovered: Bool) -> some View {
        // Hover sits one step below selection (was 0.55 — too light on the sidebar).
        let fillOpacity: CGFloat = isSelected ? 1 : (isHovered ? 0.75 : 0)
        return RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
            .fill(DesignTokens.Color.listSelectionFill.swiftUI.opacity(fillOpacity))
            // 0.5pt each side → 1pt gap between adjacent row backgrounds.
            .padding(.vertical, 0.5)
    }

    private var createProjectAlertBinding: Binding<Bool> {
        Binding(
            get: { createProjectTarget != nil },
            set: { if !$0 { createProjectTarget = nil } }
        )
    }

    private var createFlowAlertBinding: Binding<Bool> {
        Binding(
            get: { createFlowTarget != nil },
            set: { if !$0 { createFlowTarget = nil } }
        )
    }

    private func resetVisibleWindow() {
        visibleCount = min(Self.initialPageSize, max(entries.count, 0))
        ensureSelectionVisible()
    }

    private func ensureSelectionVisible() {
        guard let farthestIndex = entries.indices.reversed().first(where: { selection.contains(entries[$0].id) }) else {
            visibleCount = min(max(visibleCount, Self.initialPageSize), entries.count)
            return
        }
        let needed = farthestIndex + 1
        if needed > visibleCount {
            visibleCount = min(max(needed, Self.initialPageSize), entries.count)
        } else {
            visibleCount = min(max(visibleCount, Self.initialPageSize), entries.count)
        }
    }

    private func loadMoreIfNeeded(_ entry: CaptureEntry) {
        guard let index = visibleEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        let threshold = max(visibleEntries.count - 8, 0)
        guard index >= threshold else { return }
        guard visibleCount < entries.count else { return }
        visibleCount = min(visibleCount + Self.pageSize, entries.count)
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

    private func beginCreateFlow(for id: UUID) {
        createFlowTarget = id
        if let suggested = sessionState.rowStates[id]?.effectiveFlow, !suggested.isEmpty {
            createFlowDraft = suggested
        } else if let entry = entries.first(where: { $0.id == id }) {
            createFlowDraft = entry.tags.first(where: { $0.kind == .flow })?.name ?? ""
        } else {
            createFlowDraft = ""
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

    private func setFlow(_ flow: String, for id: UUID) {
        updateRowState(id) { state in
            state.selectedFlow = flow
        }
    }

    private func clearSuggestedFlow(for id: UUID) {
        updateRowState(id) { state in
            state.selectedFlow = ""
        }
    }

    private func beginRename(_ entry: CaptureEntry) {
        selection = [entry.id]
        // Seed the draft before flipping into edit mode so the field never
        // mounts against an empty string.
        renameDraft = entry.displayName
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
            } else {
                selection = []
            }
        }
        if renameTarget?.id == entry.id {
            renameTarget = nil
        }
        CaptureHistory.shared.remove(id: entry.id)
        sessionState.rowStates.removeValue(forKey: entry.id)
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

    private func updateRowState(_ id: UUID, _ transform: (inout CaptureRowSuggestionState) -> Void) {
        var state = sessionState.rowStates[id] ?? CaptureRowSuggestionState()
        transform(&state)
        sessionState.rowStates[id] = state
    }

    // MARK: - Inline AI suggestion

    private func requestSuggestions(for ids: Set<UUID>) {
        for entry in entries where ids.contains(entry.id) {
            requestSuggestion(for: entry)
        }
    }

    private func requestSuggestion(for entry: CaptureEntry) {
        guard let image = CaptureClassifier.imageForClassification(from: entry) else { return }

        let windowInfo = CaptureOrganizer.windowInfo(for: entry.id)
        updateRowState(entry.id) { state in
            state.isLoading = true
            state.suggestion = nil
            state.selectedName = nil
            state.selectedProject = nil
            state.selectedFlow = nil
            state.acceptedSnapshot = nil
            state.wroteMapping = false
            state.windowInfo = windowInfo
        }

        Task {
            let request = CaptureSuggestionRequest(entry: entry, image: image, windowInfo: windowInfo)
            let suggestion = await CaptureClassifier.suggestRenameAndProject(for: request)
            await MainActor.run {
                updateRowState(entry.id) { state in
                    state.isLoading = false
                    state.suggestion = suggestion
                    state.selectedName = suggestion?.suggestedName
                    state.selectedProject = suggestion?.suggestedProject
                    state.selectedFlow = suggestion?.suggestedFlow
                    state.windowInfo = windowInfo
                }
            }
        }
    }

    private func setSuggestedName(_ name: String, for id: UUID) {
        updateRowState(id) { state in
            state.selectedName = name
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
            suggestedFlow: state.effectiveFlow,
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
            row.selectedName = nil
            row.selectedProject = nil
            row.selectedFlow = nil
            row.isLoading = false
        }
    }

    private func dismissSuggestion(for entry: CaptureEntry) {
        updateRowState(entry.id) { state in
            state.suggestion = nil
            state.selectedName = nil
            state.selectedProject = nil
            state.selectedFlow = nil
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
        sessionState.rowStates.removeValue(forKey: entry.id)
    }

    /// Drops the post-accept "Organized" chrome without undoing the organize.
    private func dismissOrganizedConfirmation(for ids: Set<UUID>) {
        for id in ids {
            guard sessionState.rowStates[id]?.acceptedSnapshot != nil else { continue }
            sessionState.rowStates.removeValue(forKey: id)
        }
    }

}

/// AppKit-backed rename field so the current name is visible immediately and
/// the field becomes first responder without an extra click.
private struct InlineRenameTextField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = RenameNSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.grabbit(.caption)
        field.textColor = DesignTokens.Color.sidebarTextPrimary.ns
        field.placeholderString = "Name"
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.cancel()
        }

        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        if nsView.stringValue != text, nsView.currentEditor() == nil {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onCancel: () -> Void
        private var didFinish = false

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

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
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

private final class RenameNSTextField: NSTextField {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private struct CaptureSidebarRow: View {
    let entry: CaptureEntry
    let rowState: CaptureRowSuggestionState
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onRevertSuggestion: () -> Void

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
        if isRenaming {
            InlineRenameTextField(
                text: $renameDraft,
                onSubmit: onCommitRename,
                onCancel: onCancelRename
            )
            .font(.grabbit(.caption))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                            .stroke(DesignTokens.Color.primary.swiftUI, lineWidth: 1.5)
                    )
            )
        } else {
            Text(entry.displayName)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.sidebarTextPrimary.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var trailingMeta: some View {
        if rowState.acceptedSnapshot != nil {
            HStack(spacing: 4) {
                Text("Organized")
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.sidebarTextPrimary.swiftUI)
                Button(action: onRevertSuggestion) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignTokens.Color.sidebarTextSecondary.swiftUI)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Revert rename and move")
            }
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

/// Idle Auto-Tag label (rabbit + text), or centered hop loader while requesting.
/// Loader is overlaid so its taller frame can't grow the button and nudge the preview.
/// One rabbit view slides from the leading icon slot into the center — no crossfade.
private struct AutoTagButtonLabel: View {
    let isLoading: Bool

    private static let spacing: CGFloat = 6
    private static let idleSize = CGSize(width: 18, height: 18 * 12 / 25)
    private static let loadingSize = RabbitHopLoader.Size.compact.pointSize

    var body: some View {
        HStack(spacing: Self.spacing) {
            Color.clear
                .frame(width: Self.idleSize.width, height: Self.idleSize.height)
            Text("Auto-Tag")
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

private struct CaptureMultiSelectPane: View {
    let entries: [CaptureEntry]
    let rowStates: [UUID: CaptureRowSuggestionState]
    let onAutoTag: () -> Void
    let onAcceptSuggestion: (CaptureEntry) -> Void
    let onDismissSuggestion: (CaptureEntry) -> Void
    let onRevertSuggestion: (CaptureEntry) -> Void
    let onSelectName: (String, UUID) -> Void
    let onSelectProject: (String, UUID) -> Void
    let onCreateProject: (UUID) -> Void
    let onSelectFlow: (String, UUID) -> Void
    let onCreateFlow: (UUID) -> Void
    let onClearProject: (UUID) -> Void
    let onClearFlow: (UUID) -> Void
    let onRemoveTag: (CaptureEntry, CaptureTag) -> Void
    let onReplaceTag: (CaptureEntry, CaptureTag, String) -> Void

    private var isAnyLoading: Bool {
        entries.contains { rowStates[$0.id]?.isLoading == true }
    }

    private var projectOptions: [String] {
        CaptureLibraryOrganizer.existingProjectNames()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(entries.count) selected")
                    .font(.grabbit(.bodyEmphasized))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                Spacer(minLength: 0)
                Button {
                    onAutoTag()
                } label: {
                    AutoTagButtonLabel(isLoading: isAnyLoading)
                }
                .buttonStyle(.grabbit)
                .fixedSize()
                .disabled(entries.isEmpty)
                .allowsHitTesting(!isAnyLoading)
                .help(isAnyLoading ? "Auto-tagging…" : "Auto-Tag")
            }
            .padding(.leading, CaptureLibraryChrome.windowEdgeInset)
            .padding(.trailing, CaptureLibraryChrome.windowEdgeInset)
            .padding(.top, CaptureLibraryChrome.topChromeInset)
            .padding(.bottom, DesignTokens.Spacing.sm)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        multiSelectRow(for: entry)
                        if entry.id != entries.last?.id {
                            Divider()
                                .padding(.leading, 64)
                        }
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.sm)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.Color.background.swiftUI)
        }
    }

    @ViewBuilder
    private func multiSelectRow(for entry: CaptureEntry) -> some View {
        let rowState = rowStates[entry.id] ?? CaptureRowSuggestionState()

        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(nsImage: entry.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                if rowState.showsNameEditor, let name = rowState.effectiveName {
                    SuggestedNameField(name: name) { onSelectName($0, entry.id) }
                } else {
                    Text(entry.displayName)
                        .font(.grabbit(.bodyEmphasized))
                        .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                        .lineLimit(1)
                }

                projectAndTags(for: entry, rowState: rowState)
            }

            Spacer(minLength: 0)

            trailingActions(for: entry, rowState: rowState)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func projectAndTags(for entry: CaptureEntry, rowState: CaptureRowSuggestionState) -> some View {
        let hasSuggestion = rowState.suggestion != nil
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                committedProjectDropdown(for: entry, isReadOnly: hasSuggestion)
                committedFlowDropdown(for: entry, rowState: rowState, isReadOnly: hasSuggestion)
            }

            if hasSuggestion {
                HStack(spacing: DesignTokens.Spacing.sm) {
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
                    if rowState.showsFlowPicker {
                        TagKindDropdown(
                            kind: .flow,
                            selected: rowState.effectiveFlow ?? "None",
                            options: flowOptions(for: entry, rowState: rowState),
                            onRemove: rowState.effectiveFlow == nil
                                ? nil
                                : { onClearFlow(entry.id) },
                            onSelect: { onSelectFlow($0, entry.id) },
                            onCreateNew: { onCreateFlow(entry.id) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func committedProjectDropdown(for entry: CaptureEntry, isReadOnly: Bool) -> some View {
        let project = committedProjectTag(for: entry)
        TagKindDropdown(
            kind: .project,
            selected: project?.name ?? "None",
            options: projectOptions,
            isReadOnly: isReadOnly,
            onRemove: isReadOnly
                ? nil
                : project.map { tag in { onRemoveTag(entry, tag) } },
            onSelect: { name in
                guard !isReadOnly else { return }
                if let project, name.caseInsensitiveCompare(project.name) == .orderedSame { return }
                onReplaceTag(entry, project ?? CaptureTag(kind: .project, name: name), name)
            },
            onCreateNew: { onCreateProject(entry.id) }
        )
    }

    @ViewBuilder
    private func committedFlowDropdown(
        for entry: CaptureEntry,
        rowState: CaptureRowSuggestionState,
        isReadOnly: Bool
    ) -> some View {
        let flow = committedFlowTag(for: entry)
        TagKindDropdown(
            kind: .flow,
            selected: flow?.name ?? "None",
            options: flowOptions(for: entry, rowState: rowState),
            isReadOnly: isReadOnly,
            onRemove: isReadOnly
                ? nil
                : flow.map { tag in { onRemoveTag(entry, tag) } },
            onSelect: { name in
                guard !isReadOnly else { return }
                if let flow, name.caseInsensitiveCompare(flow.name) == .orderedSame { return }
                onReplaceTag(entry, flow ?? CaptureTag(kind: .flow, name: name), name)
            },
            onCreateNew: { onCreateFlow(entry.id) }
        )
    }

    private func committedProjectTag(for entry: CaptureEntry) -> CaptureTag? {
        if let tag = entry.tags.first(where: { $0.kind == .project }) {
            return tag
        }
        guard let project = CaptureLibraryProject.currentName(for: entry) else { return nil }
        return CaptureTag(id: entry.id, kind: .project, name: project)
    }

    private func committedFlowTag(for entry: CaptureEntry) -> CaptureTag? {
        entry.tags.first(where: { $0.kind == .flow })
    }

    private func flowOptions(for entry: CaptureEntry, rowState: CaptureRowSuggestionState) -> [String] {
        var names = Set(CaptureLibraryOrganizer.existingTagNames(kind: .flow))
        if let effective = rowState.effectiveFlow {
            names.insert(effective)
        }
        for tag in entry.tags where tag.kind == .flow {
            names.insert(tag.name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @ViewBuilder
    private func trailingActions(for entry: CaptureEntry, rowState: CaptureRowSuggestionState) -> some View {
        if rowState.isLoading {
            RabbitHopLoader(size: .compact)
                .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                .help("Auto-tagging…")
        } else if rowState.suggestion != nil {
            HStack(spacing: 6) {
                Button {
                    onAcceptSuggestion(entry)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .foregroundStyle(DesignTokens.Color.primary.swiftUI.opacity(0.55))
                .help("Accept suggestion")

                Button {
                    onDismissSuggestion(entry)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .foregroundStyle(DesignTokens.Color.primary.swiftUI.opacity(0.55))
                .help("Dismiss suggestion")
            }
        } else if rowState.acceptedSnapshot != nil {
            Button {
                onRevertSuggestion(entry)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Revert rename and move")
        }
    }
}

private enum AutoTagSuggestionPhase: Equatable {
    case idle
    case presented
    case accepting
    case rejecting
}

private struct CapturePreviewPane: View {
    let entry: CaptureEntry
    @ObservedObject var sessionState: CaptureLibrarySessionState
    let onAutoTag: () -> Void
    let onAcceptSuggestion: () -> Void
    let onDismissSuggestion: () -> Void
    let onSelectName: (String) -> Void
    let onSelectProject: (String) -> Void
    let onCreateProject: () -> Void
    let onSelectFlow: (String) -> Void
    let onCreateFlow: () -> Void
    let onClearProject: () -> Void
    let onClearFlow: () -> Void
    let onRemoveTag: (CaptureTag) -> Void
    let onReplaceTag: (CaptureTag, String) -> Void

    @Namespace private var suggestionNamespace
    @State private var suggestionPhase: AutoTagSuggestionPhase = .idle
    @State private var pendingDisplayProject: String?
    @State private var pendingDisplayFlow: String?
    @State private var fullScreenshot: NSImage?
    @State private var loadTask: Task<Void, Never>?
    @State private var suggestionAnimationTask: Task<Void, Never>?

    private var rowState: CaptureRowSuggestionState {
        sessionState.rowStates[entry.id] ?? CaptureRowSuggestionState()
    }

    private var showsSuggestionRow: Bool {
        rowState.suggestion != nil
            && (suggestionPhase == .presented || suggestionPhase == .rejecting)
    }

    private var isSuggestionBusy: Bool {
        rowState.isLoading
            || suggestionPhase == .presented
            || suggestionPhase == .accepting
            || suggestionPhase == .rejecting
    }

    private var projectOptions: [String] {
        CaptureLibraryOrganizer.existingProjectNames()
    }

    private var flowOptions: [String] {
        var names = Set(CaptureLibraryOrganizer.existingTagNames(kind: .flow))
        if let effective = rowState.effectiveFlow {
            names.insert(effective)
        }
        if let pendingDisplayFlow {
            names.insert(pendingDisplayFlow)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Existing name / project / flow stay visible but non-editable while a suggestion is up.
    private var isExistingReadOnly: Bool {
        suggestionPhase != .idle
    }

    private var suggestionInsertAnimation: Animation {
        .spring(response: 0.38, dampingFraction: 0.86)
    }

    private var suggestionAcceptAnimation: Animation {
        .spring(response: 0.42, dampingFraction: 0.84)
    }

    private var suggestionRejectAnimation: Animation {
        .easeOut(duration: 0.28)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Name | project | flow | Auto-Tag columns — suggestion row
            // mirrors the same columns so rename/project/flow/actions line up.
            Grid(alignment: .leading, horizontalSpacing: DesignTokens.Spacing.sm, verticalSpacing: DesignTokens.Spacing.sm) {
                GridRow(alignment: .center) {
                    Text(entry.displayName)
                        .font(.grabbit(.caption))
                        .foregroundStyle(
                            isExistingReadOnly
                                ? DesignTokens.Color.textSecondary.swiftUI
                                : DesignTokens.Color.textPrimary.swiftUI
                        )
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridCellAnchor(.leading)
                        .transaction { $0.animation = nil }

                    committedProjectDropdown
                    committedFlowDropdown
                    autoTagButton
                        .gridColumnAlignment(.trailing)
                }

                if showsSuggestionRow, rowState.suggestion != nil {
                    GridRow(alignment: .center) {
                        suggestionNameCell
                            .frame(maxWidth: .infinity, alignment: .leading)

                        suggestionProjectCell
                        suggestionFlowCell
                        suggestionDecisionButtons
                            .gridColumnAlignment(.trailing)
                    }
                    .scaleEffect(suggestionPhase == .rejecting ? 0.9 : 1, anchor: .top)
                    .opacity(suggestionPhase == .rejecting ? 0 : 1)
                    .blur(radius: suggestionPhase == .rejecting ? 5 : 0)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .identity
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

    private var autoTagButton: some View {
        Button {
            onAutoTag()
        } label: {
            AutoTagButtonLabel(isLoading: rowState.isLoading)
        }
        .buttonStyle(.grabbit)
        .fixedSize()
        .allowsHitTesting(!isSuggestionBusy)
        .help(rowState.isLoading ? "Auto-tagging…" : "Auto-Tag")
    }

    private var committedProjectTag: CaptureTag? {
        displayTags.first(where: { $0.kind == .project })
    }

    private var committedFlowTag: CaptureTag? {
        displayTags.first(where: { $0.kind == .flow })
    }

    private var headerProjectName: String {
        pendingDisplayProject ?? committedProjectTag?.name ?? "None"
    }

    private var headerFlowName: String {
        pendingDisplayFlow ?? committedFlowTag?.name ?? "None"
    }

    @ViewBuilder
    private var committedProjectDropdown: some View {
        let project = committedProjectTag
        let dropdown = TagKindDropdown(
            kind: .project,
            selected: headerProjectName,
            options: projectOptions,
            isReadOnly: isExistingReadOnly,
            onRemove: isExistingReadOnly
                ? nil
                : project.map { tag in { onRemoveTag(tag) } },
            onSelect: { name in
                guard !isExistingReadOnly else { return }
                if let project, name.caseInsensitiveCompare(project.name) == .orderedSame { return }
                onReplaceTag(project ?? CaptureTag(kind: .project, name: name), name)
            },
            onCreateNew: onCreateProject
        )

        if suggestionPhase == .accepting, pendingDisplayProject != nil {
            dropdown
                .matchedGeometryEffect(id: "autoTag-project", in: suggestionNamespace)
        } else {
            dropdown
        }
    }

    @ViewBuilder
    private var committedFlowDropdown: some View {
        let flow = committedFlowTag
        let dropdown = TagKindDropdown(
            kind: .flow,
            selected: headerFlowName,
            options: flowOptions,
            isReadOnly: isExistingReadOnly,
            onRemove: isExistingReadOnly
                ? nil
                : flow.map { tag in { onRemoveTag(tag) } },
            onSelect: { name in
                guard !isExistingReadOnly else { return }
                if let flow, name.caseInsensitiveCompare(flow.name) == .orderedSame { return }
                onReplaceTag(flow ?? CaptureTag(kind: .flow, name: name), name)
            },
            onCreateNew: onCreateFlow
        )

        if suggestionPhase == .accepting, pendingDisplayFlow != nil {
            dropdown
                .matchedGeometryEffect(id: "autoTag-flow", in: suggestionNamespace)
        } else {
            dropdown
        }
    }

    @ViewBuilder
    private var suggestionNameCell: some View {
        if rowState.showsNameEditor, let name = rowState.effectiveName {
            SuggestedNameField(name: name, onCommit: onSelectName)
        } else if !rowState.showsProjectPicker && !rowState.showsFlowPicker {
            Text("No tags suggested")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
        } else {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var suggestionProjectCell: some View {
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
            .matchedGeometryEffect(id: "autoTag-project", in: suggestionNamespace)
        } else {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var suggestionFlowCell: some View {
        if rowState.showsFlowPicker {
            TagKindDropdown(
                kind: .flow,
                selected: rowState.effectiveFlow ?? "None",
                options: flowOptions,
                onRemove: rowState.effectiveFlow == nil
                    ? nil
                    : onClearFlow,
                onSelect: onSelectFlow,
                onCreateNew: onCreateFlow
            )
            .matchedGeometryEffect(id: "autoTag-flow", in: suggestionNamespace)
        } else {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
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
            .help("Accept suggestion")

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
    }

    private func handleSuggestionPresenceChange(_ hasSuggestion: Bool) {
        if hasSuggestion {
            guard suggestionPhase == .idle else { return }
            withAnimation(suggestionInsertAnimation) {
                suggestionPhase = .presented
            }
        } else if suggestionPhase == .presented || suggestionPhase == .rejecting {
            suggestionPhase = .idle
            pendingDisplayProject = nil
            pendingDisplayFlow = nil
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
        pendingDisplayProject = nil
        pendingDisplayFlow = nil
    }

    private func confirmSuggestion() {
        guard suggestionPhase == .presented else { return }

        pendingDisplayProject = rowState.showsProjectPicker
            ? (rowState.effectiveProject ?? "None")
            : nil
        pendingDisplayFlow = rowState.showsFlowPicker
            ? (rowState.effectiveFlow ?? "None")
            : nil

        withAnimation(suggestionAcceptAnimation) {
            suggestionPhase = .accepting
        }

        suggestionAnimationTask?.cancel()
        suggestionAnimationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            onAcceptSuggestion()
            pendingDisplayProject = nil
            pendingDisplayFlow = nil
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

