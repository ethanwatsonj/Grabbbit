//
//  RecordingBackgroundPreviewWindow.swift
//  Grabbit
//

import AppKit
@preconcurrency import AVFoundation
import CoreImage
import ScreenCaptureKit

/// Toggleable recording preview: small thumbnail bottom-left, click to expand full stage.
final class RecordingBackgroundPreviewWindow: NSPanel {

    private static var shared: RecordingBackgroundPreviewWindow?

    static var isVisible: Bool { shared?.isVisible ?? false }
    static var isExpanded: Bool { shared?.displayMode == .expanded }

    struct Configuration: Equatable {
        var captureMode: CaptureMode
        var windowID: CGWindowID?
        var appBundleID: String?
        var background: RecordingBackgroundStyle
    }

    private enum DisplayMode {
        case thumbnail
        case expanded
    }

    static func showThumbnail(configuration: Configuration) {
        Task { @MainActor in
            guard CaptureBar.isPresented else {
                hide()
                return
            }
            if let existing = shared, existing.configuration == configuration {
                existing.applyLayout()
                existing.orderFrontRegardless()
                existing.startRefreshing()
                return
            }
            if let existing = shared {
                await existing.teardownCaptures()
                existing.orderOut(nil)
            }
            let window = RecordingBackgroundPreviewWindow(configuration: configuration, displayMode: .thumbnail)
            shared = window
            await window.startCaptures()
            window.orderFrontRegardless()
            window.startRefreshing()
        }
    }

    static func hide() {
        Task { @MainActor in
            if let existing = shared {
                await existing.teardownCaptures()
                existing.orderOut(nil)
            }
            shared = nil
        }
    }

    /// Releases preview capture so RecordingEngine can capture the same window.
    static func transitionToRecording() async {
        await shared?.enterRecordingMode()
    }

    private let configuration: Configuration
    private var displayMode: DisplayMode
    private let contentCapture = RecordingPreviewContentCapture()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let renderQueue = DispatchQueue(label: "com.grabbit.recordingBackgroundPreview", qos: .userInitiated)
    private var refreshTimer: Timer?
    private weak var stageView: RecordingBackgroundStageView?
    private var isInRecordingMode = false

    private let thumbnailWidth: CGFloat = 180
    private let thumbnailInset: CGFloat = 20

    private init(configuration: Configuration, displayMode: DisplayMode) {
        self.configuration = configuration
        self.displayMode = displayMode

        let frame = Self.frame(for: displayMode, thumbnailWidth: thumbnailWidth, inset: thumbnailInset)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = NSWindow.Level(rawValue: Int(NSWindow.Level.popUpMenu.rawValue) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false

        let view = RecordingBackgroundStageView(
            frame: NSRect(origin: .zero, size: frame.size),
            isThumbnail: displayMode == .thumbnail
        )
        view.onClick = { [weak self] in self?.toggleDisplayMode() }
        contentView = view
        stageView = view
    }

    private func startCaptures() async {
        await contentCapture.start(configuration: configuration)
    }

    private func teardownCaptures() async {
        refreshTimer?.invalidate()
        refreshTimer = nil
        await contentCapture.stop()
    }

    private static func frame(for mode: DisplayMode, thumbnailWidth: CGFloat, inset: CGFloat) -> NSRect {
        guard let screen = NSScreen.main else { return .zero }
        let vis = screen.visibleFrame
        switch mode {
        case .thumbnail:
            let height = thumbnailWidth * 9 / 16
            return NSRect(
                x: vis.minX + inset,
                y: vis.minY + inset,
                width: thumbnailWidth,
                height: height
            )
        case .expanded:
            return vis
        }
    }

    private func applyLayout() {
        let frame = Self.frame(for: displayMode, thumbnailWidth: thumbnailWidth, inset: thumbnailInset)
        stageView?.isThumbnail = displayMode == .thumbnail
        setFrame(frame, display: true)
    }

    private func toggleDisplayMode() {
        displayMode = displayMode == .thumbnail ? .expanded : .thumbnail
        applyLayout()
    }

    private func startRefreshing() {
        guard refreshTimer == nil else { return }
        refreshFrame()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshFrame()
            }
        }
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func enterRecordingMode() async {
        isInRecordingMode = true
        stopRefreshing()
        await teardownCaptures()
        if displayMode == .expanded {
            displayMode = .thumbnail
            applyLayout()
        }
    }

    private func refreshFrame() {
        guard !isInRecordingMode else { return }

        let background = configuration.background
        let screenSize = frame.size
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let canvasSize = RecordingBackgroundRenderer.canvasSize(for: scale)
        let contentImage = contentCapture.latestCIImage()
        let isWindowCapture: Bool
        switch configuration.captureMode {
        case .recordWindow, .screenshotWindow: isWindowCapture = true
        default: isWindowCapture = false
        }
        let backgroundIsNone: Bool
        switch background {
        case .none: backgroundIsNone = true
        default: backgroundIsNone = false
        }
        let extent = CGRect(origin: .zero, size: canvasSize)
        var composited: CIImage

        if let contentImage {
            let useCompositeLayout = isWindowCapture && !backgroundIsNone
            if useCompositeLayout {
                composited = RecordingBackgroundRenderer.composite(
                    windowImage: contentImage,
                    background: background,
                    canvasSize: canvasSize,
                    scale: scale
                )
            } else {
                composited = fitImage(contentImage, into: extent)
            }
        } else {
            composited = RecordingBackgroundRenderer.backgroundImage(for: background, extent: extent)
        }

        let renderRect = CGRect(origin: .zero, size: canvasSize)
        let toRender = composited.clampedToExtent().cropped(to: renderRect)

        renderQueue.async { [weak self] in
            guard let self else { return }
            guard let cgImage = self.makeCGImage(from: toRender, size: canvasSize) else { return }
            DispatchQueue.main.async {
                self.stageView?.update(image: cgImage, screenSize: screenSize)
            }
        }
    }

    private func fitImage(_ image: CIImage, into extent: CGRect) -> CIImage {
        let scale = min(extent.width / image.extent.width, extent.height / image.extent.height)
        let scaledW = image.extent.width * scale
        let scaledH = image.extent.height * scale
        let tx = extent.midX - scaledW / 2 - image.extent.minX * scale
        let ty = extent.midY - scaledH / 2 - image.extent.minY * scale
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: tx / scale, y: ty / scale))
            .cropped(to: extent)
    }

    private func makeCGImage(from image: CIImage, size: CGSize) -> CGImage? {
        let bounds = CGRect(origin: .zero, size: size)
        let finite = image.clampedToExtent().cropped(to: bounds)
        if let cgImage = ciContext.createCGImage(finite, from: bounds) {
            return cgImage
        }
        let width = Int(size.width)
        let height = Int(size.height)
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        ciContext.render(
            finite,
            to: buffer,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return ciContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: bounds)
    }
}

// MARK: - Content capture (window or display)

private final class RecordingPreviewContentCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var latestFrame: CVPixelBuffer?
    private let frameQueue = DispatchQueue(label: "com.grabbit.recordingPreviewContentCapture.frames")

    func start(configuration: RecordingBackgroundPreviewWindow.Configuration) async {
        await stop()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)

            let filter: SCContentFilter
            let width: Int
            let height: Int

            switch configuration.captureMode {
            case .recordWindow, .screenshotWindow:
                guard let windowID = configuration.windowID,
                      let window = content.windows.first(where: { $0.windowID == windowID }) else { return }
                filter = SCContentFilter(desktopIndependentWindow: window)
                width = Int(window.frame.width) * scale
                height = Int(window.frame.height) * scale

            case .recordFullScreen:
                let mainID = CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == mainID })
                                 ?? content.displays.first else { return }
                filter = SCContentFilter(display: display, excludingWindows: [])
                width = display.width * scale
                height = display.height * scale

            default:
                return
            }

            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true

            let captureStream = SCStream(filter: filter, configuration: config, delegate: nil)
            try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await captureStream.startCapture()
            stream = captureStream
        } catch {
            #if DEBUG
            print("[RecordingBackgroundPreview] Content capture failed: \(error)")
            #endif
        }
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        frameQueue.sync { latestFrame = nil }
    }

    func latestCIImage() -> CIImage? {
        frameQueue.sync {
            guard let latestFrame else { return nil }
            return CIImage(cvPixelBuffer: latestFrame)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
        frameQueue.sync { latestFrame = pixelBuffer }
    }
}

// MARK: - Stage view

private final class RecordingBackgroundStageView: NSView {
    var onClick: (() -> Void)?
    var isThumbnail: Bool {
        didSet { needsLayout = true }
    }

    private let imageLayer = CALayer()
    private var contentSize = CGSize.zero

    init(frame: NSRect, isThumbnail: Bool) {
        self.isThumbnail = isThumbnail
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard let root = layer else { return }
        if isThumbnail {
            root.cornerRadius = DesignTokens.Radius.lg
            root.masksToBounds = true
            root.borderWidth = 2
            root.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            DesignTokens.Elevation.panelRaised.apply(to: root)
        } else {
            root.cornerRadius = 0
            root.masksToBounds = true
            root.borderWidth = 0
            root.shadowOpacity = 0
        }
        imageLayer.frame = aspectFitFrame(for: contentSize, in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    func update(image: CGImage, screenSize: NSSize) {
        imageLayer.contents = image
        contentSize = CGSize(width: image.width, height: image.height)
        needsLayout = true
    }

    private func aspectFitFrame(for contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else { return bounds }
        let widthRatio = bounds.width / contentSize.width
        let heightRatio = bounds.height / contentSize.height
        let scale = min(widthRatio, heightRatio)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
