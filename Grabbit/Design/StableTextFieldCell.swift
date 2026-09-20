//
//  StableTextFieldCell.swift
//  Grabbit
//
//  NSTextField cell + helpers so idle drawing and the field editor share one
//  text origin. Without this, focus often shifts glyphs left (truncation scroll
//  to caret-at-end, lineFragmentPadding, or cell inset mismatch).
//

import AppKit
import ObjectiveC

/// Shared metrics for idle cell drawing and the AppKit field editor.
enum StableTextFieldMetrics {
    /// Must stay 0 — AppKit's field editor defaults to 5; if we leave that
    /// default while idle draws flush, glyphs jump left on focus. We draw idle
    /// ink flush and lock the editor to the same value.
    static let lineFragmentPadding: CGFloat = 0
}

/// Text field cell whose drawing rect matches the field-editor frame.
final class StableTextFieldCell: NSTextFieldCell {
    /// When set, `drawInterior` paints a Cursor-style sheen without changing metrics.
    var isShimmering = false
    var shimmerHighlightColor: NSColor?
    /// 0…1 cycle phase; advanced by `NSTextField` shimmer timer.
    var shimmerPhase: CGFloat = 0
    /// Set for the whole edit session — `currentEditor()` can lag a turn and
    /// let idle glyphs paint under the field editor (sidebar “growing” text).
    private var isEditingWithFieldEditor = false

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        alignedRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        alignedRect(for: rect)
    }

    /// Avoid NSTextFieldCell’s default title path — it can paint in addition to
    /// our interior draw and read as thickened / ghosted glyphs.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        // Pass the *aligned* rect (same as idle drawing). PR #1 passed full
        // bounds then patched the editor; AppKit still applied the default
        // lineFragmentPadding (5) relative to a different frame, and zeroing it
        // afterward shifted glyphs left of the idle placeholder/string.
        isEditingWithFieldEditor = true
        prepareFieldEditor(textObj)
        super.edit(
            withFrame: alignedRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
        stabilizeFieldEditor(textObj, controlView: controlView, cellBounds: rect)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        isEditingWithFieldEditor = true
        prepareFieldEditor(textObj)
        super.select(
            withFrame: alignedRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
        stabilizeFieldEditor(textObj, controlView: controlView, cellBounds: rect)
    }

    override func endEditing(_ textObj: NSText) {
        isEditingWithFieldEditor = false
        super.endEditing(textObj)
    }

    /// Draw string/placeholder ourselves so idle ink matches the field editor.
    /// AppKit's default interior path does not always honor a custom drawingRect
    /// for placeholders, which left a ~5pt idle inset that vanished on focus.
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // While the field editor is active, skip real string painting so glyphs
        // don't double under the editor (sidebar rename → thick “growing” text).
        // Keep drawing the placeholder for empty fields — otherwise Project
        // blanked on focus.
        if isFieldEditorActive(in: controlView), !stringValue.isEmpty {
            return
        }

        let draw = alignedRect(for: cellFrame)
        let text = stringValue
        if text.isEmpty {
            let basePlaceholderColor = textColor ?? .placeholderTextColor
            let placeholder = placeholderAttributedString
                ?? placeholderString.map {
                    NSAttributedString(string: $0, attributes: textAttributes(color: basePlaceholderColor))
                }
            guard let placeholder else { return }
            drawAttributed(placeholder, in: draw)
            if isShimmering, let highlight = shimmerHighlightColor, let string = placeholderString {
                drawShimmerHighlight(
                    NSAttributedString(string: string, attributes: textAttributes(color: highlight)),
                    in: draw
                )
            }
            return
        }

        let baseColor = textColor ?? .controlTextColor
        drawAttributed(
            NSAttributedString(string: text, attributes: textAttributes(color: baseColor)),
            in: draw
        )
        if isShimmering, let highlight = shimmerHighlightColor {
            drawShimmerHighlight(
                NSAttributedString(string: text, attributes: textAttributes(color: highlight)),
                in: draw
            )
        }
    }

    private func isFieldEditorActive(in controlView: NSView) -> Bool {
        if isEditingWithFieldEditor { return true }
        guard let field = controlView as? NSTextField else { return false }
        if field.currentEditor() != nil { return true }
        // Editor can be installed as a subview a beat before currentEditor wires.
        return field.subviews.contains { $0 is NSTextView }
    }

    /// Flush single-line draw via the same NSLayoutManager path the field
    /// editor uses — NSStringDrawing looked lighter/tighter, so focus jumped
    /// to a wider-spaced NSTextView render.
    private func drawAttributed(_ attributed: NSAttributedString, in draw: NSRect) {
        let width = max(0, draw.width)
        guard width > 0, draw.height > 0, attributed.length > 0 else { return }

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: width, height: draw.height)
        )
        container.lineFragmentPadding = StableTextFieldMetrics.lineFragmentPadding
        container.maximumNumberOfLines = 1
        container.lineBreakMode = lineBreakMode
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let glyphRange = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: draw.origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: draw.origin)
    }

    /// Highlight glyphs under a moving sheen — same geometry as `CursorStyleShimmerText`.
    private func drawShimmerHighlight(_ attributed: NSAttributedString, in draw: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let width = max(draw.width, 1)
        let center = shimmerPhase * 1.6 - 0.3
        let sheenCenter = draw.minX + center * width
        let sheenHalf = 0.45 * width

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // Glyphs only — skip `drawBackground` so destinationIn masks to ink,
        // not a solid run rectangle across the field width.
        drawAttributedGlyphs(attributed, in: draw)
        ctx.setBlendMode(.destinationIn)
        let colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.35).cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.35).cgColor,
            NSColor.clear.cgColor,
        ] as CFArray
        let locations: [CGFloat] = [0, 0.35, 0.5, 0.65, 1]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: sheenCenter - sheenHalf, y: draw.midY),
                end: CGPoint(x: sheenCenter + sheenHalf, y: draw.midY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func drawAttributedGlyphs(_ attributed: NSAttributedString, in draw: NSRect) {
        let width = max(0, draw.width)
        guard width > 0, draw.height > 0, attributed.length > 0 else { return }

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: width, height: draw.height)
        )
        container.lineFragmentPadding = StableTextFieldMetrics.lineFragmentPadding
        container.maximumNumberOfLines = 1
        container.lineBreakMode = lineBreakMode
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let glyphRange = layoutManager.glyphRange(for: container)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: draw.origin)
    }

    private func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        paragraph.alignment = alignment
        return [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: 0
        ]
    }

    private func alignedRect(for rect: NSRect) -> NSRect {
        var result = rect
        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        // Same line height NSTextView uses for this font.
        let textHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        if result.height > textHeight {
            result.origin.y += floor((result.height - textHeight) / 2)
            result.size.height = textHeight
        }
        // No extra horizontal inset — padding is `lineFragmentPadding` only.
        result.origin.x = rect.minX
        result.size.width = rect.width
        return result
    }

    private func prepareFieldEditor(_ textObj: NSText) {
        applyStableInsets(to: textObj)
    }

    private func stabilizeFieldEditor(
        _ textObj: NSText,
        controlView: NSView,
        cellBounds: NSRect
    ) {
        applyStableInsets(to: textObj)
        guard let editor = textObj as? NSTextView else { return }
        positionFieldEditor(editor, in: controlView, cellBounds: cellBounds)

        // Truncated idle fields otherwise scroll to the caret-at-end and the
        // visible glyphs jump left on focus.
        let location = min(editor.selectedRange().location, editor.string.count)
        editor.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    func positionFieldEditor(
        _ editor: NSTextView,
        in controlView: NSView,
        cellBounds: NSRect
    ) {
        let draw = drawingRect(forBounds: cellBounds)
        guard let superview = editor.superview else { return }
        if superview === controlView {
            editor.frame = draw
        } else {
            editor.frame = controlView.convert(draw, to: superview)
        }
        // Keep container width = cell width so edit doesn't reflow wider than idle.
        if let container = editor.textContainer {
            container.size = NSSize(width: max(0, draw.width), height: max(0, draw.height))
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.maximumNumberOfLines = 1
            container.lineBreakMode = lineBreakMode
        }
    }

    func applyStableInsets(to textObj: NSText) {
        guard let editor = textObj as? NSTextView else { return }
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = StableTextFieldMetrics.lineFragmentPadding
        // Shared field editor often carries another control's font / rich-text
        // attrs — lock to this cell so sidebar edit doesn't look larger/looser.
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFontPanel = false
        editor.usesRuler = false
        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let color = textColor ?? .controlTextColor
        editor.font = font
        editor.textColor = color
        let attrs = textAttributes(color: color)
        if let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle {
            editor.defaultParagraphStyle = paragraph
        }
        editor.typingAttributes = attrs
        editor.selectedTextAttributes = [
            .font: font,
            .foregroundColor: color,
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .kern: 0,
            .paragraphStyle: attrs[.paragraphStyle] as Any
        ]
        if let storage = editor.textStorage, storage.length > 0 {
            storage.addAttributes(
                attrs,
                range: NSRange(location: 0, length: storage.length)
            )
        }
    }
}

extension NSTextField {
    /// Install `StableTextFieldCell` and borderless chrome used by inline edits.
    func installStableEditingCell(preservingString: Bool = true) {
        let current = stringValue
        let next = StableTextFieldCell(textCell: preservingString ? current : "")
        next.font = font
        next.textColor = textColor
        next.alignment = alignment
        next.isEditable = isEditable
        next.isSelectable = isSelectable
        next.isScrollable = true
        next.wraps = false
        next.usesSingleLineMode = true
        next.lineBreakMode = .byTruncatingTail
        next.placeholderString = placeholderString
        next.isBordered = false
        next.isBezeled = false
        next.drawsBackground = false
        cell = next

        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        if preservingString {
            stringValue = current
        }
    }

    /// Drive in-cell AO shimmer without swapping the field for a SwiftUI label.
    func updateStableTextShimmer(isActive: Bool, highlightColor: NSColor?) {
        guard let cell = cell as? StableTextFieldCell else { return }
        let wasActive = cell.isShimmering
        cell.shimmerHighlightColor = highlightColor
        cell.isShimmering = isActive
        if isActive {
            if !wasActive {
                startStableShimmerTimer()
            }
        } else if wasActive {
            stopStableShimmerTimer()
            needsDisplay = true
        }
    }

    private static var shimmerTimerKey: UInt8 = 0
    private static let shimmerCycle: TimeInterval = 1.7

    private func startStableShimmerTimer() {
        stopStableShimmerTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self, let cell = self.cell as? StableTextFieldCell, cell.isShimmering else {
                timer.invalidate()
                return
            }
            let t = Date.timeIntervalSinceReferenceDate
            cell.shimmerPhase = CGFloat(
                t.truncatingRemainder(dividingBy: Self.shimmerCycle) / Self.shimmerCycle
            )
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        objc_setAssociatedObject(self, &Self.shimmerTimerKey, timer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func stopStableShimmerTimer() {
        if let timer = objc_getAssociatedObject(self, &Self.shimmerTimerKey) as? Timer {
            timer.invalidate()
        }
        objc_setAssociatedObject(self, &Self.shimmerTimerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// After becoming first responder, keep the visible text origin stable.
    func stabilizeFocusedEditor(selectAll: Bool = false) {
        guard let editor = currentEditor() as? NSTextView else { return }
        guard let cell = cell as? StableTextFieldCell else { return }
        cell.applyStableInsets(to: editor)
        cell.positionFieldEditor(editor, in: self, cellBounds: bounds)

        if selectAll {
            editor.selectAll(nil)
        }
        let location = min(editor.selectedRange().location, editor.string.count)
        editor.scrollRangeToVisible(NSRange(location: location, length: 0))
        // If selection is empty at end of a truncated string, pin to start so
        // the first glyphs stay where the idle label showed them.
        if editor.selectedRange().length == 0,
           editor.string.count > 0,
           lineBreakMode == .byTruncatingTail || lineBreakMode == .byTruncatingMiddle {
            let visible = editor.visibleRect
            if visible.minX > 0.5 {
                editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }
}

/// Shared AppKit field editor that never starts a window drag under
/// `fullSizeContentView`. The system default `NSTextView` returns `true` for
/// `mouseDownCanMoveWindow`, so click-drag to select text moves the window.
final class StableNonMovingFieldEditor: NSTextView {
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isFieldEditor = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isFieldEditor = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Flipped AppKit field so idle `NSLayoutManager` drawing and the field editor
/// share one coordinate space (default `NSTextField` is not flipped).
class StableFlippedTextField: NSTextField {
    override var isFlipped: Bool { true }

    /// Library title chrome + soft controls must never start a window drag under
    /// `fullSizeContentView` (default NSTextField allows it).
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === self || hit is StableNonMovingFieldEditor { return hit }
        // AppKit installs `_NSKeyboardFocusClipView` around the field editor;
        // that private clip view defaults to mouseDownCanMoveWindow=true.
        if hit.mouseDownCanMoveWindow {
            return self
        }
        return hit
    }
}
