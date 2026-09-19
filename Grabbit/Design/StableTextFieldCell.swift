//
//  StableTextFieldCell.swift
//  Grabbit
//
//  NSTextField cell + helpers so idle drawing and the field editor share one
//  text origin. Without this, focus often shifts glyphs left (truncation scroll
//  to caret-at-end, lineFragmentPadding, or cell inset mismatch).
//

import AppKit

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
        // Pass the full cell bounds — AppKit places the editor; we then snap
        // insets/frame to `drawingRect` so idle and editing share an origin.
        super.edit(
            withFrame: rect,
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
        super.select(
            withFrame: rect,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
        stabilizeFieldEditor(textObj, controlView: controlView, cellBounds: rect)
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
        // No horizontal inset — SwiftUI / AppKit parents own leading padding.
        result.origin.x = rect.minX
        result.size.width = rect.width
        return result
    }

    private func stabilizeFieldEditor(
        _ textObj: NSText,
        controlView: NSView,
        cellBounds: NSRect
    ) {
        guard let editor = textObj as? NSTextView else { return }
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0

        let draw = drawingRect(forBounds: cellBounds)
        // Editor is a subview of the control; keep it glued to the draw rect.
        if editor.superview === controlView {
            editor.frame = draw
        }

        // Truncated idle fields otherwise scroll to the caret-at-end and the
        // visible glyphs jump left on focus.
        let location = min(editor.selectedRange().location, editor.string.count)
        editor.scrollRangeToVisible(NSRange(location: location, length: 0))
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
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
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
