//
//  StableTextFieldCell.swift
//  Grabbit
//
//  NSTextField cell + helpers so idle drawing and the field editor share one
//  text origin. Without this, focus often shifts glyphs left (truncation scroll
//  to caret-at-end, lineFragmentPadding, or cell inset mismatch).
//

import AppKit

/// Shared metrics for idle cell drawing and the AppKit field editor.
enum StableTextFieldMetrics {
    /// Must stay 0 — AppKit's field editor defaults to 5; if we leave that
    /// default while idle draws flush, glyphs jump left on focus. We draw idle
    /// ink flush and lock the editor to the same value.
    static let lineFragmentPadding: CGFloat = 0
}

/// Text field cell whose drawing rect matches the field-editor frame.
final class StableTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        alignedRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        alignedRect(for: rect)
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

    /// Draw string/placeholder ourselves so idle ink matches the field editor.
    /// AppKit's default interior path does not always honor a custom drawingRect
    /// for placeholders, which left a ~5pt idle inset that vanished on focus.
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let draw = alignedRect(for: cellFrame)
        let text = stringValue
        if text.isEmpty {
            let placeholder = placeholderAttributedString
                ?? placeholderString.map {
                    NSAttributedString(string: $0, attributes: textAttributes(color: .placeholderTextColor))
                }
            guard let placeholder else { return }
            drawAttributed(placeholder, in: draw)
            return
        }

        drawAttributed(
            NSAttributedString(
                string: text,
                attributes: textAttributes(color: textColor ?? .controlTextColor)
            ),
            in: draw
        )
    }

    private func drawAttributed(_ attributed: NSAttributedString, in draw: NSRect) {
        var origin = draw.origin
        origin.x += StableTextFieldMetrics.lineFragmentPadding
        let size = NSSize(
            width: max(0, draw.width - StableTextFieldMetrics.lineFragmentPadding),
            height: draw.height
        )
        attributed.draw(
            with: NSRect(origin: origin, size: size),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    private func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        paragraph.alignment = alignment
        return [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    private func alignedRect(for rect: NSRect) -> NSRect {
        var result = rect
        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        // Match NSTextView layout height for the same font (ascender − descender).
        let textHeight = ceil(font.ascender) - floor(font.descender)
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

        let draw = drawingRect(forBounds: cellBounds)
        // Editor is usually a subview of the control; keep it glued to the draw rect.
        if editor.superview === controlView {
            editor.frame = draw
        }

        // Truncated idle fields otherwise scroll to the caret-at-end and the
        // visible glyphs jump left on focus.
        let location = min(editor.selectedRange().location, editor.string.count)
        editor.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    fileprivate func applyStableInsets(to textObj: NSText) {
        guard let editor = textObj as? NSTextView else { return }
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = StableTextFieldMetrics.lineFragmentPadding
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

    /// After becoming first responder, keep the visible text origin stable.
    func stabilizeFocusedEditor(selectAll: Bool = false) {
        guard let editor = currentEditor() as? NSTextView else { return }
        (cell as? StableTextFieldCell)?.applyStableInsets(to: editor)
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = StableTextFieldMetrics.lineFragmentPadding

        // Re-glue editor frame to the cell drawing rect (superview-relative).
        if editor.superview === self {
            editor.frame = (cell as? StableTextFieldCell)?
                .drawingRect(forBounds: bounds) ?? bounds
        }

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
