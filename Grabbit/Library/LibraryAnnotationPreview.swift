//
//  LibraryAnnotationPreview.swift
//  Grabbit
//
//  In-library screenshot annotation: canvas + floating tool pill over the preview.
//

import AppKit
import SwiftUI

/// Screenshot preview with annotation canvas and toolbar pill (Cmd+S to save).
final class ScreenshotLibraryAnnotationView: NSView {

    private let stageHost = NSView(frame: .zero)
    private let imageView = NSImageView(frame: .zero)
    private let canvas = AnnotationCanvasView(frame: .zero)
    private let pill: ToolbarPillView

    private var screenshot: NSImage?
    private var captureID: UUID?
    private var stageSize: NSSize = .zero
    private var undoRedoKeyMonitor: Any?
    private var saveKeyMonitor: Any?
    private var isSaving = false

    private let toolbarBottomInset: CGFloat = 16

    override init(frame frameRect: NSRect) {
        pill = ToolbarPillView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 44),
            availableTools: AnnotationTool.screenshotTools
        )
        super.init(frame: frameRect)
        wantsLayer = true
        focusRingType = .none
        canvas.focusRingType = .none
        // Let the host window background show through around the image.
        layer?.backgroundColor = NSColor.clear.cgColor

        stageHost.wantsLayer = true
        addSubview(stageHost)

        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        stageHost.addSubview(imageView)
        stageHost.addSubview(canvas)
        addSubview(pill)

        wire()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeKeyMonitors()
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

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard stageSize.width > 0, stageSize.height > 0 else {
            stageHost.frame = .zero
            layoutPill()
            return
        }

        let fit = Self.aspectFitFrame(for: stageSize, in: bounds)
        stageHost.bounds = NSRect(origin: .zero, size: stageSize)
        stageHost.frame = fit
        imageView.frame = stageHost.bounds
        canvas.frame = stageHost.bounds
        updateCanvasStageBackground()
        layoutPill()
    }

    func bind(image: NSImage, captureID: UUID) {
        let sameImage = screenshot === image
        let sameID = self.captureID == captureID
        if sameImage, sameID, stageSize.width > 0 { return }

        self.screenshot = image
        self.captureID = captureID
        stageSize = AnnotationViewBackground.fittedStageSize(image.size)

        imageView.image = image
        imageView.layer?.mask = nil

        if !(sameImage && sameID) {
            canvas.annotations = []
            canvas.currentAnnotation = nil
            canvas.selectedIndex = nil
            canvas.selectedTool = .select
            pill.selectedTool = .select
            pill.hasBeenManuallyRepositioned = false
        }

        updateCanvasStageBackground()
        needsLayout = true
        window?.makeFirstResponder(canvas)
    }

    // MARK: - Layout

    private func layoutPill() {
        pill.dragBounds = bounds
        if pill.hasBeenManuallyRepositioned {
            pill.clampToDragBoundsIfNeeded()
        } else if !pill.isAnimatingAccessoryLayout {
            pill.frame.origin = ToolbarPillView.defaultOrigin(
                pillSize: pill.frame.size,
                in: bounds.size,
                bottomInset: toolbarBottomInset
            )
        }
        addSubview(pill, positioned: .above, relativeTo: nil)
    }

    private static func aspectFitFrame(for contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Wire

    private func wire() {
        canvas.allowedTools = Set(AnnotationTool.screenshotTools)
        canvas.selectedTool = .select
        pill.selectedTool = .select
        pill.selectedColor = NSColor.annotationPalette[0]
        pill.selectedSpotlightDimOpacity = canvas.selectedSpotlightDimOpacity
        pill.selectedSpotlightBlurRadius = canvas.selectedSpotlightBlurRadius
        updateSpotlightCoordinateMapping()
        updateToolbarAccessoryControls()

        canvas.onToolChanged = { [weak self] tool in
            guard let self else { return }
            pill.selectedTool = tool
            updateToolbarAccessoryControls()
        }

        canvas.onEscapeAction = { [weak self] in
            guard let self else { return }
            canvas.selectedTool = .select
            pill.selectedTool = .select
            canvas.selectedIndex = nil
            canvas.needsDisplay = true
            updateToolbarAccessoryControls()
        }

        canvas.onCommittedCropPreviewChanged = { [weak self] cropRect in
            self?.updateCropMask(cropRect)
        }

        canvas.onSelectionChanged = { [weak self] _ in
            self?.updateToolbarAccessoryControls()
        }

        canvas.onSelectionGeometryChanged = { [weak self] in
            guard let self,
                  let settings = canvas.spotlightSettingsForEditing() else { return }
            pill.syncSpotlightOptionsPanelRegion(settings.region)
        }

        canvas.onActiveToolUseChanged = { [weak self] active in
            self?.pill.setCanvasActivelyUsingTool(active)
        }

        canvas.onActiveToolPointerMoved = { [weak self] location in
            self?.pill.handleCanvasToolPointer(at: location)
        }

        pill.onToolSelected = { [weak self] tool in
            guard let self else { return }
            canvas.selectedTool = tool
            pill.selectedTool = tool
            updateToolbarAccessoryControls()
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
            self?.syncSpotlightOptionsPanelFromCanvas()
        }

        pill.onSpotlightOptionsEditingEnded = { [weak self] in
            self?.canvas.commitSpotlightEditUndo()
        }
    }

    private func updateToolbarAccessoryControls() {
        updateSpotlightCoordinateMapping()
        pill.showsSpotlightAccessoryControls = canvas.prefersSpotlightToolbarAccessory()
        pill.showsColorAccessoryControls = canvas.prefersColorToolbarAccessory()
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

    private func syncSpotlightOptionsPanelFromCanvas() {
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

    private func updateSpotlightCoordinateMapping() {
        let contentFrame = NSRect(origin: .zero, size: stageSize)
        let pixelSize = screenshot?.size ?? contentFrame.size
        pill.spotlightImagePixelSize = pixelSize
        pill.mapSpotlightRegionToPanel = { region in
            SpotlightRegionCoordinates.displayRegion(
                region,
                contentFrame: contentFrame,
                imagePixelSize: pixelSize
            )
        }
        pill.mapSpotlightRegionFromPanel = { region in
            SpotlightRegionCoordinates.canvasRegion(
                region,
                contentFrame: contentFrame,
                imagePixelSize: pixelSize
            )
        }
    }

    private func updateCanvasStageBackground() {
        guard let screenshot else {
            canvas.stageBackgroundImage = nil
            return
        }
        let layout = AnnotationViewBackground.stageLayout(for: screenshot.size, background: .none)
        canvas.stageBackgroundImage = AnnotationViewBackground.renderStage(
            screenshot: screenshot,
            layout: layout,
            background: .none
        )
        canvas.needsDisplay = true
    }

    private func updateCropMask(_ cropRect: CGRect?) {
        if let cropRect, cropRect.width > 1, cropRect.height > 1 {
            let mask = CAShapeLayer()
            mask.path = CGPath(rect: cropRect, transform: nil)
            imageView.layer?.mask = mask
        } else {
            imageView.layer?.mask = nil
        }
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
        guard !isSaving, let screenshot, let captureID else { return }
        isSaving = true
        defer { isSaving = false }

        let layout = AnnotationViewBackground.stageLayout(for: screenshot.size, background: .none)
        let stageImage = AnnotationViewBackground.renderStage(
            screenshot: screenshot,
            layout: layout,
            background: .none
        )
        let flattened = canvas.flattenedImage(background: stageImage)
        guard CaptureHistory.shared.replaceScreenshot(id: captureID, with: flattened) else {
            ToastWindow.show(message: "Couldn’t save")
            return
        }

        self.screenshot = flattened
        imageView.image = flattened
        imageView.layer?.mask = nil
        stageSize = AnnotationViewBackground.fittedStageSize(flattened.size)
        canvas.annotations = []
        canvas.currentAnnotation = nil
        canvas.selectedIndex = nil
        canvas.selectedTool = .select
        pill.selectedTool = .select
        updateCanvasStageBackground()
        needsLayout = true

        ToastWindow.show(
            message: "Saved",
            associatedCaptureID: captureID,
            actionTitle: "Show in Finder",
            onAction: {
                guard let fileURL = CaptureHistory.shared.fileURL(for: captureID) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        )
    }
}

struct ScreenshotLibraryAnnotationRepresentable: NSViewRepresentable {
    let image: NSImage
    let captureID: UUID

    func makeNSView(context: Context) -> ScreenshotLibraryAnnotationView {
        let view = ScreenshotLibraryAnnotationView(frame: .zero)
        view.bind(image: image, captureID: captureID)
        return view
    }

    func updateNSView(_ nsView: ScreenshotLibraryAnnotationView, context: Context) {
        nsView.bind(image: image, captureID: captureID)
    }
}
