//
//  RecordingTimelinePreviewView.swift
//  Grabbit
//
//  Library recording preview with annotation canvas, tool pill, and timeline chrome.
//

import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// Video surface + annotation canvas/toolbar + timeline row (play/pause, scrubber, time).
final class RecordingTimelinePreviewView: NSView {

    /// Preview under `fullSizeContentView`; never start a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    private var player: AVPlayer?
    private var playerView: ZoomablePlayerView?
    private let canvas = AnnotationCanvasView(frame: .zero)
    private let pill: ToolbarPillView
    private let timelineBg = NSView(frame: .zero)
    private let rowSep = NSView(frame: .zero)
    private let playPauseButton = NSButton(frame: .zero)
    private let timeline = VideoTimelineView(frame: .zero)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")

    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var undoRedoKeyMonitor: Any?
    private var saveKeyMonitor: Any?
    private var isScrubbing = false
    private var isSaving = false
    private var videoDuration: Double = 0
    private var videoNaturalSize: CGSize = .zero
    private var lastVideoRectSize: CGSize = .zero
    private var boundURL: URL?

    private let timelineRowHeight: CGFloat = 44
    private let toolbarBottomInset: CGFloat = 12
    private let timelineHorizontalInset: CGFloat = 12
    private let playButtonWidth: CGFloat = 32
    private let timeLabelWidth: CGFloat = 98

    override init(frame frameRect: NSRect) {
        pill = ToolbarPillView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 44),
            availableTools: AnnotationTool.videoTools
        )
        super.init(frame: frameRect)
        wantsLayer = true
        focusRingType = .none
        canvas.focusRingType = .none
        // Let the host window background show through around the video.
        layer?.backgroundColor = NSColor.clear.cgColor

        timelineBg.wantsLayer = true
        addSubview(timelineBg)

        rowSep.wantsLayer = true
        addSubview(rowSep)

        playPauseButton.bezelStyle = .regularSquare
        playPauseButton.isBordered = false
        playPauseButton.imageScaling = .scaleProportionallyDown
        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayPause)
        addSubview(playPauseButton)
        updatePlayPauseButton(playing: false)

        timeline.focusRingType = .none
        addSubview(timeline)

        timeLabel.alignment = .right
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        addSubview(timeLabel)

        addSubview(canvas)
        addSubview(pill)

        timeline.onSeek = { [weak self] time in
            self?.seekTo(time)
        }
        timeline.onScrubBegan = { [weak self] in
            guard let self else { return }
            isScrubbing = true
            canvas.isScrubbing = true
            canvas.cancelZoomGeometryDrag()
            playerView?.isScrubbing = true
            playerView?.setContinuousUpdatesEnabled(true)
        }
        timeline.onScrubEnded = { [weak self] in
            guard let self else { return }
            isScrubbing = false
            canvas.isScrubbing = false
            playerView?.isScrubbing = false
            playerView?.setContinuousUpdatesEnabled(player?.timeControlStatus == .playing)
            playerView?.updateZoomPreview()
            canvas.needsDisplay = true
        }

        wireAnnotationChrome()
        updateChromeAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeKeyMonitors()
        tearDownPlayer()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installKeyMonitors()
            window?.makeFirstResponder(canvas)
        } else {
            removeKeyMonitors()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChromeAppearance()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let width = bounds.width
        let videoHeight = max(1, bounds.height - timelineRowHeight)
        let videoRect = NSRect(x: 0, y: timelineRowHeight, width: width, height: videoHeight)

        if lastVideoRectSize.width > 0, lastVideoRectSize.height > 0,
           lastVideoRectSize != videoRect.size,
           !canvas.annotations.isEmpty {
            canvas.remapAnnotations(
                fromContent: NSRect(origin: .zero, size: lastVideoRectSize),
                toContent: NSRect(origin: .zero, size: videoRect.size)
            )
        }
        lastVideoRectSize = videoRect.size

        playerView?.frame = videoRect
        canvas.frame = videoRect
        playerView?.canvasSize = videoRect.size
        playerView?.updateZoomPreview()

        timelineBg.frame = NSRect(x: 0, y: 0, width: width, height: timelineRowHeight)
        rowSep.frame = NSRect(x: 0, y: timelineRowHeight, width: width, height: 1)

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
        addSubview(pill, positioned: .above, relativeTo: nil)

        let timelineMidY = timelineRowHeight / 2
        let timelineX = timelineHorizontalInset + playButtonWidth + 8
        let trailingInset = timelineHorizontalInset
        let timelineWidth = width - timelineX - timeLabelWidth - 8 - trailingInset

        playPauseButton.frame = CGRect(
            x: timelineHorizontalInset,
            y: timelineMidY - 16,
            width: playButtonWidth,
            height: 32
        )
        timeline.frame = CGRect(
            x: timelineX,
            y: (timelineRowHeight - 28) / 2,
            width: max(40, timelineWidth),
            height: 28
        )
        timeLabel.frame = CGRect(
            x: width - trailingInset - timeLabelWidth,
            y: (timelineRowHeight - 18) / 2,
            width: timeLabelWidth,
            height: 18
        )

        updateSpotlightCoordinateMapping()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.isEmpty || mods == .shift {
                togglePlayPause()
                return
            }
        }
        super.keyDown(with: event)
    }

    func bind(url: URL) {
        let standardized = url.standardizedFileURL
        guard boundURL != standardized else { return }
        boundURL = standardized

        tearDownPlayer()
        canvas.annotations = []
        canvas.currentAnnotation = nil
        canvas.selectedIndex = nil
        canvas.selectedTool = .zoom
        pill.selectedTool = .zoom
        pill.hasBeenManuallyRepositioned = false
        lastVideoRectSize = .zero
        videoNaturalSize = .zero
        canvas.videoMediaSize = .zero
        canvas.videoAspectRatio = 0

        updateToolbarAccessoryControls(animated: false)

        if FileManager.default.isUbiquitousItem(at: standardized) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: standardized)
        }

        let player = AVPlayer(url: standardized)
        self.player = player

        let playerView = ZoomablePlayerView(player: player, frame: .zero)
        playerView.zoomAnnotationsProvider = { [weak self] in
            self?.canvas.annotations ?? []
        }
        playerView.selectedZoomRectProvider = { [weak self] in
            guard let self,
                  let idx = canvas.selectedIndex,
                  canvas.annotations.indices.contains(idx),
                  case let .zoom(rect) = canvas.annotations[idx].content else {
                return nil
            }
            return rect
        }
        playerView.prefersRawVideoForZoomEditing = { [weak self] in
            self?.canvas.prefersRawVideoForZoomEditing ?? false
        }
        self.playerView = playerView
        addSubview(playerView, positioned: .below, relativeTo: canvas)

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let playing = player.timeControlStatus == .playing
                self.updatePlayPauseButton(playing: playing)
                self.canvas.isPlaybackActive = playing
                playerView.isPlaybackActive = playing
                if playing {
                    self.canvas.cancelZoomGeometryDrag()
                }
                playerView.setContinuousUpdatesEnabled(playing || self.isScrubbing)
                playerView.updateZoomPreview()
                self.canvas.needsDisplay = true
            }
        }

        installPlaybackTimeObserver()
        loadMediaMetadata(from: player)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.seekTo(0)
        }

        updatePlaybackTime(0, total: 0)
        updatePlayPauseButton(playing: false)
        needsLayout = true
        window?.makeFirstResponder(canvas)
    }

    // MARK: - Annotation chrome

    private func wireAnnotationChrome() {
        canvas.videoMode = true
        canvas.allowedTools = Set(AnnotationTool.videoTools)
        canvas.selectedTool = .zoom
        pill.selectedTool = .zoom
        pill.selectedColor = NSColor.annotationPalette[0]
        pill.selectedSpotlightDimOpacity = canvas.selectedSpotlightDimOpacity
        pill.selectedSpotlightBlurRadius = canvas.selectedSpotlightBlurRadius

        canvas.onSelectionChanged = { [weak self] index in
            guard let self else { return }
            updateTimelineSelection(for: index)
            updateToolbarAccessoryControls()
            playerView?.canvasSize = canvas.bounds.size
            playerView?.updateZoomPreview()
        }

        timeline.onSelectionStartChanged = { [weak self] startTime in
            guard let self, let index = canvas.selectedIndex else { return }
            canvas.setStartTime(for: index, seconds: startTime, recordingDuration: videoDuration)
            updateTimelineSelection(for: index)
            playerView?.updateZoomPreview()
        }

        timeline.onSelectionDurationChanged = { [weak self] duration in
            guard let self, let index = canvas.selectedIndex else { return }
            if let duration {
                canvas.setVisibleDuration(for: index, seconds: duration, recordingDuration: videoDuration)
            } else {
                canvas.setForever(for: index, forever: true)
            }
            updateTimelineSelection(for: index)
            playerView?.updateZoomPreview()
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
                pauseForZoomEditingIfNeeded()
            }
            pill.selectedTool = tool
            updateToolbarAccessoryControls()
            playerView?.updateZoomPreview()
            canvas.needsDisplay = true
        }

        canvas.onSelectionGeometryChanged = { [weak self] in
            guard let self else { return }
            playerView?.canvasSize = canvas.bounds.size
            playerView?.updateZoomPreview()
            if let settings = canvas.spotlightSettingsForEditing() {
                pill.syncSpotlightOptionsPanelRegion(settings.region)
            }
        }

        canvas.onEscapeAction = { [weak self] in
            guard let self else { return }
            canvas.selectedTool = .select
            pill.selectedTool = .select
            canvas.selectedIndex = nil
            canvas.needsDisplay = true
            updateToolbarAccessoryControls()
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
            playerView?.updateZoomPreview()
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
            updateSpotlightCoordinateMapping()
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

        updateToolbarAccessoryControls(animated: false)
    }

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

    private func updateSpotlightCoordinateMapping() {
        let contentFrame = NSRect(origin: .zero, size: canvas.bounds.size)
        let pixelSize = videoNaturalSize.width > 0 && videoNaturalSize.height > 0
            ? videoNaturalSize
            : contentFrame.size
        pill.spotlightImagePixelSize = pixelSize
        pill.mapSpotlightRegionToPanel = { [weak self] region in
            guard let self else { return region }
            let frame = NSRect(origin: .zero, size: canvas.bounds.size)
            let size = videoNaturalSize.width > 0 ? videoNaturalSize : frame.size
            return SpotlightRegionCoordinates.displayRegion(
                region,
                contentFrame: frame,
                imagePixelSize: size
            )
        }
        pill.mapSpotlightRegionFromPanel = { [weak self] region in
            guard let self else { return region }
            let frame = NSRect(origin: .zero, size: canvas.bounds.size)
            let size = videoNaturalSize.width > 0 ? videoNaturalSize : frame.size
            return SpotlightRegionCoordinates.canvasRegion(
                region,
                contentFrame: frame,
                imagePixelSize: size
            )
        }
    }

    // MARK: - Player

    private func tearDownPlayer() {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        timeControlObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        playerView?.setContinuousUpdatesEnabled(false)
        playerView?.removeFromSuperview()
        playerView = nil
        player?.pause()
        player = nil
        videoDuration = 0
        timeline.videoDuration = 0
        timeline.currentTime = 0
        timeline.clearSelection()
        canvas.videoDuration = 0
        canvas.playbackTime = 0
        canvas.isPlaybackActive = false
        canvas.isScrubbing = false
    }

    private func installPlaybackTimeObserver() {
        guard let player, timeObserverToken == nil else { return }
        let interval = CMTime(value: 1, timescale: 10)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let current = CMTimeGetSeconds(time)
                let total = CMTimeGetSeconds(self.player?.currentItem?.duration ?? .zero)
                guard total.isFinite, total > 0 else { return }
                self.videoDuration = total
                self.timeline.videoDuration = total
                self.canvas.videoDuration = total
                self.updatePlaybackTime(current, total: total)
            }
        }
    }

    private func loadMediaMetadata(from player: AVPlayer) {
        Task { [weak self] in
            guard let asset = player.currentItem?.asset else { return }
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
                guard let self, total.isFinite, total > 0 else { return }
                self.videoDuration = total
                self.timeline.videoDuration = total
                self.canvas.videoDuration = total
                if mediaSize.width > 0, mediaSize.height > 0 {
                    self.videoNaturalSize = mediaSize
                    self.canvas.videoAspectRatio = mediaSize.width / mediaSize.height
                    self.canvas.videoMediaSize = mediaSize
                    self.playerView?.mediaSize = mediaSize
                    self.playerView?.updateZoomPreview()
                    self.updateSpotlightCoordinateMapping()
                }
                self.updatePlaybackTime(
                    CMTimeGetSeconds(player.currentTime()),
                    total: total
                )
            }
        }
    }

    @objc private func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    private func pauseForZoomEditingIfNeeded() {
        if player?.timeControlStatus == .playing {
            player?.pause()
        }
        canvas.isPlaybackActive = false
        playerView?.isPlaybackActive = false
        playerView?.updateZoomPreview()
        canvas.needsDisplay = true
    }

    private func seekTo(_ seconds: Double) {
        guard let player, let item = player.currentItem else { return }
        let total = videoDuration > 0 ? videoDuration : CMTimeGetSeconds(item.duration)
        guard total.isFinite, total > 0 else { return }
        let clamped = max(0, min(seconds, total))
        let target = CMTimeMakeWithSeconds(clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        updatePlaybackTime(clamped, total: total)
    }

    private func updatePlaybackTime(_ current: Double, total: Double) {
        canvas.playbackTime = current
        playerView?.playbackTime = current
        playerView?.canvasSize = canvas.bounds.size
        playerView?.updateZoomPreview()
        canvas.needsDisplay = true
        timeline.currentTime = current
        let displayTotal = total > 0 ? total : videoDuration
        timeLabel.stringValue = "\(Self.formatTime(current)) / \(Self.formatTime(displayTotal))"
    }

    private func updateTimelineSelection(for index: Int?) {
        guard let index, canvas.annotations.indices.contains(index) else {
            timeline.clearSelection()
            return
        }
        let placed = canvas.annotations[index]
        timeline.configureSelection(startTime: placed.startTime, visibleDuration: placed.visibleDuration)
    }

    private func updatePlayPauseButton(playing: Bool) {
        let symbol = playing ? "pause.fill" : "play.fill"
        let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            .applying(.init(hierarchicalColor: .labelColor))
        playPauseButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: playing ? "Pause" : "Play"
        )?.withSymbolConfiguration(cfg)
        playPauseButton.contentTintColor = .labelColor
    }

    private func updateChromeAppearance() {
        // Timeline chrome follows system appearance; stage uses the window background.
        let fill = DesignTokens.Color.background.ns.cgColor
        timelineBg.layer?.backgroundColor = fill
        rowSep.layer?.backgroundColor = NSColor.clear.cgColor
        timeLabel.textColor = .secondaryLabelColor
        playPauseButton.contentTintColor = .labelColor
        timeline.needsDisplay = true
        pill.refreshChromeForHostIfNeeded()
    }

    // MARK: - Keys / Save

    private func installKeyMonitors() {
        removeKeyMonitors()
        guard let window else { return }
        undoRedoKeyMonitor = canvas.installUndoRedoKeyMonitor(for: window)
        saveKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "s" else { return event }
            if self.canvas.isEditingText { return event }
            if let resp = window.firstResponder as? NSView,
               !(resp === self.canvas || resp.isDescendant(of: self)) {
                return event
            }
            if window.firstResponder is NSTextView || window.firstResponder is NSTextField {
                return event
            }
            self.performSave()
            return nil
        }
    }

    private func removeKeyMonitors() {
        if let undoRedoKeyMonitor {
            NSEvent.removeMonitor(undoRedoKeyMonitor)
            self.undoRedoKeyMonitor = nil
        }
        if let saveKeyMonitor {
            NSEvent.removeMonitor(saveKeyMonitor)
            self.saveKeyMonitor = nil
        }
    }

    private func performSave() {
        guard !isSaving, let videoURL = boundURL, let player else { return }
        isSaving = true
        ToastWindow.show(message: "Saving…")

        player.pause()
        player.replaceCurrentItem(with: nil)
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        playerView?.setContinuousUpdatesEnabled(false)

        let snapshot = canvas.makeExportSnapshot()
        canvas.isExporting = true

        AnnotatedVideoExporter.export(sourceURL: videoURL, snapshot: snapshot, renderer: canvas) { [weak self] result in
            guard let self else { return }
            canvas.isExporting = false
            isSaving = false
            player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
            installPlaybackTimeObserver()
            playerView?.setContinuousUpdatesEnabled(player.timeControlStatus == .playing)

            switch result {
            case .success(let url):
                ToastWindow.show(message: "Saved")
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

    private static func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct RecordingTimelinePreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> RecordingTimelinePreviewView {
        let view = RecordingTimelinePreviewView(frame: .zero)
        view.bind(url: url)
        return view
    }

    func updateNSView(_ nsView: RecordingTimelinePreviewView, context: Context) {
        nsView.bind(url: url)
    }
}
