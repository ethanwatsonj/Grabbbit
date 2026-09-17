//
//  ZoomablePlayerView.swift
//  Grabbit
//

import AppKit
import AVFoundation
import QuartzCore

final class ZoomablePlayerView: NSView {

    let player: AVPlayer
    /// Transform parent for video only — read-only selection stays fixed in view space.
    private let zoomContainer = CALayer()
    private let playerLayer = AVPlayerLayer()
    private let selectionBorderLayer = CAShapeLayer()
    private var updateTimer: Timer?

    var zoomAnnotationsProvider: () -> [PlacedAnnotation] = { [] }
    /// Selected zoom rect in canvas space, if any. During play/scrub this region is drawn
    /// as a faded, non-interactive outline for the whole video (not only while zoomed).
    var selectedZoomRectProvider: () -> CGRect? = { nil }
    /// When true, paused preview skips settled zoom so the region can be edited on the raw frame.
    var prefersRawVideoForZoomEditing: () -> Bool = { false }
    var playbackTime: Double = 0
    var canvasSize: CGSize = .zero
    /// Real recording pixel size (orientation-corrected). The editor window is sized to match
    /// this aspect so the player fills edge-to-edge; mediaSize still drives zoom math when
    /// the window and recording diverge for any reason.
    var mediaSize: CGSize = .zero
    var isPlaybackActive: Bool = false
    var isScrubbing: Bool = false

    init(player: AVPlayer, frame: NSRect) {
        self.player = player
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        zoomContainer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(zoomContainer)

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        zoomContainer.addSublayer(playerLayer)

        // Fixed in view space (not inside zoomContainer) so the outline stays visible
        // as a reference even while the video is fully zoomed.
        selectionBorderLayer.fillColor = nil
        selectionBorderLayer.strokeColor = Self.readOnlySelectionStroke.cgColor
        selectionBorderLayer.lineWidth = 1.5
        selectionBorderLayer.lineDashPattern = nil
        selectionBorderLayer.opacity = 0
        selectionBorderLayer.isHidden = true
        layer?.addSublayer(selectionBorderLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        stopContinuousUpdates()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomContainer.bounds = CGRect(origin: .zero, size: bounds.size)
        zoomContainer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        playerLayer.frame = zoomContainer.bounds
        selectionBorderLayer.frame = bounds
        updateZoomPreview()
        CATransaction.commit()
    }

    func setContinuousUpdatesEnabled(_ enabled: Bool) {
        if enabled {
            startContinuousUpdates()
        } else {
            stopContinuousUpdates()
        }
    }

    private func startContinuousUpdates() {
        guard updateTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.displayTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    private func stopContinuousUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func displayTick() {
        guard isPlaybackActive || isScrubbing else { return }
        let time = CMTimeGetSeconds(player.currentTime())
        guard time.isFinite else { return }
        playbackTime = time
        updateZoomPreview()
    }

    func updateZoomPreview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard canvasSize.width > 0, canvasSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            zoomContainer.transform = CATransform3DIdentity
            hideSelectionBorder()
            return
        }

        let editingRaw = prefersRawVideoForZoomEditing()
        let annotations = zoomAnnotationsProvider()
        let viewSize = bounds.size
        let effectiveMediaSize: CGSize? = (mediaSize.width > 0 && mediaSize.height > 0) ? mediaSize : nil

        let zoom = ZoomEffect.transform(
            at: playbackTime,
            from: annotations,
            outputSize: viewSize,
            canvasSize: canvasSize.width > 0 ? canvasSize : viewSize,
            mediaSize: effectiveMediaSize,
            settleTransitions: !(isPlaybackActive || isScrubbing || editingRaw)
        )

        if editingRaw {
            zoomContainer.transform = CATransform3DIdentity
            hideSelectionBorder()
            return
        }

        zoomContainer.transform = ZoomEffect.layerTransform(zoom, viewSize: viewSize)
        updateSelectionBorder(mediaSize: effectiveMediaSize)
    }

    /// Greyer, lightly faded selection blue — visual reference only during play/scrub.
    private static let readOnlySelectionStroke: NSColor = {
        let accent = NSColor.annotationSelectionAccent
        let grey = NSColor(calibratedWhite: 0.55, alpha: 1)
        let muted = accent.blended(withFraction: 0.45, of: grey) ?? accent
        return muted.withAlphaComponent(0.45)
    }()

    /// Fixed read-only outline of the selected zoom for the entire play/scrub session.
    private func updateSelectionBorder(mediaSize: CGSize?) {
        guard isPlaybackActive || isScrubbing else {
            hideSelectionBorder()
            return
        }

        // Only while a zoom is selected — never as an unsolicited guide.
        guard let selectedRect = selectedZoomRectProvider() else {
            hideSelectionBorder()
            return
        }

        guard let viewRect = ZoomEffect.selectionRect(
            zoomRect: selectedRect,
            outputSize: bounds.size,
            canvasSize: canvasSize.width > 0 ? canvasSize : bounds.size,
            mediaSize: mediaSize
        ) else {
            hideSelectionBorder()
            return
        }

        selectionBorderLayer.strokeColor = Self.readOnlySelectionStroke.cgColor
        selectionBorderLayer.path = CGPath(rect: viewRect, transform: nil)
        selectionBorderLayer.opacity = 1
        selectionBorderLayer.isHidden = false
    }

    private func hideSelectionBorder() {
        selectionBorderLayer.isHidden = true
        selectionBorderLayer.opacity = 0
        selectionBorderLayer.path = nil
    }
}
