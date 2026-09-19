//
//  VideoAnnotationWindow.swift
//  Grabbit
//
//  Created by Ethan Watson on 6/28/26.
//

import AppKit
import AVFoundation

// MARK: - Appearance-aware host

private final class AppearanceAwareView: NSView {
    var onEffectiveAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChanged?()
    }
}

// MARK: - Timeline

final class VideoTimelineView: NSView {

    var videoDuration: Double = 0 {
        didSet { needsDisplay = true }
    }
    var currentTime: Double = 0 {
        didSet { needsDisplay = true }
    }

    var selectionStartTime: Double?
    var selectionVisibleDuration: Double?

    var onSeek: ((Double) -> Void)?
    var onScrubBegan: (() -> Void)?
    var onScrubEnded: (() -> Void)?
    var onSelectionStartChanged: ((Double) -> Void)?
    var onSelectionDurationChanged: ((Double?) -> Void)?

    private enum DragMode {
        case none
        case scrub
        case moveSelection
        case resizeStart
        case resizeEnd
    }

    private var dragMode: DragMode = .none
    private var dragAnchorTime: Double = 0
    private var dragAnchorEndTime: Double = 0
    private var dragStartMouseTime: Double = 0

    private let trackHeight: CGFloat = 8
    private let handleWidth: CGFloat = 6
    private let minDuration: Double = 0.05

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }

    private var hasSelection: Bool { selectionStartTime != nil }

    private var selectionEndTime: Double {
        guard let start = selectionStartTime else { return 0 }
        if let duration = selectionVisibleDuration {
            return min(videoDuration, start + duration)
        }
        return videoDuration
    }

    private func trackRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: 0,
            y: (bounds.height - trackHeight) / 2,
            width: bounds.width,
            height: trackHeight
        )
    }

    private func xForTime(_ time: Double, in track: CGRect) -> CGFloat {
        guard videoDuration > 0 else { return track.minX }
        return track.minX + CGFloat(time / videoDuration) * track.width
    }

    private func timeForX(_ x: CGFloat, in track: CGRect) -> Double {
        guard track.width > 0, videoDuration > 0 else { return 0 }
        let fraction = max(0, min(1, (x - track.minX) / track.width))
        return fraction * videoDuration
    }

    private func selectionRect(in track: CGRect) -> CGRect? {
        guard let start = selectionStartTime, videoDuration > 0 else { return nil }
        let end = selectionEndTime
        let x1 = xForTime(start, in: track)
        let x2 = xForTime(end, in: track)
        return CGRect(x: x1, y: track.minY - 4, width: max(x2 - x1, handleWidth * 2), height: track.height + 8)
    }

    private func hitTestSelection(at point: CGPoint) -> DragMode {
        guard let rect = selectionRect(in: trackRect(in: bounds)), rect.contains(point) else { return .none }

        let leftHandle = CGRect(x: rect.minX, y: rect.minY, width: handleWidth, height: rect.height)
        let rightHandle = CGRect(x: rect.maxX - handleWidth, y: rect.minY, width: handleWidth, height: rect.height)
        let minMoveWidth = handleWidth * 3

        if rect.width >= minMoveWidth {
            if leftHandle.contains(point) { return .resizeStart }
            if rightHandle.contains(point) { return .resizeEnd }
            return .moveSelection
        }

        let fraction = (point.x - rect.minX) / rect.width
        if fraction <= 0.25 { return .resizeStart }
        if fraction >= 0.75 { return .resizeEnd }
        return .moveSelection
    }

    private func edgeHandleRects() -> (left: CGRect, right: CGRect)? {
        guard let rect = selectionRect(in: trackRect(in: bounds)) else { return nil }
        let minMoveWidth = handleWidth * 3
        if rect.width >= minMoveWidth {
            let left = CGRect(x: rect.minX, y: rect.minY, width: handleWidth, height: rect.height)
            let right = CGRect(x: rect.maxX - handleWidth, y: rect.minY, width: handleWidth, height: rect.height)
            return (left, right)
        }
        let edgeWidth = max(rect.width * 0.25, 1)
        let left = CGRect(x: rect.minX, y: rect.minY, width: edgeWidth, height: rect.height)
        let right = CGRect(x: rect.maxX - edgeWidth, y: rect.minY, width: edgeWidth, height: rect.height)
        return (left, right)
    }

    override func resetCursorRects() {
        guard let handles = edgeHandleRects() else { return }
        addCursorRect(handles.left, cursor: .pointingHand)
        addCursorRect(handles.right, cursor: .pointingHand)
    }

    private func invalidateEdgeCursors() {
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect(in: bounds)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Track background
        let trackPath = CGPath(roundedRect: track, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(NSColor.quaternaryLabelColor.cgColor)
        ctx.addPath(trackPath)
        ctx.fillPath()

        // Selected annotation range
        if let rect = selectionRect(in: track) {
            let rangePath = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.setFillColor(NSColor.annotationSelectionAccent.withAlphaComponent(0.35).cgColor)
            ctx.addPath(rangePath)
            ctx.fillPath()
            ctx.setStrokeColor(NSColor.annotationSelectionAccent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(rangePath)
            ctx.strokePath()

            let handleH = rect.height
            for x in [rect.minX, rect.maxX - handleWidth] {
                let handleRect = CGRect(x: x, y: rect.minY, width: handleWidth, height: handleH)
                let handlePath = CGPath(roundedRect: handleRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.addPath(handlePath)
                ctx.fillPath()
                ctx.setStrokeColor(NSColor.annotationSelectionAccent.cgColor)
                ctx.setLineWidth(1)
                ctx.addPath(handlePath)
                ctx.strokePath()
            }
        }

        // Playhead
        guard videoDuration > 0 else { return }
        let playheadX = xForTime(currentTime, in: track)
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: playheadX, y: track.minY - 6))
        ctx.addLine(to: CGPoint(x: playheadX, y: track.maxY + 6))
        ctx.strokePath()

        let dotRect = CGRect(x: playheadX - 4, y: track.maxY + 4, width: 8, height: 8)
        ctx.setFillColor(NSColor.labelColor.cgColor)
        ctx.fillEllipse(in: dotRect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let track = trackRect(in: bounds)

        if hasSelection {
            let hit = hitTestSelection(at: point)
            if hit != .none {
                dragMode = hit
                dragAnchorTime = selectionStartTime ?? 0
                dragAnchorEndTime = selectionEndTime
                dragStartMouseTime = timeForX(point.x, in: track)
                return
            }
        }

        if track.insetBy(dx: 0, dy: -10).contains(point) {
            dragMode = .scrub
            onScrubBegan?()
            let time = timeForX(point.x, in: track)
            currentTime = time
            needsDisplay = true
            onSeek?(time)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let track = trackRect(in: bounds)
        guard videoDuration > 0 else { return }

        switch dragMode {
        case .scrub:
            let time = timeForX(point.x, in: track)
            currentTime = time
            needsDisplay = true
            onSeek?(time)

        case .moveSelection:
            let mouseTime = timeForX(point.x, in: track)
            let delta = mouseTime - dragStartMouseTime
            if selectionVisibleDuration == nil {
                let newStart = max(0, min(dragAnchorTime + delta, videoDuration - minDuration))
                selectionStartTime = newStart
                onSelectionStartChanged?(newStart)
            } else {
                let duration = dragAnchorEndTime - dragAnchorTime
                let maxStart = max(0, videoDuration - duration)
                let newStart = max(0, min(dragAnchorTime + delta, maxStart))
                selectionStartTime = newStart
                onSelectionStartChanged?(newStart)
            }
            needsDisplay = true
            invalidateEdgeCursors()

        case .resizeStart:
            let newStart = max(0, min(timeForX(point.x, in: track), dragAnchorEndTime - minDuration))
            let newDuration = dragAnchorEndTime - newStart
            selectionStartTime = newStart
            selectionVisibleDuration = newDuration
            onSelectionStartChanged?(newStart)
            onSelectionDurationChanged?(newDuration)
            needsDisplay = true
            invalidateEdgeCursors()

        case .resizeEnd:
            let newEnd = max((selectionStartTime ?? 0) + minDuration, min(timeForX(point.x, in: track), videoDuration))
            let start = selectionStartTime ?? 0
            let newDuration = newEnd - start
            selectionVisibleDuration = newDuration
            onSelectionDurationChanged?(newDuration)
            needsDisplay = true
            invalidateEdgeCursors()

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragMode == .scrub {
            onScrubEnded?()
        }
        dragMode = .none
        invalidateEdgeCursors()
    }

    func configureSelection(startTime: Double, visibleDuration: Double?) {
        selectionStartTime = startTime
        selectionVisibleDuration = visibleDuration
        needsDisplay = true
        invalidateEdgeCursors()
    }

    func clearSelection() {
        selectionStartTime = nil
        selectionVisibleDuration = nil
        needsDisplay = true
        invalidateEdgeCursors()
    }
}

// MARK: - Window

final class VideoAnnotationWindow: NSWindow {

    private static var current: VideoAnnotationWindow?

    private let player: AVPlayer
    private let videoURL: URL
    private let playerView: ZoomablePlayerView
    private let canvas: AnnotationCanvasView

    private var pill: ToolbarPillView!
    private var playPauseButton: NSButton!
    private var timeline: VideoTimelineView!
    private var timeLabel: NSTextField!
    private var saveButton: NSButton!
    private var isSaving = false
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserverToken: Any?
    private var undoRedoKeyMonitor: Any?
    private var videoDuration: Double = 0
    private var videoNaturalSize: CGSize = .zero
    private var isScrubbing = false
    private var contentContainer: NSView?
    private var timelineBg: NSView?
    private var rowSep: NSView?

    /// Provisional video stage before the recording's real dimensions are known.
    private let provisionalVideoStage = NSSize(width: 900, height: 536)
    private let timelineRowHeight: CGFloat = 44
    private let toolbarBottomInset: CGFloat = 12
    private let timelineHorizontalInset: CGFloat = 12
    private let playButtonWidth: CGFloat = 32
    private let timeLabelWidth: CGFloat = 98
    private let saveButtonWidth: CGFloat = 206

    // MARK: - Entry Point

    static func show(url: URL, thumbnail: NSImage) {
        DispatchQueue.main.async {
            current = VideoAnnotationWindow(url: url)
            current?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Init

    private init(url: URL) {
        self.videoURL = url
        self.player = AVPlayer(url: url)
        self.playerView = ZoomablePlayerView(player: self.player, frame: .zero)
        self.canvas = AnnotationCanvasView(frame: .zero)

        let windowSize = NSSize(
            width: provisionalVideoStage.width,
            height: provisionalVideoStage.height + timelineRowHeight
        )
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let styleMask: NSWindow.StyleMask = [.titled, .closable]
        let frameRect = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: styleMask
        )
        let centeredFrame = NSRect(
            x: screen.midX - frameRect.width / 2,
            y: screen.midY - frameRect.height / 2,
            width: frameRect.width,
            height: frameRect.height
        )
        let contentRect = NSWindow.contentRect(forFrameRect: centeredFrame, styleMask: styleMask)

        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false

        AnnotationTitlebarStyle.apply(
            to: self,
            title: url.deletingPathExtension().lastPathComponent,
            backgroundColor: .windowBackgroundColor,
            laysContentBelowTitlebar: true,
            usesSystemAppearance: true
        )

        let titleControl = AnnotationTitlebarTitleControl(
            title: url.deletingPathExtension().lastPathComponent,
            foregroundColor: .labelColor,
            showsFileSettingsChrome: false
        )
        AnnotationTitlebarStyle.installCenteredTitle(titleControl, in: self)

        buildLayout(videoStage: provisionalVideoStage)
        wire()
        player.play()
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
        super.setFrame(frameRect, display: displayFlag)
        AnnotationTitlebarStyle.layoutCenteredTitle(in: self)
        if let contentContainer {
            AnnotationTitlebarStyle.layoutContentContainer(
                contentContainer,
                in: self,
                laysContentBelowTitlebar: true
            )
        }
    }

    // MARK: - Layout

    private func contentSize(forVideoStage stage: NSSize) -> NSSize {
        NSSize(width: stage.width, height: stage.height + timelineRowHeight)
    }

    /// Size the player stage to the recording's aspect ratio so AVPlayerLayer doesn't pillarbox.
    private func videoStageSize(for mediaSize: CGSize) -> CGSize {
        var stage = AnnotationViewBackground.fittedStageSize(mediaSize)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let titlebarAllowance: CGFloat = 52
        let maxH = max(200, screen.height - titlebarAllowance - timelineRowHeight)
        let maxW = max(320, screen.width - 24)
        let scale = min(1, maxW / max(stage.width, 1), maxH / max(stage.height, 1))
        if scale < 1 {
            stage = CGSize(
                width: (stage.width * scale).rounded(),
                height: (stage.height * scale).rounded()
            )
        }
        return stage
    }

    private func fitWindowToMediaSize(_ mediaSize: CGSize) {
        let stage = videoStageSize(for: mediaSize)
        let windowSize = contentSize(forVideoStage: stage)
        guard let root = contentContainer else { return }
        if abs(root.bounds.width - windowSize.width) < 1,
           abs(root.bounds.height - windowSize.height) < 1 {
            layoutVideoChrome(videoStage: stage)
            return
        }

        let styleMask = self.styleMask
        let frameRect = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: styleMask
        )
        let screen = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var newFrame = NSRect(
            x: frame.midX - frameRect.width / 2,
            y: frame.midY - frameRect.height / 2,
            width: frameRect.width,
            height: frameRect.height
        )
        newFrame.origin.x = max(screen.minX, min(newFrame.origin.x, screen.maxX - newFrame.width))
        newFrame.origin.y = max(screen.minY, min(newFrame.origin.y, screen.maxY - newFrame.height))

        setFrame(newFrame, display: true)
        layoutVideoChrome(videoStage: stage)
        playerView.canvasSize = canvas.bounds.size
        playerView.updateZoomPreview()
        updateSpotlightCoordinateMapping()
        canvas.needsDisplay = true
    }

    private func buildLayout(videoStage: NSSize) {
        let windowSize = contentSize(forVideoStage: videoStage)

        pill = ToolbarPillView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 44),
            availableTools: AnnotationTool.videoTools
        )

        let shell = AppearanceAwareView(frame: NSRect(origin: .zero, size: windowSize))
        shell.wantsLayer = true
        shell.layer?.backgroundColor = NSColor.clear.cgColor
        shell.autoresizingMask = [.width, .height]
        shell.onEffectiveAppearanceChanged = { [weak self] in
            self?.updateTimelineChromeAppearance()
        }

        let root = NSView(frame: NSRect(origin: .zero, size: windowSize))

        root.addSubview(playerView)
        root.addSubview(canvas)

        let timelineBg = NSView(frame: .zero)
        timelineBg.wantsLayer = true
        root.addSubview(timelineBg)
        self.timelineBg = timelineBg

        let rowSep = NSView(frame: .zero)
        rowSep.wantsLayer = true
        root.addSubview(rowSep)
        self.rowSep = rowSep

        root.addSubview(pill)

        let ppBtn = NSButton(frame: .zero)
        ppBtn.bezelStyle = .regularSquare
        ppBtn.isBordered = false
        ppBtn.imageScaling = .scaleProportionallyDown
        ppBtn.target = self
        ppBtn.action = #selector(togglePlayPause)
        root.addSubview(ppBtn)
        self.playPauseButton = ppBtn
        updatePlayPauseButton(playing: false)

        let tl = VideoTimelineView(frame: .zero)
        root.addSubview(tl)
        self.timeline = tl

        let tLabel = NSTextField(labelWithString: "0:00 / 0:00")
        tLabel.alignment = .right
        tLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tLabel.textColor = .secondaryLabelColor
        root.addSubview(tLabel)
        self.timeLabel = tLabel

        let saveBtn = NSButton(frame: .zero)
        saveBtn.bezelStyle = .rounded
        saveBtn.title = "Save and show in Finder"
        saveBtn.target = self
        saveBtn.action = #selector(saveAndShowInFinder)
        root.addSubview(saveBtn)
        self.saveButton = saveBtn

        shell.addSubview(root)
        contentView = shell
        contentContainer = root

        AnnotationTitlebarStyle.layoutContentContainer(
            root,
            in: self,
            laysContentBelowTitlebar: true
        )
        layoutVideoChrome(videoStage: videoStage)
        makeFirstResponder(canvas)
        updateTimelineChromeAppearance()
    }

    private func layoutVideoChrome(videoStage: NSSize) {
        let rootBounds = contentContainer?.bounds.size ?? contentSize(forVideoStage: videoStage)
        let width = rootBounds.width
        let videoHeight = max(1, rootBounds.height - timelineRowHeight)
        let videoRect = NSRect(
            x: 0,
            y: timelineRowHeight,
            width: width,
            height: videoHeight
        )

        playerView.frame = videoRect
        canvas.frame = videoRect

        timelineBg?.frame = NSRect(x: 0, y: 0, width: width, height: timelineRowHeight)
        rowSep?.frame = NSRect(x: 0, y: timelineRowHeight, width: width, height: 1)

        pill.dragBounds = videoRect
        if pill.hasBeenManuallyRepositioned {
            pill.clampToDragBoundsIfNeeded()
        } else if !pill.isAnimatingAccessoryLayout {
            pill.frame.origin = ToolbarPillView.defaultOrigin(
                pillSize: pill.frame.size,
                in: videoRect.size,
                bottomInset: toolbarBottomInset
            )
            pill.frame.origin.y += timelineRowHeight
        }

        let timelineMidY = timelineRowHeight / 2
        let timelineX = timelineHorizontalInset + playButtonWidth + 8
        let trailingInset = timelineHorizontalInset + saveButtonWidth + 8
        let timelineWidth = width - timelineX - timeLabelWidth - 8 - trailingInset

        playPauseButton?.frame = CGRect(
            x: timelineHorizontalInset,
            y: timelineMidY - 16,
            width: playButtonWidth,
            height: 32
        )
        timeline?.frame = CGRect(
            x: timelineX,
            y: (timelineRowHeight - 28) / 2,
            width: max(40, timelineWidth),
            height: 28
        )
        timeLabel?.frame = CGRect(
            x: width - trailingInset - timeLabelWidth,
            y: (timelineRowHeight - 18) / 2,
            width: timeLabelWidth,
            height: 18
        )
        saveButton?.frame = CGRect(
            x: width - saveButtonWidth - timelineHorizontalInset,
            y: (timelineRowHeight - 30) / 2,
            width: saveButtonWidth,
            height: 30
        )
    }

    private func updateTimelineChromeAppearance() {
        timelineBg?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        rowSep?.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        timeLabel?.textColor = .secondaryLabelColor
        playPauseButton?.contentTintColor = .labelColor
        updatePlayPauseButton(playing: player.timeControlStatus == .playing)
        timeline?.needsDisplay = true
        pill.refreshChromeForHostIfNeeded()
    }

    // MARK: - Wire

    private func updateToolbarAccessoryControls(animated: Bool = true) {
        updateSpotlightCoordinateMapping()
        pill.setAccessoryControls(
            showsSpotlight: canvas.prefersSpotlightToolbarAccessory(),
            showsColor: canvas.prefersColorToolbarAccessory(),
            animated: animated
        )
        pill.spotlightAffectsAllInstances = canvas.appliesSpotlightEffectGlobally
        if let settings = canvas.spotlightSettingsForEditing() {
            pill.selectedSpotlightDimOpacity = AppSettings.snapSpotlightDimOpacity(settings.dimOpacity)
            pill.selectedSpotlightBlurRadius = AppSettings.snapSpotlightBlurRadius(settings.blurRadius)
            pill.spotlightOptionsRegion = settings.region
            canvas.selectedSpotlightDimOpacity = settings.dimOpacity
            canvas.selectedSpotlightBlurRadius = settings.blurRadius
        } else if canvas.selectedTool == .spotlight {
            pill.selectedSpotlightDimOpacity = canvas.selectedSpotlightDimOpacity
            pill.selectedSpotlightBlurRadius = canvas.selectedSpotlightBlurRadius
        }
        syncToolbarPreferencesFromSelection()
    }

    private func syncToolbarPreferencesFromSelection() {
        guard canvas.selectedTool == .select,
              let idx = canvas.selectedIndex,
              canvas.annotations.indices.contains(idx) else { return }

        switch canvas.annotations[idx].content {
        case let .stroke(_, color, _, tool):
            pill.selectedColor = color
            canvas.selectedColor = color
            pill.selectedStrokeTool = tool
            canvas.selectedStrokeTool = tool
        case let .arrow(_, _, _, color, tipStyle, pathStyle, _):
            pill.selectedColor = color
            canvas.selectedColor = color
            pill.selectedArrowTipStyle = tipStyle
            canvas.selectedArrowTipStyle = tipStyle
            pill.selectedArrowPathStyle = pathStyle
            canvas.selectedArrowPathStyle = pathStyle
        case let .rect(_, color):
            pill.selectedColor = color
            canvas.selectedColor = color
        case let .text(_, _, color, _):
            pill.selectedColor = color
            canvas.selectedColor = color
        case let .emoji(_, _, _, color):
            pill.selectedColor = color
            canvas.selectedColor = color
        case .spotlight, .zoom, .crop:
            break
        }
    }

    private func spotlightImageCoordinateContext() -> (contentFrame: CGRect, imagePixelSize: CGSize) {
        let contentFrame = NSRect(origin: .zero, size: canvas.bounds.size)
        let pixelSize = videoNaturalSize.width > 0 && videoNaturalSize.height > 0
            ? videoNaturalSize
            : contentFrame.size
        return (contentFrame, pixelSize)
    }

    private func updateSpotlightCoordinateMapping() {
        let context = spotlightImageCoordinateContext()
        pill.spotlightImagePixelSize = context.imagePixelSize
        pill.mapSpotlightRegionToPanel = { [weak self] region in
            guard let self else { return region }
            let context = self.spotlightImageCoordinateContext()
            return SpotlightRegionCoordinates.displayRegion(
                region,
                contentFrame: context.contentFrame,
                imagePixelSize: context.imagePixelSize
            )
        }
        pill.mapSpotlightRegionFromPanel = { [weak self] region in
            guard let self else { return region }
            let context = self.spotlightImageCoordinateContext()
            return SpotlightRegionCoordinates.canvasRegion(
                region,
                contentFrame: context.contentFrame,
                imagePixelSize: context.imagePixelSize
            )
        }
    }

    private func wire() {
        canvas.videoMode = true
        canvas.allowedTools = Set(AnnotationTool.videoTools)
        canvas.selectedTool = .zoom
        pill.selectedTool = .zoom
        pill.selectedColor = NSColor.annotationPalette[0]
        pill.selectedSpotlightDimOpacity = canvas.selectedSpotlightDimOpacity
        pill.selectedSpotlightBlurRadius = canvas.selectedSpotlightBlurRadius
        updateSpotlightCoordinateMapping()

        playerView.zoomAnnotationsProvider = { [weak self] in
            self?.canvas.annotations ?? []
        }
        playerView.selectedZoomRectProvider = { [weak self] in
            guard let self,
                  let idx = self.canvas.selectedIndex,
                  self.canvas.annotations.indices.contains(idx),
                  case let .zoom(rect) = self.canvas.annotations[idx].content else {
                return nil
            }
            return rect
        }
        playerView.prefersRawVideoForZoomEditing = { [weak self] in
            self?.canvas.prefersRawVideoForZoomEditing ?? false
        }
        playerView.canvasSize = canvas.bounds.size

        canvas.onSelectionChanged = { [weak self] index in
            self?.updateTimelineSelection(for: index)
            self?.updateToolbarAccessoryControls()
            self?.playerView.canvasSize = self?.canvas.bounds.size ?? .zero
            self?.playerView.updateZoomPreview()
        }

        timeline.onSeek = { [weak self] time in
            self?.seekTo(time)
        }

        timeline.onScrubBegan = { [weak self] in
            guard let self else { return }
            self.isScrubbing = true
            self.canvas.isScrubbing = true
            self.canvas.cancelZoomGeometryDrag()
            self.playerView.isScrubbing = true
            self.playerView.setContinuousUpdatesEnabled(true)
        }

        timeline.onScrubEnded = { [weak self] in
            guard let self else { return }
            self.isScrubbing = false
            self.canvas.isScrubbing = false
            self.playerView.isScrubbing = false
            self.playerView.setContinuousUpdatesEnabled(self.player.timeControlStatus == .playing)
            self.playerView.updateZoomPreview()
            self.canvas.needsDisplay = true
        }

        timeline.onSelectionStartChanged = { [weak self] startTime in
            guard let self, let index = canvas.selectedIndex else { return }
            canvas.setStartTime(for: index, seconds: startTime, recordingDuration: videoDuration)
            self.updateTimelineSelection(for: index)
            self.playerView.updateZoomPreview()
        }

        timeline.onSelectionDurationChanged = { [weak self] duration in
            guard let self, let index = canvas.selectedIndex else { return }
            if let duration {
                canvas.setVisibleDuration(for: index, seconds: duration, recordingDuration: videoDuration)
            } else {
                canvas.setForever(for: index, forever: true)
            }
            self.updateTimelineSelection(for: index)
            self.playerView.updateZoomPreview()
        }

        canvas.onWillDraw = { [weak self] in
            self?.pauseForZoomEditingIfNeeded()
        }

        canvas.onTogglePlayback = { [weak self] in
            self?.togglePlayPause()
        }

        canvas.onToolChanged = { [weak self] tool in
            guard let self else { return }
            if tool == .zoom {
                self.pauseForZoomEditingIfNeeded()
            }
            self.pill.selectedTool = tool
            self.updateToolbarAccessoryControls()
            self.playerView.updateZoomPreview()
            self.canvas.needsDisplay = true
        }

        canvas.onSelectionGeometryChanged = { [weak self] in
            guard let self else { return }
            self.playerView.canvasSize = self.canvas.bounds.size
            self.playerView.updateZoomPreview()
            if let settings = self.canvas.spotlightSettingsForEditing() {
                self.pill.syncSpotlightOptionsPanelRegion(settings.region)
            }
        }

        canvas.onEscapeAction = { [weak self] in
            self?.close()
        }

        canvas.onActiveToolUseChanged = { [weak self] active in
            self?.pill.setCanvasActivelyUsingTool(active)
        }

        canvas.onActiveToolPointerMoved = { [weak self] location in
            self?.pill.handleCanvasToolPointer(at: location)
        }

        pill.onToolSelected = { [weak self] tool in
            guard let self else { return }
            if tool == .zoom {
                pauseForZoomEditingIfNeeded()
            }
            canvas.selectedTool = tool
            pill.selectedTool = tool
            updateToolbarAccessoryControls()
            playerView.updateZoomPreview()
            canvas.needsDisplay = true
        }

        pill.onColorSelected = { [weak self] color in
            guard let self else { return }
            canvas.selectedColor = color
            pill.selectedColor = color
            canvas.updateEmojiPickerColor(color)
        }

        pill.onStrokeToolSelected = { [weak self] style in
            guard let self else { return }
            canvas.selectedStrokeTool = style
            pill.selectedStrokeTool = style
        }

        pill.onArrowTipStyleSelected = { [weak self] style in
            guard let self else { return }
            canvas.selectedArrowTipStyle = style
            pill.selectedArrowTipStyle = style
        }

        pill.onArrowPathStyleSelected = { [weak self] style in
            guard let self else { return }
            canvas.selectedArrowPathStyle = style
            pill.selectedArrowPathStyle = style
        }

        pill.onSpotlightDimOpacityChanged = { [weak self] opacity in
            guard let self else { return }
            canvas.applySpotlightDimOpacity(opacity)
            pill.selectedSpotlightDimOpacity = opacity
            canvas.needsDisplay = true
        }

        pill.onSpotlightBlurRadiusChanged = { [weak self] radius in
            guard let self else { return }
            canvas.applySpotlightBlurRadius(radius)
            pill.selectedSpotlightBlurRadius = radius
            canvas.needsDisplay = true
        }

        pill.onSpotlightRegionChanged = { [weak self] region in
            guard let self else { return }
            canvas.applySpotlightRegion(region)
            pill.spotlightOptionsRegion = region
            canvas.needsDisplay = true
        }

        pill.onSpotlightOptionsWillShow = { [weak self] in
            guard let self else { return }
            self.updateSpotlightCoordinateMapping()
            let affectsAll = canvas.appliesSpotlightEffectGlobally
            if let settings = canvas.spotlightSettingsForEditing() {
                pill.syncSpotlightOptionsPanel(
                    dimOpacity: settings.dimOpacity,
                    blurRadius: settings.blurRadius,
                    region: settings.region,
                    affectsAllSpotlights: affectsAll
                )
            } else {
                pill.syncSpotlightOptionsPanel(
                    dimOpacity: canvas.selectedSpotlightDimOpacity,
                    blurRadius: canvas.selectedSpotlightBlurRadius,
                    region: pill.spotlightOptionsRegion,
                    affectsAllSpotlights: affectsAll
                )
            }
        }

        pill.onSpotlightOptionsEditingEnded = { [weak self] in
            self?.canvas.commitSpotlightEditUndo()
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let playing = player.timeControlStatus == .playing
                self.updatePlayPauseButton(playing: playing)
                self.canvas.isPlaybackActive = playing
                self.playerView.isPlaybackActive = playing
                if playing {
                    // Keep zoom selected as read-only during play (solid outline on
                    // the player, no handles / no move-resize). Cancel any in-progress drag.
                    self.canvas.cancelZoomGeometryDrag()
                }
                self.playerView.setContinuousUpdatesEnabled(playing || self.isScrubbing)
                self.playerView.updateZoomPreview()
                self.canvas.needsDisplay = true
            }
        }

        installPlaybackTimeObserver()

        Task { [weak self] in
            guard let self, let asset = self.player.currentItem?.asset else { return }
            async let durationLoad = asset.load(.duration)
            async let tracksLoad = asset.load(.tracks)
            guard let duration = try? await durationLoad,
                  let tracks = try? await tracksLoad,
                  let videoTrack = tracks.first(where: { $0.mediaType == .video }) else { return }
            let naturalSize = try? await videoTrack.load(.naturalSize)
            let preferred = (try? await videoTrack.load(.preferredTransform)) ?? .identity
            let total = CMTimeGetSeconds(duration)
            var mediaSize = CGSize.zero
            if let naturalSize, naturalSize.width > 0, naturalSize.height > 0 {
                let transformed = naturalSize.applying(preferred)
                mediaSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            }
            await MainActor.run {
                guard total.isFinite, total > 0 else { return }
                self.videoDuration = total
                self.timeline.videoDuration = total
                self.canvas.videoDuration = total
                if mediaSize.width > 0, mediaSize.height > 0 {
                    self.videoNaturalSize = mediaSize
                    self.canvas.videoAspectRatio = mediaSize.width / mediaSize.height
                    self.canvas.videoMediaSize = mediaSize
                    self.playerView.mediaSize = mediaSize
                    self.fitWindowToMediaSize(mediaSize)
                    self.playerView.updateZoomPreview()
                    self.updateSpotlightCoordinateMapping()
                }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )

        undoRedoKeyMonitor = installKeyMonitor()
        updateToolbarAccessoryControls(animated: false)
    }

    private func installKeyMonitor() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            if self.canvas.handleUndoRedoKeyEquivalent(event) { return nil }
            if self.shouldTogglePlayback(for: event) {
                self.togglePlayPause()
                return nil
            }
            return event
        }
    }

    private func shouldTogglePlayback(for event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers == " " else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.isEmpty || mods == .shift else { return false }
        if canvas.isEditingText { return false }
        if let resp = firstResponder as? NSTextView, resp.isFieldEditor { return false }
        if firstResponder is NSTextField { return false }
        return true
    }

    private func installPlaybackTimeObserver() {
        guard timeObserverToken == nil else { return }
        let interval = CMTime(value: 1, timescale: 10)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let current = CMTimeGetSeconds(time)
                let total = CMTimeGetSeconds(self.player.currentItem?.duration ?? .zero)
                guard total.isFinite, total > 0 else { return }
                self.videoDuration = total
                self.timeline.videoDuration = total
                self.canvas.videoDuration = total
                self.updatePlaybackTime(current, total: total)
            }
        }
    }

    @objc private func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// Pause and immediately show the full unzoomed frame so zoom selection
    /// is relative to the overall recording, not the currently zoomed view.
    private func pauseForZoomEditingIfNeeded() {
        if player.timeControlStatus == .playing {
            player.pause()
        }
        // Don't wait for KVO — drop the zoom transform right away.
        canvas.isPlaybackActive = false
        playerView.isPlaybackActive = false
        playerView.updateZoomPreview()
        canvas.needsDisplay = true
    }

    private func seekTo(_ seconds: Double) {
        guard let item = player.currentItem else { return }
        let total = CMTimeGetSeconds(item.duration)
        guard total.isFinite, total > 0 else { return }
        let clamped = max(0, min(seconds, total))
        let target = CMTimeMakeWithSeconds(clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        updatePlaybackTime(clamped, total: total)
    }

    private func updatePlaybackTime(_ current: Double, total: Double) {
        canvas.playbackTime = current
        playerView.playbackTime = current
        playerView.canvasSize = canvas.bounds.size
        playerView.updateZoomPreview()
        canvas.needsDisplay = true
        timeline.currentTime = current
        timeLabel.stringValue = "\(Self.formatTime(current)) / \(Self.formatTime(total))"
    }

    // MARK: - Timeline Selection

    private func updateTimelineSelection(for index: Int?) {
        guard let index, canvas.annotations.indices.contains(index) else {
            timeline.clearSelection()
            return
        }
        let placed = canvas.annotations[index]
        timeline.configureSelection(startTime: placed.startTime, visibleDuration: placed.visibleDuration)
    }

    @objc private func playerItemDidEnd() {
        seekTo(0)
    }

    private static func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    override func close() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        playerView.setContinuousUpdatesEnabled(false)
        if let undoRedoKeyMonitor {
            NSEvent.removeMonitor(undoRedoKeyMonitor)
            self.undoRedoKeyMonitor = nil
        }
        super.close()
    }

    private func updatePlayPauseButton(playing: Bool) {
        let symbol = playing ? "pause.fill" : "play.fill"
        let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            .applying(.init(hierarchicalColor: .labelColor))
        playPauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: playing ? "Pause" : "Play")?
            .withSymbolConfiguration(cfg)
    }

    // MARK: - Save

    @objc private func saveAndShowInFinder() {
        guard !isSaving else { return }
        isSaving = true
        saveButton.isEnabled = false
        saveButton.title = "Saving…"

        player.pause()
        player.replaceCurrentItem(with: nil)
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        playerView.setContinuousUpdatesEnabled(false)

        let snapshot = canvas.makeExportSnapshot()
        canvas.isExporting = true

        AnnotatedVideoExporter.export(sourceURL: videoURL, snapshot: snapshot, renderer: canvas) { [weak self] result in
            guard let self else { return }
            self.canvas.isExporting = false
            self.isSaving = false
            self.saveButton.isEnabled = true
            self.saveButton.title = "Save and show in Finder"
            self.player.replaceCurrentItem(with: AVPlayerItem(url: self.videoURL))
            self.installPlaybackTimeObserver()
            self.playerView.setContinuousUpdatesEnabled(self.player.timeControlStatus == .playing)

            switch result {
            case .success(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "Could Not Save Video"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
