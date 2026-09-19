//
//  AnnotationWindow.swift
//  Grabbit
//
//  Created by Ethan Watson on 6/27/26.
//

import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - Enums

enum StrokeTool: Equatable, CaseIterable {
    case marker, highlighter

    var lineWidth: CGFloat {
        switch self {
        case .marker:      return 4
        case .highlighter: return 14
        }
    }

    var menuSymbol: String {
        switch self {
        case .marker:      return "scribble"
        case .highlighter: return "highlighter"
        }
    }

    var menuSymbolPointSize: CGFloat { 14 }

    var accessibilityLabel: String {
        switch self {
        case .marker:      return "Marker"
        case .highlighter: return "Highlighter"
        }
    }
}

enum AnnotationTool: Hashable {
    case select, draw, arrow, rect, spotlight, zoom, crop, text, emoji

    /// Preferred spotlight glyph needs SF Symbols 7 (macOS 26+); fall back on older systems.
    private static let spotlightSfSymbol: String = {
        let preferred = "squareshape.on.pattern.diagonalline"
        if NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil {
            return preferred
        }
        return "squareshape.dotted.squareshape"
    }()

    static let screenshotTools: [AnnotationTool] = [
        .select, .spotlight, .crop, .text, .emoji
    ]
    static let videoTools: [AnnotationTool] = [
        .select, .zoom, .text
    ]

    var sfSymbol: String {
        switch self {
        case .select:    return "cursorarrow"
        case .draw:      return "scribble"
        case .arrow:     return "arrow.up.right"
        case .rect:      return "rectangle"
        case .spotlight: return Self.spotlightSfSymbol
        case .zoom:      return "plus.magnifyingglass"
        case .crop:      return "crop"
        case .text:      return "textformat"
        case .emoji:     return "face.smiling"
        }
    }

    var displayName: String {
        switch self {
        case .select:    return "Select"
        case .draw:      return "Draw"
        case .arrow:     return "Arrow"
        case .rect:      return "Rectangle"
        case .spotlight: return "Spotlight"
        case .zoom:      return "Zoom"
        case .crop:      return "Crop"
        case .text:      return "Text"
        case .emoji:     return "Sticker"
        }
    }

    var shortcutKey: String {
        switch self {
        case .select:    return "S"
        case .draw:      return "D"
        case .arrow:     return "A"
        case .rect:      return "R"
        case .spotlight: return "F"
        case .zoom:      return "Z"
        case .crop:      return "C"
        case .text:      return "T"
        case .emoji:     return "E"
        }
    }
}

enum ArrowTipStyle: Equatable, CaseIterable {
    case solid, dot

    var menuSymbol: String {
        switch self {
        case .solid: return "arrow.up.right"
        case .dot:   return "circle.fill"
        }
    }

    var menuSymbolPointSize: CGFloat {
        switch self {
        case .solid: return 14
        case .dot:   return 5
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .solid: return "Solid arrow"
        case .dot:   return "Dot arrow"
        }
    }
}

enum ArrowPathStyle: Equatable, CaseIterable {
    case autoBend, squiggle

    var menuSymbol: String {
        switch self {
        case .autoBend: return "arrow.turn.up.right"
        case .squiggle: return "scribble.variable"
        }
    }

    var menuSymbolPointSize: CGFloat {
        switch self {
        case .autoBend: return 13
        case .squiggle: return 13
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .autoBend: return "Auto bend"
        case .squiggle: return "Squiggle"
        }
    }
}

enum Annotation {
    /// Hard-edge rounded-rect cutout for spotlight; not user-exposed in v1.
    static let spotlightCornerRadius: CGFloat = 8

    case stroke(points: [CGPoint], color: NSColor, lineWidth: CGFloat, tool: StrokeTool)
    case arrow(from: CGPoint, to: CGPoint, bend: CGPoint?, color: NSColor, tipStyle: ArrowTipStyle, pathStyle: ArrowPathStyle, seed: UInt64)
    case rect(rect: CGRect, color: NSColor)
    case spotlight(region: CGRect, dimOpacity: CGFloat, blurRadius: CGFloat)
    case zoom(rect: CGRect)
    case crop(rect: CGRect)
    case text(origin: CGPoint, text: String, color: NSColor, maxWidth: CGFloat?)
    case emoji(center: CGPoint, emoji: String, size: CGFloat, color: NSColor)
}

struct PlacedAnnotation {
    var content: Annotation
    /// Video timeline position when the annotation appears.
    var startTime: Double = 0
    /// Seconds visible after `startTime`. `nil` = forever.
    var visibleDuration: Double? = nil

    func isVisible(at time: Double) -> Bool {
        guard time >= startTime else { return false }
        guard let duration = visibleDuration else { return true }
        return time <= startTime + duration
    }
}

struct AnnotationExportSnapshot {
    let annotations: [PlacedAnnotation]
    let canvasSize: CGSize
}

// MARK: - Color Palette

extension NSColor {
    /// Selection outline for annotations in select mode (solid blue, Figma-style handles).
    static var annotationSelectionAccent: NSColor { DesignTokens.Color.primary.ns }
    /// Region capture overlay border and handles.
    static var regionSelectionAccent: NSColor { DesignTokens.Color.regionSelectionAccent.ns }

    static var annotationPalette: [NSColor] { DesignTokens.Color.annotationPaletteNS }

    convenience init(hex24: UInt32) {
        self.init(
            calibratedRed:   CGFloat((hex24 >> 16) & 0xFF) / 255,
            green:           CGFloat((hex24 >>  8) & 0xFF) / 255,
            blue:            CGFloat( hex24         & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Perceived luminance via Rec. 601 coefficients.
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (usingColorSpace(.sRGB) ?? self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
    }

    var rgb24Value: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (usingColorSpace(.sRGB) ?? self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt32((r * 255).rounded()) << 16)
             | (UInt32((g * 255).rounded()) << 8)
             |  UInt32((b * 255).rounded())
    }

    var hexString: String {
        String(format: "%06X", rgb24Value)
    }

    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(hex24: value)
    }

    static func paletteIndex(matching color: NSColor) -> Int? {
        let value = color.rgb24Value
        return annotationPalette.firstIndex { $0.rgb24Value == value }
    }

    /// Two-step darker shade for selection rings (palette-500 → palette-700).
    func darkenedPaletteSteps(_ steps: Int = 2) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        if s < 0.08 {
            let factor = pow(0.82, CGFloat(steps))
            return NSColor(calibratedWhite: max(0.12, b * factor), alpha: a)
        }

        let brightnessFactor = pow(0.80, CGFloat(steps))
        let saturationBoost = 1 + 0.08 * CGFloat(steps)
        return NSColor(
            calibratedHue: h,
            saturation: min(1, s * saturationBoost),
            brightness: max(0.15, b * brightnessFactor),
            alpha: a
        )
    }
}

// MARK: - Sticker Symbol Rendering

private enum StickerStyle {
    static let outlineWidth: CGFloat = 6
}

private func drawStickerSymbol(
    base: NSImage,
    in symRect: NSRect,
    pointSize: CGFloat,
    color: NSColor
) {
    let outline = StickerStyle.outlineWidth
    let outlineCfg = NSImage.SymbolConfiguration(pointSize: pointSize + outline * 2, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let outlineImg = base.withSymbolConfiguration(outlineCfg) {
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setShadow(
                offset: .zero,
                blur: 3,
                color: NSColor.white.withAlphaComponent(0.75).cgColor
            )
            outlineImg.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx.restoreGState()
        }
        outlineImg.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    let fillCfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    if let fillImg = base.withSymbolConfiguration(fillCfg) {
        fillImg.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}

private func stickerSymbolImage(symbolName: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
    guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
    let pad = StickerStyle.outlineWidth + 3
    let canvas = pointSize + pad * 2
    let size = NSSize(width: canvas, height: canvas)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }
    let symRect = NSRect(x: pad, y: pad, width: pointSize, height: pointSize)
    drawStickerSymbol(base: base, in: symRect, pointSize: pointSize, color: color)
    return image
}

// MARK: - Path Helpers

func smoothPath(from points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard !points.isEmpty else { return path }

    if points.count == 1 {
        let p = points[0]
        path.addEllipse(in: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3))
        return path
    }

    if points.count == 2 {
        path.move(to: points[0])
        path.addLine(to: points[1])
        return path
    }

    // Midpoint quadratic Bézier: control = raw point, end = midpoint between this and next.
    path.move(to: points[0])
    for i in 0 ..< points.count - 1 {
        let mid = CGPoint(
            x: (points[i].x + points[i + 1].x) / 2,
            y: (points[i].y + points[i + 1].y) / 2
        )
        path.addQuadCurve(to: mid, control: points[i])
    }
    path.addLine(to: points[points.count - 1])
    return path
}

private struct ArrowLayout {
    let angle: CGFloat
    let headLen: CGFloat
    let headAngle: CGFloat
    let baseCenter: CGPoint
    let wingLeft: CGPoint
    let wingRight: CGPoint
}

private func arrowLayout(from start: CGPoint, to end: CGPoint) -> ArrowLayout? {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let len = hypot(dx, dy)
    guard len > 4 else { return nil }

    let angle = atan2(dy, dx)
    let headLen = min(16, len * 0.35)
    let headAngle: CGFloat = .pi / 6
    let cosA = cos(angle)
    let sinA = sin(angle)

    return ArrowLayout(
        angle: angle,
        headLen: headLen,
        headAngle: headAngle,
        baseCenter: CGPoint(
            x: end.x - headLen * cos(headAngle) * cosA,
            y: end.y - headLen * cos(headAngle) * sinA
        ),
        wingLeft: CGPoint(
            x: end.x - headLen * cos(angle - headAngle),
            y: end.y - headLen * sin(angle - headAngle)
        ),
        wingRight: CGPoint(
            x: end.x - headLen * cos(angle + headAngle),
            y: end.y - headLen * sin(angle + headAngle)
        )
    )
}

private struct ArrowPaths {
    var stroke: CGPath
    var fill: CGPath?
}

/// Radius of the dot drawn at the arrow tip (8px diameter).
private let arrowDotRadius: CGFloat = 4

/// Soft corner radius at an elbow bend (~8pt, clamped per segment).
private let arrowBendCornerRadius: CGFloat = 8

/// Minimum axis offset before an auto elbow is introduced (already straight-ish otherwise).
private let arrowAutoBendThreshold: CGFloat = 8

/// Collapses duplicate and axis-colinear points so L-elbows and straight runs stay clean.
private func collapseArrowWaypoints(_ points: [CGPoint]) -> [CGPoint] {
    guard let first = points.first else { return [] }
    var result = [first]
    for point in points.dropFirst() {
        guard let last = result.last else { continue }
        if hypot(point.x - last.x, point.y - last.y) < 0.5 { continue }
        if result.count >= 2 {
            let prior = result[result.count - 2]
            let colinearH = abs(prior.y - last.y) < 0.5 && abs(last.y - point.y) < 0.5
            let colinearV = abs(prior.x - last.x) < 0.5 && abs(last.x - point.x) < 0.5
            if colinearH || colinearV {
                result[result.count - 1] = point
                continue
            }
        }
        result.append(point)
    }
    return result
}

/// FigJam-style orthogonal route through a free control point.
/// Hidden corners sit on either side of `bend`; every joint is 90°.
/// Orientation is locked to the start–end box (wider → leave start horizontally) so
/// dragging the handle does not flip the route.
/// Horizontal-first: `start → (bend.x, start.y) → bend → (end.x, bend.y) → end`
/// Vertical-first:   `start → (start.x, bend.y) → bend → (bend.x, end.y) → end`
private func arrowWaypoints(from start: CGPoint, to end: CGPoint, bend: CGPoint?) -> [CGPoint] {
    guard let bend else { return [start, end] }
    let leaveHorizontally = abs(end.x - start.x) >= abs(end.y - start.y)
    let corners: [CGPoint]
    if leaveHorizontally {
        corners = [
            CGPoint(x: bend.x, y: start.y),
            bend,
            CGPoint(x: end.x, y: bend.y),
        ]
    } else {
        corners = [
            CGPoint(x: start.x, y: bend.y),
            bend,
            CGPoint(x: bend.x, y: end.y),
        ]
    }
    return collapseArrowWaypoints([start] + corners + [end])
}

/// Bend handle is the free control point (or the shaft midpoint when straight).
private func arrowBendHandle(from start: CGPoint, to end: CGPoint, bend: CGPoint?) -> CGPoint {
    bend ?? CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
}

/// Default control at the start–end midpoint when both axes have meaningful offset.
private func autoArrowBend(from start: CGPoint, to end: CGPoint) -> CGPoint? {
    let dx = abs(end.x - start.x)
    let dy = abs(end.y - start.y)
    guard dx >= arrowAutoBendThreshold, dy >= arrowAutoBendThreshold else { return nil }
    return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
}

/// Placement / live preview: free-angle endpoints; auto orthogonal route unless Shift keeps it straight.
private func arrowPlacementBend(from start: CGPoint, to end: CGPoint, forceStraight: Bool, pathStyle: ArrowPathStyle) -> CGPoint? {
    guard pathStyle == .autoBend else { return nil }
    return forceStraight ? nil : autoArrowBend(from: start, to: end)
}

/// Endpoint edit: Shift clears the bend (straight); otherwise keep the free control or auto-create one.
private func arrowEditBend(from start: CGPoint, to end: CGPoint, existing: CGPoint?, forceStraight: Bool, pathStyle: ArrowPathStyle) -> CGPoint? {
    guard pathStyle == .autoBend else { return nil }
    if forceStraight { return nil }
    if let existing { return existing }
    return autoArrowBend(from: start, to: end)
}

/// Tiny seeded PRNG so squiggles stay stable while endpoints move.
private struct ArrowSquiggleRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xC0FFEE : seed
    }

    mutating func nextUnit() -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return CGFloat(state % 10_000) / 9_999
    }

    mutating func nextSigned() -> CGFloat {
        nextUnit() * 2 - 1
    }
}

/// Organic but clean polyline between endpoints (seeded, ends pinned).
private func arrowSquigglePoints(from start: CGPoint, to end: CGPoint, seed: UInt64) -> [CGPoint] {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let len = hypot(dx, dy)
    guard len > 4 else { return [start, end] }

    let ux = dx / len
    let uy = dy / len
    let px = -uy
    let py = ux

    let interiorCount = max(3, min(7, Int(len / 70)))
    let amplitude = min(32, max(12, len * 0.14))

    var rng = ArrowSquiggleRNG(seed: seed)
    var walk: CGFloat = 0
    var points = [start]

    for i in 1 ... interiorCount {
        let t = CGFloat(i) / CGFloat(interiorCount + 1)
        let envelope = sin(t * .pi)
        // Correlated walk keeps the curve smooth rather than noisy.
        walk = walk * 0.55 + rng.nextSigned() * 0.45
        let offset = walk * amplitude * envelope
        let tJitter = rng.nextSigned() * 0.06 * (1 / CGFloat(interiorCount + 1))
        let tt = min(0.97, max(0.03, t + tJitter))
        let base = CGPoint(x: start.x + dx * tt, y: start.y + dy * tt)
        points.append(CGPoint(x: base.x + px * offset, y: base.y + py * offset))
    }
    points.append(end)
    return points
}

/// Shaft sample points for hit-testing / bounds (orthogonal waypoints or squiggle polyline).
private func arrowShaftPoints(
    from start: CGPoint,
    to end: CGPoint,
    bend: CGPoint?,
    pathStyle: ArrowPathStyle,
    seed: UInt64
) -> [CGPoint] {
    switch pathStyle {
    case .autoBend:
        return arrowWaypoints(from: start, to: end, bend: bend)
    case .squiggle:
        return arrowSquigglePoints(from: start, to: end, seed: seed)
    }
}

/// Appends an orthogonal shaft through `points`, rounding each interior joint.
private func appendOrthogonalArrowShaft(to path: CGMutablePath, points: [CGPoint]) {
    guard let first = points.first else { return }
    path.move(to: first)
    guard points.count >= 2 else { return }
    if points.count == 2 {
        path.addLine(to: points[1])
        return
    }
    for i in 1 ..< points.count - 1 {
        let prev = points[i - 1]
        let corner = points[i]
        let next = points[i + 1]
        let segIn = hypot(corner.x - prev.x, corner.y - prev.y)
        let segOut = hypot(next.x - corner.x, next.y - corner.y)
        let radius = min(arrowBendCornerRadius, segIn / 2, segOut / 2)
        if radius > 0.5 {
            path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
        } else {
            path.addLine(to: corner)
        }
    }
    path.addLine(to: points[points.count - 1])
}

private func appendArrowShaft(
    to path: CGMutablePath,
    from start: CGPoint,
    bend: CGPoint?,
    to end: CGPoint,
    pathStyle: ArrowPathStyle,
    seed: UInt64
) {
    let points = arrowShaftPoints(from: start, to: end, bend: bend, pathStyle: pathStyle, seed: seed)
    switch pathStyle {
    case .autoBend:
        appendOrthogonalArrowShaft(to: path, points: points)
    case .squiggle:
        path.addPath(smoothPath(from: points))
    }
}

private func arrowPaths(
    from start: CGPoint,
    to end: CGPoint,
    bend: CGPoint? = nil,
    tipStyle: ArrowTipStyle,
    pathStyle: ArrowPathStyle,
    seed: UInt64,
    lineWidth: CGFloat
) -> ArrowPaths? {
    let points = arrowShaftPoints(from: start, to: end, bend: bend, pathStyle: pathStyle, seed: seed)
    guard points.count >= 2 else { return nil }
    let headStart = points[points.count - 2]
    guard let layout = arrowLayout(from: headStart, to: end) else { return nil }

    let stroke = CGMutablePath()
    var fill: CGPath?
    var shaftPoints = points

    switch tipStyle {
    case .solid:
        shaftPoints[shaftPoints.count - 1] = layout.baseCenter
        switch pathStyle {
        case .autoBend:
            appendOrthogonalArrowShaft(to: stroke, points: collapseArrowWaypoints(shaftPoints))
        case .squiggle:
            stroke.addPath(smoothPath(from: shaftPoints))
        }
        let head = CGMutablePath()
        head.move(to: layout.baseCenter)
        head.addLine(to: layout.wingLeft)
        head.addLine(to: end)
        head.addLine(to: layout.wingRight)
        head.closeSubpath()
        fill = head
    case .dot:
        shaftPoints[shaftPoints.count - 1] = CGPoint(
            x: end.x - cos(layout.angle) * arrowDotRadius,
            y: end.y - sin(layout.angle) * arrowDotRadius
        )
        switch pathStyle {
        case .autoBend:
            appendOrthogonalArrowShaft(to: stroke, points: collapseArrowWaypoints(shaftPoints))
        case .squiggle:
            stroke.addPath(smoothPath(from: shaftPoints))
        }
    }
    return ArrowPaths(stroke: stroke, fill: fill)
}

// MARK: - AnnotationTextField

/// NSTextField subclass that intercepts Escape before AppKit can beep.
final class AnnotationTextField: NSTextField {
    var onEscape: (() -> Void)?
    var onTextDidChange: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextDidChange?()
    }
}

// MARK: - StickerPickerPanel

final class StickerPickerPanel: NSObject, NSWindowDelegate {

    // 12 curated SF symbols that map to common annotation intents.
    private static let stickers: [String] = [
        "star.fill",
        "heart.fill",
        "hand.thumbsup.fill",
        "checkmark.circle.fill",
        "xmark.circle.fill",
        "exclamationmark.triangle.fill",
        "lightbulb.fill",
        "flame.fill",
        "eyes",
        "bubble.left.fill",
        "ant.fill",
        "flag.fill",
    ]

    private let panel: NSPanel
    private let onSelect: (String) -> Void
    private var color: NSColor
    private var symbolButtons: [NSButton] = []

    init(nearScreenPoint point: CGPoint, color: NSColor, onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        self.color = color

        let cols: CGFloat = 4
        let rows: CGFloat = 3
        let btnSz: CGFloat = 46
        let gap: CGFloat = 6
        let pad: CGFloat = 10
        let panelW = pad * 2 + cols * btnSz + (cols - 1) * gap
        let panelH = pad * 2 + rows * btnSz + (rows - 1) * gap

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var ox = point.x + 12
        var oy = point.y - panelH / 2
        ox = min(ox, screen.maxX - panelW - 10)
        ox = max(ox, screen.minX + 10)
        oy = min(oy, screen.maxY - panelH - 10)
        oy = max(oy, screen.minY + 10)

        panel = NSPanel(
            contentRect: NSRect(x: ox, y: oy, width: panelW, height: panelH),
            styleMask: [.nonactivatingPanel, .titled, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false

        super.init()
        panel.delegate = self
        buildUI()
    }

    private func buildUI() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let vStack = NSStackView()
        vStack.translatesAutoresizingMaskIntoConstraints = false
        vStack.orientation = .vertical
        vStack.spacing = 6

        let cols = 4
        var rowViews: [NSView] = []
        for (i, symbol) in Self.stickers.enumerated() {
            let btn = NSButton(frame: .zero)
            btn.title = ""
            btn.isBordered = false
            btn.bezelStyle = .regularSquare
            btn.wantsLayer = true
            btn.layer?.cornerRadius = DesignTokens.Radius.md
            btn.image = stickerSymbolImage(symbolName: symbol, pointSize: 22, color: color)
            btn.imageScaling = .scaleProportionallyDown
            symbolButtons.append(btn)
            btn.target = self
            btn.action = #selector(stickerTapped(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(symbol)
            btn.widthAnchor.constraint(equalToConstant: 46).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 46).isActive = true
            rowViews.append(btn)
            if rowViews.count == cols || i == Self.stickers.count - 1 {
                let row = NSStackView(views: rowViews)
                row.orientation = .horizontal
                row.spacing = 6
                row.distribution = .fillEqually
                vStack.addArrangedSubview(row)
                rowViews = []
            }
        }

        container.addSubview(vStack)
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            vStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            vStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            vStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10),
        ])
        panel.contentView = container
    }

    @objc private func stickerTapped(_ sender: NSButton) {
        let symbol = sender.identifier?.rawValue ?? ""
        panel.close()
        onSelect(symbol)
    }

    func show() { panel.makeKeyAndOrderFront(nil) }
    func close() { panel.close() }

    func updateColor(_ color: NSColor) {
        self.color = color
        for btn in symbolButtons {
            let symbol = btn.identifier?.rawValue ?? ""
            btn.image = stickerSymbolImage(symbolName: symbol, pointSize: 22, color: color)
        }
    }
}

// MARK: - AnnotationCanvasView

final class AnnotationCanvasView: NSView, NSTextFieldDelegate {

    private static let textHPadding: CGFloat = 10
    private static let textVPadding: CGFloat = 4

    // All committed annotations.
    var annotations: [PlacedAnnotation] = []
    // The annotation being drawn right now (not yet committed).
    var currentAnnotation: Annotation?

    var selectedTool: AnnotationTool = .draw {
        didSet {
            guard oldValue != selectedTool else { return }
            commitActiveTextField()
            resetArrowPlacement()
            if oldValue == .crop {
                commitCropEditing()
            }
            if selectedTool == .crop {
                beginCropEditing()
            }
            notifyCommittedCropPreviewIfNeeded()
        }
    }
    var selectedColor: NSColor = NSColor.annotationPalette[0]
    var selectedStrokeTool: StrokeTool = .marker
    var selectedArrowTipStyle: ArrowTipStyle = .solid
    var selectedArrowPathStyle: ArrowPathStyle = .autoBend
    /// Last-used spotlight settings (recents, same as stroke color/weight).
    var selectedSpotlightDimOpacity: CGFloat = AppSettings.spotlightDimOpacityDefault
    var selectedSpotlightBlurRadius: CGFloat = AppSettings.spotlightBlurRadiusDefault
    /// Stage background for spotlight blur (canvas-sized).
    var stageBackgroundImage: NSImage?
    /// Stable seed for the in-progress squiggle arrow.
    private var activeArrowSeed: UInt64 = 1
    private var spotlightEffectCache: (roundedRadius: CGFloat, imageID: ObjectIdentifier, image: NSImage)?

    /// When true, annotations are filtered by playback time and stamped on commit.
    var videoMode: Bool = false
    /// Current video playback time — drives visibility filtering in video mode.
    var playbackTime: Double = 0
    /// Total video length in seconds (video mode). Used to clamp annotation end times.
    var videoDuration: Double = 0
    /// Recording width/height. When > 0, zoom selections lock to this aspect ratio.
    var videoAspectRatio: CGFloat = 0
    /// Natural recording size (orientation-corrected). Used to map the aspect-fit video
    /// frame inside letterboxed previews (e.g. View All) so zoom stays on the media.
    var videoMediaSize: CGSize = .zero
    /// When true, zoom overlays are hidden and zoom is applied to the video layer instead.
    var isPlaybackActive: Bool = false
    /// When true, scrubbing the timeline — same live zoom behavior as playback.
    var isScrubbing: Bool = false
    /// When true, user input is ignored while a video export is in progress.
    var isExporting: Bool = false
    /// Tools available in this canvas (screenshot vs video).
    var allowedTools: Set<AnnotationTool> = Set(AnnotationTool.videoTools)

    /// Called whenever the active tool changes via keyboard.
    var onToolChanged: ((AnnotationTool) -> Void)?
    /// Called when Escape is pressed (with or without an active text field).
    var onEscapeAction: (() -> Void)?
    /// Video mode: spacebar toggles play/pause.
    var onTogglePlayback: (() -> Void)?
    /// Called just before the first mouse-down begins a new stroke/shape.
    var onWillDraw: (() -> Void)?
    /// Called when the user presses or releases the mouse while actively using a drag tool.
    var onActiveToolUseChanged: ((Bool) -> Void)?
    /// Called on mouse drag while a drag tool is in use (window coordinates).
    var onActiveToolPointerMoved: ((NSPoint) -> Void)?
    /// Called when the selected annotation index changes (video mode duration UI).
    var onSelectionChanged: ((Int?) -> Void)?
    /// Called when the selected annotation moves (drag in select mode).
    var onSelectionGeometryChanged: (() -> Void)?
    /// Called when a committed crop preview should be applied or cleared.
    var onCommittedCropPreviewChanged: ((CGRect?) -> Void)?

    var selectedIndex: Int? = nil
    private var dragOffset: CGPoint = .zero
    private var isActiveToolUse = false

    private enum RectResizeHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum SelectDragMode {
        case none
        case moveWhole
        case arrowStart
        case arrowEnd
        case arrowBend
        case textWidthLeft(anchorRight: CGFloat)
        case textWidthRight(anchorLeft: CGFloat)
        case rectResize(handle: RectResizeHandle, anchor: CGRect)
    }

    private let rectCornerHitRadius: CGFloat = 10
    private let rectEdgeHitThickness: CGFloat = 6
    private let rectMinSize: CGFloat = 20

    private var selectDragMode: SelectDragMode = .none

    private enum CropDragMode {
        case none
        case moving(origin: CGRect, start: CGPoint)
        case resizing(handle: RectResizeHandle, anchor: CGRect)
    }

    private var cropEditingRect: CGRect?
    private var cropDragMode: CropDragMode = .none

    private var strokePoints: [CGPoint] = []
    private var dragStart: CGPoint = .zero

    private enum ArrowPlacementState {
        case idle
        case drawingStart(start: CGPoint)
        case awaitingEndpoint(start: CGPoint)
        case drawingEnd(start: CGPoint)
    }

    private var arrowPlacementState: ArrowPlacementState = .idle
    private var arrowDragExceededThreshold = false
    private let arrowDragThreshold: CGFloat = 4
    private var activeTextField: AnnotationTextField?
    private var activeEmojiPicker: StickerPickerPanel?
    private var pendingEmojiPoint: CGPoint = .zero

    func updateEmojiPickerColor(_ color: NSColor) {
        activeEmojiPicker?.updateColor(color)
    }

    private var undoStack: [[PlacedAnnotation]] = []
    private var redoStack: [[PlacedAnnotation]] = []
    private static let maxUndoLevels = 50
    private var selectDragSavedState: [PlacedAnnotation]?
    private var selectDidDrag = false

    private func appendAnnotation(_ content: Annotation) {
        pushUndoState()
        if case .crop = content {
            annotations.removeAll { if case .crop = $0.content { return true }; return false }
        }
        let start = videoMode ? playbackTime : 0
        var placed = PlacedAnnotation(content: content, startTime: start)
        if videoMode, case .zoom = content {
            // Only one zoom at a time — end earlier zooms and replace any at this playhead.
            annotations.removeAll {
                guard case .zoom = $0.content else { return false }
                return abs($0.startTime - start) < 0.05
            }
            endOverlappingZooms(before: start)
            // Span from the placement time to the end of the video — never past it.
            if videoDuration.isFinite, videoDuration > start {
                placed.visibleDuration = videoDuration - start
            } else {
                placed.visibleDuration = nil
            }
        }
        annotations.append(placed)
        if videoMode, case .zoom = content {
            resolveZoomOverlaps()
        }
        if videoMode {
            setSelectedIndex(annotations.count - 1)
        }
        if case .crop = content {
            notifyCommittedCropPreviewIfNeeded()
        }
    }

    /// Caps any zoom that extends past `newStart` so it ends exactly there.
    private func endOverlappingZooms(before newStart: Double, excluding excludedIndex: Int? = nil) {
        for i in annotations.indices {
            if i == excludedIndex { continue }
            guard case .zoom = annotations[i].content else { continue }
            let zStart = annotations[i].startTime
            guard zStart < newStart else { continue }
            let overlaps: Bool
            if let duration = annotations[i].visibleDuration {
                overlaps = zStart + duration > newStart
            } else {
                overlaps = true
            }
            guard overlaps else { continue }
            annotations[i].visibleDuration = max(0.05, newStart - zStart)
        }
    }

    /// Ensures zoom ranges never overlap: earlier zooms end when the next zoom starts.
    private func resolveZoomOverlaps() {
        let zoomIndices = annotations.indices.filter {
            if case .zoom = annotations[$0].content { return true }
            return false
        }.sorted { annotations[$0].startTime < annotations[$1].startTime }

        guard zoomIndices.count > 1 else { return }

        var remove: Set<Int> = []
        for i in 0..<(zoomIndices.count - 1) {
            let earlier = zoomIndices[i]
            let later = zoomIndices[i + 1]
            let laterStart = annotations[later].startTime
            let earlierStart = annotations[earlier].startTime
            if laterStart <= earlierStart {
                remove.insert(earlier)
                continue
            }
            if let duration = annotations[earlier].visibleDuration {
                if earlierStart + duration > laterStart {
                    annotations[earlier].visibleDuration = laterStart - earlierStart
                }
            } else {
                annotations[earlier].visibleDuration = laterStart - earlierStart
            }
        }
        if !remove.isEmpty {
            let selected = selectedIndex
            annotations = annotations.enumerated().compactMap { offset, placed in
                remove.contains(offset) ? nil : placed
            }
            if let selected {
                if remove.contains(selected) {
                    setSelectedIndex(nil)
                } else {
                    let shifted = selected - remove.filter { $0 < selected }.count
                    setSelectedIndex(shifted)
                }
            }
        }
    }

    private func pushUndoState() {
        undoStack.append(annotations)
        if undoStack.count > Self.maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo() {
        commitActiveTextField()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        setSelectedIndex(nil)
        needsDisplay = true
        notifyCommittedCropPreviewIfNeeded()
    }

    func redo() {
        commitActiveTextField()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        setSelectedIndex(nil)
        needsDisplay = true
        notifyCommittedCropPreviewIfNeeded()
    }

    /// Returns true when the event was handled (undo/redo).
    func handleUndoRedoKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        if activeTextField != nil { return false }
        if let resp = window?.firstResponder as? NSTextView, resp.isFieldEditor { return false }
        if event.modifierFlags.contains(.shift) {
            redo()
        } else {
            undo()
        }
        return true
    }

    var isEditingText: Bool { activeTextField != nil }

    func installUndoRedoKeyMonitor(for window: NSWindow) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            return self.handleUndoRedoKeyEquivalent(event) ? nil : event
        }
    }

    private func setSelectedIndex(_ index: Int?) {
        selectedIndex = index
        onSelectionChanged?(index)
    }

    func setForever(for index: Int, forever: Bool) {
        guard annotations.indices.contains(index) else { return }
        if forever {
            annotations[index].visibleDuration = nil
        } else {
            annotations[index].visibleDuration = max(0.05, annotations[index].visibleDuration ?? 5)
        }
        if case .zoom = annotations[index].content {
            resolveZoomOverlaps()
        }
        needsDisplay = true
    }

    func setStartTime(for index: Int, seconds: Double, recordingDuration: Double) {
        guard annotations.indices.contains(index) else { return }
        let maxStart = max(0, recordingDuration)
        let start = max(0, min(seconds, maxStart))
        annotations[index].startTime = start
        if let duration = annotations[index].visibleDuration {
            let maxDuration = max(0.05, recordingDuration - start)
            annotations[index].visibleDuration = min(duration, maxDuration)
        }
        if case .zoom = annotations[index].content {
            resolveZoomOverlaps()
        }
        needsDisplay = true
    }

    func setVisibleDuration(for index: Int, seconds: Double, recordingDuration: Double = .infinity) {
        guard annotations.indices.contains(index) else { return }
        let start = annotations[index].startTime
        let maxDuration = recordingDuration.isFinite
            ? max(0.05, recordingDuration - start)
            : seconds
        annotations[index].visibleDuration = max(0.05, min(seconds, maxDuration))
        if case .zoom = annotations[index].content {
            resolveZoomOverlaps()
        }
        needsDisplay = true
    }

    func selectionBoundingBox() -> CGRect? {
        guard let idx = selectedIndex, annotations.indices.contains(idx) else { return nil }
        return boundingBox(for: annotations[idx].content)
    }

    // MARK: Drawing

    private func shouldRenderOverlay(for content: Annotation, isCurrent: Bool = false) -> Bool {
        guard videoMode, case .zoom = content else { return true }
        // Playing / scrubbing: draw a solid read-only selection instead of the dashed zoom chrome.
        if isPlaybackActive || isScrubbing { return false }
        // In-progress placement: always show the drag border on the raw frame.
        if isCurrent { return true }
        // Paused: show the region only when it is selected for editing (raw video).
        // Otherwise the settled zoom preview is on the player and the overlay would drift.
        guard let idx = selectedIndex, annotations.indices.contains(idx),
              case let .zoom(selectedRect) = annotations[idx].content,
              case let .zoom(rect) = content else {
            return false
        }
        return selectedRect == rect
    }

    /// When true, preview leaves the video unzoomed so zoom selection is always
    /// relative to the full recording frame (never the currently zoomed view).
    var prefersRawVideoForZoomEditing: Bool {
        guard videoMode else { return false }
        // Never freeze the preview while playing/scrubbing — zoom must still run.
        guard !isPlaybackActive, !isScrubbing else { return false }
        // In-progress placement: always show the full unzoomed recording.
        if case .zoom = currentAnnotation { return true }
        if selectedTool == .zoom { return true }
        // Editing an existing zoom while paused.
        guard let idx = selectedIndex, annotations.indices.contains(idx),
              case .zoom = annotations[idx].content else { return false }
        return annotations[idx].isVisible(at: playbackTime)
    }

    /// Zoom regions are fixed to the full frame — no move/resize while playing.
    private var allowsZoomGeometryEditing: Bool {
        !videoMode || (!isPlaybackActive && !isScrubbing)
    }

    /// Cancels an in-progress select drag of a zoom region (e.g. when play starts).
    func cancelZoomGeometryDrag() {
        guard let idx = selectedIndex,
              annotations.indices.contains(idx),
              case .zoom = annotations[idx].content else { return }
        selectDragMode = .none
        selectDragSavedState = nil
        selectDidDrag = false
    }

    private func committedCropRect() -> CGRect? {
        guard let rect = annotations.compactMap({ placed -> CGRect? in
            if case .crop(let rect) = placed.content { return rect }
            return nil
        }).last else { return nil }
        guard rect.width > 1, rect.height > 1, !isFullBoundsCrop(rect) else { return nil }
        return rect
    }

    private func committedCropPreviewRect() -> CGRect? {
        guard selectedTool != .crop else { return nil }
        return committedCropRect()
    }

    private func notifyCommittedCropPreviewIfNeeded() {
        onCommittedCropPreviewChanged?(committedCropPreviewRect())
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Spotlights first so they suppress the capture, not other annotations.
        renderSpotlightLayers(
            annotations: annotations,
            current: currentAnnotation,
            at: playbackTime,
            in: ctx
        )

        for placed in annotations {
            if case .crop = placed.content { continue }
            if case .spotlight = placed.content { continue }
            if !videoMode || placed.isVisible(at: playbackTime) {
                if shouldRenderOverlay(for: placed.content) {
                    render(placed.content, in: ctx)
                }
            }
        }
        if let cur = currentAnnotation, shouldRenderOverlay(for: cur, isCurrent: true) {
            if case .spotlight = cur {
                // Already drawn in the spotlight pass.
            } else {
                render(cur, in: ctx)
            }
        }

        if selectedTool == .crop, let cropRect = cropEditingRect {
            drawCropEditingOverlay(rect: cropRect, in: ctx)
        }

        if selectedTool == .select, let idx = selectedIndex, idx < annotations.count {
            let content = annotations[idx].content
            if case .crop = content {
                // Crop is edited via the crop tool, not select handles.
            } else if case .zoom = content, isPlaybackActive || isScrubbing {
                // Player draws a fixed read-only selection during play/scrub.
            } else {
            switch content {
            case let .arrow(from, to, bend, _, _, pathStyle, seed):
                drawArrowSelectionHandles(from: from, to: to, bend: bend, pathStyle: pathStyle, seed: seed, in: ctx)
            case let .text(origin, text, _, maxWidth):
                drawTextSelectionHandles(metrics: textMetrics(origin: origin, text: text, maxWidth: maxWidth), in: ctx)
            case let .rect(rect, _):
                drawRectAnnotationSelectionHandles(rect: rect, in: ctx)
            case let .spotlight(region, _, _):
                drawRectAnnotationSelectionHandles(rect: region, in: ctx)
            case let .zoom(rect):
                drawRectAnnotationSelectionHandles(rect: rect, in: ctx)
            default:
                let box = boundingBox(for: content).insetBy(dx: -4, dy: -4)
                ctx.saveGState()
                ctx.setStrokeColor(NSColor.annotationSelectionAccent.cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.strokePath()
                ctx.restoreGState()
            }
            }
        }
    }

    private struct TextMetrics {
        let origin: CGPoint
        let contentWidth: CGFloat
        let contentHeight: CGFloat
        let pillRect: CGRect
        let selectionRect: CGRect
        let leftHandle: CGPoint
        let rightHandle: CGPoint
    }

    private func textFont() -> NSFont {
        NSFont.grabbit(.panelTitle)
    }

    private func textDrawAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return [
            .font: textFont(),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
    }

    private func textMetrics(origin: CGPoint, text: String, maxWidth: CGFloat?) -> TextMetrics {
        let font = textFont()
        let hPad = Self.textHPadding
        let vPad = Self.textVPadding
        let measureAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let intrinsicWidth = (text as NSString).size(withAttributes: measureAttrs).width
        let contentWidth = max(maxWidth ?? intrinsicWidth, 1)
        let wrapAttrs = textDrawAttributes(color: .black)
        let contentHeight = ceil((text as NSString).boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: wrapAttrs
        ).height)
        let pillRect = CGRect(
            x: origin.x - hPad,
            y: origin.y - vPad,
            width: contentWidth + hPad * 2,
            height: contentHeight + vPad * 2
        )
        let midY = pillRect.midY
        return TextMetrics(
            origin: origin,
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            pillRect: pillRect,
            selectionRect: pillRect,
            leftHandle: CGPoint(x: pillRect.minX, y: midY),
            rightHandle: CGPoint(x: pillRect.maxX, y: midY)
        )
    }

    private func drawRectAnnotationSelectionHandles(rect: CGRect, in ctx: CGContext) {
        let radius: CGFloat = 5
        let accent = NSColor.annotationSelectionAccent
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]

        ctx.saveGState()
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(rect)

        for point in corners {
            let dotRect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: dotRect)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: dotRect)
        }
        ctx.restoreGState()
    }

    private func drawCropSelectionHandles(rect: CGRect, in ctx: CGContext) {
        let armLength: CGFloat = 14
        let accent = NSColor.annotationSelectionAccent

        ctx.saveGState()
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(rect)

        ctx.setLineCap(.square)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(NSColor.white.cgColor)
        addCornerBrackets(to: rect, armLength: armLength, in: ctx)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func addCornerBrackets(to rect: CGRect, armLength: CGFloat, in ctx: CGContext) {
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + armLength))
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.minX + armLength, y: rect.minY))

        ctx.move(to: CGPoint(x: rect.maxX - armLength, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + armLength))

        ctx.move(to: CGPoint(x: rect.maxX, y: rect.maxY - armLength))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.maxX - armLength, y: rect.maxY))

        ctx.move(to: CGPoint(x: rect.minX + armLength, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - armLength))
    }

    private func drawTextSelectionHandles(metrics: TextMetrics, in ctx: CGContext) {
        let radius: CGFloat = 5
        let accent = NSColor.annotationSelectionAccent
        let cornerRadius: CGFloat = 2

        ctx.saveGState()
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(
            roundedRect: metrics.selectionRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        ))
        ctx.strokePath()

        for point in [metrics.leftHandle, metrics.rightHandle] {
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: rect)
        }
        ctx.restoreGState()
    }

    private func drawCropEditingOverlay(rect: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        dimPath.addRect(rect)
        ctx.addPath(dimPath)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fillPath(using: .evenOdd)

        ctx.setStrokeColor(NSColor.annotationSelectionAccent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(rect)
        ctx.restoreGState()

        drawCropSelectionHandles(rect: rect, in: ctx)
    }

    private func beginCropEditing() {
        if let existing = annotations.compactMap({ placed -> CGRect? in
            if case .crop(let rect) = placed.content { return rect }
            return nil
        }).last {
            cropEditingRect = clampedCropRect(existing)
        } else {
            cropEditingRect = bounds
        }
        cropDragMode = .none
        needsDisplay = true
    }

    private func commitCropEditing() {
        guard let rect = cropEditingRect else {
            cropDragMode = .none
            return
        }
        cropEditingRect = nil
        cropDragMode = .none

        if isFullBoundsCrop(rect) {
            let hadCrop = annotations.contains { if case .crop = $0.content { return true }; return false }
            if hadCrop {
                pushUndoState()
                annotations.removeAll { if case .crop = $0.content { return true }; return false }
            }
        } else if rect.width > 1, rect.height > 1 {
            appendAnnotation(.crop(rect: rect))
        }
        notifyCommittedCropPreviewIfNeeded()
        needsDisplay = true
    }

    private func isFullBoundsCrop(_ rect: CGRect) -> Bool {
        let b = bounds
        return abs(rect.minX - b.minX) < 1
            && abs(rect.minY - b.minY) < 1
            && abs(rect.maxX - b.maxX) < 1
            && abs(rect.maxY - b.maxY) < 1
    }

    private func clampedCropRect(_ rect: CGRect) -> CGRect {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return rect }
        var minX = max(b.minX, rect.minX)
        var minY = max(b.minY, rect.minY)
        var maxX = min(b.maxX, rect.maxX)
        var maxY = min(b.maxY, rect.maxY)
        if maxX - minX < rectMinSize {
            if rect.midX < b.midX {
                maxX = min(b.maxX, minX + rectMinSize)
            } else {
                minX = max(b.minX, maxX - rectMinSize)
            }
        }
        if maxY - minY < rectMinSize {
            if rect.midY < b.midY {
                maxY = min(b.maxY, minY + rectMinSize)
            } else {
                minY = max(b.minY, maxY - rectMinSize)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func resizedCropRect(anchor: CGRect, handle: RectResizeHandle, to point: CGPoint) -> CGRect {
        clampedCropRect(resizedRect(anchor: anchor, handle: handle, to: point))
    }

    private func handleCropMouseDown(at pt: CGPoint) {
        if let rect = cropEditingRect, rect.width > 1, rect.height > 1 {
            if let handle = rectHitTestHandle(at: pt, in: rect) {
                cropDragMode = .resizing(handle: handle, anchor: rect)
                return
            }
            if rectInterior(of: rect).contains(pt), !isFullBoundsCrop(rect) {
                cropDragMode = .moving(origin: rect, start: pt)
                return
            }
        }
        cropDragMode = .none
    }

    private func handleCropMouseDragged(to pt: CGPoint) {
        switch cropDragMode {
        case .none:
            break
        case .moving(let origin, let start):
            let dx = pt.x - start.x
            let dy = pt.y - start.y
            var moved = origin.offsetBy(dx: dx, dy: dy)
            let b = bounds
            if moved.minX < b.minX { moved.origin.x += b.minX - moved.minX }
            if moved.minY < b.minY { moved.origin.y += b.minY - moved.minY }
            if moved.maxX > b.maxX { moved.origin.x -= moved.maxX - b.maxX }
            if moved.maxY > b.maxY { moved.origin.y -= moved.maxY - b.maxY }
            cropEditingRect = moved
        case .resizing(let handle, let anchor):
            cropEditingRect = resizedCropRect(anchor: anchor, handle: handle, to: pt)
        }
    }

    private func drawArrowSelectionHandles(
        from: CGPoint,
        to: CGPoint,
        bend: CGPoint?,
        pathStyle: ArrowPathStyle,
        seed: UInt64,
        in ctx: CGContext
    ) {
        let radius: CGFloat = 5
        let accent = NSColor.annotationSelectionAccent

        ctx.saveGState()
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(2)
        let shaft = CGMutablePath()
        appendArrowShaft(to: shaft, from: from, bend: bend, to: to, pathStyle: pathStyle, seed: seed)
        ctx.addPath(shaft)
        ctx.strokePath()
        ctx.restoreGState()

        var handles = [from, to]
        if pathStyle == .autoBend {
            handles.append(arrowBendHandle(from: from, to: to, bend: bend))
        }
        for point in handles {
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: rect)
            ctx.restoreGState()
        }
    }

    private struct SpotlightRenderEntry {
        let region: CGRect
        let dimOpacity: CGFloat
        let blurRadius: CGFloat
    }

    private func renderSpotlightLayers(
        annotations: [PlacedAnnotation],
        current: Annotation?,
        at time: Double,
        in ctx: CGContext,
        canvasBounds: CGRect? = nil,
        annotationOffset: CGPoint = .zero
    ) {
        var entries: [SpotlightRenderEntry] = []

        func append(region: CGRect, dimOpacity: CGFloat, blurRadius: CGFloat) {
            guard region.width > 0.5, region.height > 0.5 else { return }
            guard dimOpacity > 0 || blurRadius > 0 else { return }
            let offsetRegion = annotationOffset == .zero
                ? region
                : region.offsetBy(dx: annotationOffset.x, dy: annotationOffset.y)
            entries.append(
                SpotlightRenderEntry(
                    region: offsetRegion,
                    dimOpacity: dimOpacity,
                    blurRadius: blurRadius
                )
            )
        }

        for placed in annotations {
            if case .crop = placed.content { continue }
            guard case let .spotlight(region, dimOpacity, blurRadius) = placed.content else { continue }
            if !videoMode || placed.isVisible(at: time) {
                append(
                    region: region,
                    dimOpacity: dimOpacity,
                    blurRadius: blurRadius
                )
            }
        }
        if case let .spotlight(region, dimOpacity, blurRadius) = current {
            append(
                region: region,
                dimOpacity: dimOpacity,
                blurRadius: blurRadius
            )
        }

        guard !entries.isEmpty else { return }
        let bounds = canvasBounds ?? self.bounds
        let cutoutPaths = entries.map { spotlightCutoutPath(for: $0.region) }
        // Union of all cutouts: overlapping spotlights share one lit region; separate rects stay separate holes.
        let outsideMask = spotlightClipMask(cutouts: cutoutPaths, bounds: bounds)
        let dimOpacity = entries.map(\.dimOpacity).max() ?? 0
        let blurRadius = entries.map(\.blurRadius).max() ?? 0

        ctx.saveGState()
        if let outsideMask {
            ctx.clip(to: bounds, mask: outsideMask)
        }
        drawSpotlightSuppression(
            bounds: bounds,
            dimOpacity: dimOpacity,
            blurRadius: blurRadius,
            in: ctx
        )
        ctx.restoreGState()
    }

    private func spotlightCutoutPath(for region: CGRect) -> CGPath {
        let radius = Annotation.spotlightCornerRadius
        return CGPath(
            roundedRect: region,
            cornerWidth: min(radius, region.width / 2),
            cornerHeight: min(radius, region.height / 2),
            transform: nil
        )
    }

    private func drawSpotlightSuppression(
        bounds: CGRect,
        dimOpacity: CGFloat,
        blurRadius: CGFloat,
        in ctx: CGContext
    ) {
        if blurRadius > 0 {
            if let effect = spotlightSuppressionImage(for: blurRadius) {
                let imageRect = NSRect(origin: .zero, size: effect.size)
                effect.draw(
                    in: bounds,
                    from: imageRect,
                    operation: .sourceOver,
                    fraction: 1.0
                )
            }
        }

        if dimOpacity > 0 {
            ctx.setFillColor(NSColor.black.withAlphaComponent(dimOpacity).cgColor)
            ctx.fill(bounds)
        }
    }

    /// Hard clip mask: white outside all cutouts, black inside (lit regions). Multiple cutouts union.
    private func spotlightClipMask(
        cutouts: [CGPath],
        bounds: CGRect
    ) -> CGImage? {
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }

        let width = Int(bounds.width.rounded(.up))
        let height = Int(bounds.height.rounded(.up))
        guard let maskCtx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        maskCtx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        maskCtx.setFillColor(gray: 1, alpha: 1)
        maskCtx.fill(bounds)
        maskCtx.setFillColor(gray: 0, alpha: 1)
        for cutout in cutouts {
            maskCtx.addPath(cutout)
            maskCtx.fillPath(using: .winding)
        }
        return maskCtx.makeImage()
    }

    private func spotlightSuppressionImage(for blurRadius: CGFloat) -> NSImage? {
        guard blurRadius > 0 else { return nil }
        guard let background = stageBackgroundImage else { return nil }
        let roundedRadius = blurRadius.rounded()
        let imageID = ObjectIdentifier(background)
        if let cache = spotlightEffectCache,
           cache.roundedRadius == roundedRadius,
           cache.imageID == imageID {
            return cache.image
        }
        guard let image = RecordingBackgroundRenderer.spotlightSuppressionImage(
            from: background,
            radius: roundedRadius
        ) else { return nil }
        spotlightEffectCache = (roundedRadius, imageID, image)
        return image
    }

    private func render(_ annotation: Annotation, in ctx: CGContext) {
        switch annotation {

        case .spotlight:
            break

        case let .stroke(points, color, lineWidth, tool):
            ctx.saveGState()
            ctx.setLineWidth(lineWidth)
            ctx.setStrokeColor(color.cgColor)
            ctx.setAlpha(tool == .highlighter ? 0.35 : 1.0)
            ctx.addPath(smoothPath(from: points))
            ctx.strokePath()
            ctx.restoreGState()

        case let .arrow(from, to, bend, color, tipStyle, pathStyle, seed):
            let lineWidth: CGFloat = 2.5
            guard let paths = arrowPaths(
                from: from,
                to: to,
                bend: bend,
                tipStyle: tipStyle,
                pathStyle: pathStyle,
                seed: seed,
                lineWidth: lineWidth
            ) else { break }

            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -1),
                blur: 4,
                color: NSColor.black.withAlphaComponent(0.25).cgColor
            )
            ctx.setAlpha(1)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(tipStyle == .dot || pathStyle == .squiggle ? .round : .butt)
            ctx.setLineJoin(pathStyle == .squiggle ? .round : .miter)
            ctx.setMiterLimit(4)
            ctx.setStrokeColor(color.cgColor)
            ctx.addPath(paths.stroke)
            ctx.strokePath()

            if let fillPath = paths.fill {
                ctx.setFillColor(color.cgColor)
                ctx.addPath(fillPath)
                ctx.fillPath()
            }

            if tipStyle == .dot {
                let dotRect = CGRect(
                    x: to.x - arrowDotRadius,
                    y: to.y - arrowDotRadius,
                    width: arrowDotRadius * 2,
                    height: arrowDotRadius * 2
                )
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: dotRect)
            }
            ctx.restoreGState()

        case let .rect(rect, color):
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -1),
                blur: 4,
                color: NSColor.black.withAlphaComponent(0.25).cgColor
            )
            ctx.setAlpha(1)
            let rounded = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.setFillColor(color.withAlphaComponent(0.08).cgColor)
            ctx.addPath(rounded)
            ctx.fillPath()
            ctx.setLineWidth(2)
            ctx.setStrokeColor(color.cgColor)
            ctx.addPath(rounded)
            ctx.strokePath()
            ctx.restoreGState()

        case let .zoom(rect):
            ctx.saveGState()
            ctx.setAlpha(1)
            ctx.setLineWidth(2)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineDash(phase: 0, lengths: [6, 3])
            ctx.stroke(rect)
            ctx.setLineDash(phase: 0, lengths: [])
            let badgeSize: CGFloat = 20
            let badgeOrigin = CGPoint(x: rect.minX + 4, y: rect.maxY - badgeSize - 4)
            let badgeRect = CGRect(origin: badgeOrigin, size: CGSize(width: badgeSize, height: badgeSize))
            if let badge = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
                if let tinted = badge.withSymbolConfiguration(cfg) {
                    tinted.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                }
            }
            ctx.restoreGState()

        case let .crop(rect):
            ctx.saveGState()
            ctx.setAlpha(1)
            ctx.setLineWidth(2)
            ctx.setStrokeColor(NSColor.labelColor.cgColor)
            ctx.setLineDash(phase: 0, lengths: [6, 3])
            ctx.stroke(rect)
            ctx.setLineDash(phase: 0, lengths: [])
            let badgeSize: CGFloat = 20
            let badgeOrigin = CGPoint(x: rect.minX + 4, y: rect.maxY - badgeSize - 4)
            let badgeRect = CGRect(origin: badgeOrigin, size: CGSize(width: badgeSize, height: badgeSize))
            if let badge = NSImage(systemSymbolName: "crop", accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
                if let tinted = badge.withSymbolConfiguration(cfg) {
                    tinted.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                }
            }
            ctx.restoreGState()

        case let .text(origin, text, color, maxWidth):
            ctx.saveGState()
            ctx.setAlpha(1)
            let metrics = textMetrics(origin: origin, text: text, maxWidth: maxWidth)
            let cornerRadius: CGFloat = 2
            let pillPath = CGPath(
                roundedRect: metrics.pillRect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
            ctx.setFillColor(color.withAlphaComponent(0.12).cgColor)
            ctx.addPath(pillPath)
            ctx.fillPath()
            ctx.setStrokeColor(color.withAlphaComponent(0.18).cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(pillPath)
            ctx.strokePath()
            let textRect = CGRect(
                origin: origin,
                size: CGSize(width: metrics.contentWidth, height: metrics.contentHeight)
            )
            (text as NSString).draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: textDrawAttributes(color: color)
            )
            ctx.restoreGState()

        case let .emoji(center, symbolName, size, color):
            let symRect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            let pointSize = size * 0.58
            guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { break }
            drawStickerSymbol(base: base, in: symRect, pointSize: pointSize, color: color)
        }
    }

    // MARK: Mouse Events

    private func setActiveToolUse(_ active: Bool) {
        guard isActiveToolUse != active else { return }
        isActiveToolUse = active
        onActiveToolUseChanged?(active)
    }

    private func notifyActiveToolPointer(at event: NSEvent) {
        guard isActiveToolUse else { return }
        onActiveToolPointerMoved?(event.locationInWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if selectedTool == .arrow, case .awaitingEndpoint(let start) = arrowPlacementState {
            let forceStraight = event.modifierFlags.contains(.shift)
            let bend = arrowPlacementBend(
                from: start,
                to: pt,
                forceStraight: forceStraight,
                pathStyle: selectedArrowPathStyle
            )
            currentAnnotation = makeArrow(from: start, to: pt, bend: bend)
            needsDisplay = true
        }
    }

    private func makeArrow(from: CGPoint, to: CGPoint, bend: CGPoint?) -> Annotation {
        .arrow(
            from: from,
            to: to,
            bend: bend,
            color: selectedColor,
            tipStyle: selectedArrowTipStyle,
            pathStyle: selectedArrowPathStyle,
            seed: activeArrowSeed
        )
    }

    private func resetArrowPlacement() {
        arrowPlacementState = .idle
        arrowDragExceededThreshold = false
        if case .arrow = currentAnnotation {
            currentAnnotation = nil
        }
    }

    private func commitPlacedArrow(_ content: Annotation) {
        appendAnnotation(content)
        resetArrowPlacement()
        setSelectedIndex(annotations.count - 1)
        selectedTool = .select
        onToolChanged?(.select)
    }

    private func commitPlacedSpotlight(_ content: Annotation) {
        if case let .spotlight(_, dimOpacity, blurRadius) = content {
            selectedSpotlightDimOpacity = AppSettings.snapSpotlightDimOpacity(dimOpacity)
            selectedSpotlightBlurRadius = AppSettings.snapSpotlightBlurRadius(blurRadius)
        }
        appendAnnotation(content)
        currentAnnotation = nil
        setSelectedIndex(annotations.count - 1)
        selectedTool = .select
        onToolChanged?(.select)
        needsDisplay = true
    }

    private func commitPlacedZoom(_ content: Annotation) {
        appendAnnotation(content)
        currentAnnotation = nil
        setSelectedIndex(annotations.count - 1)
        if allowedTools.contains(.select) {
            selectedTool = .select
            onToolChanged?(.select)
        }
        needsDisplay = true
    }

    /// Whether the toolbar should show spotlight controls instead of the color swatch.
    func prefersSpotlightToolbarAccessory() -> Bool {
        selectedTool == .spotlight || spotlightSettingsForEditing() != nil
    }

    /// Whether the toolbar should show the color swatch (and its leading divider).
    func prefersColorToolbarAccessory() -> Bool {
        if selectedTool == .crop || selectedTool == .zoom || prefersSpotlightToolbarAccessory() {
            return false
        }
        if selectedTool == .select {
            guard let idx = selectedIndex,
                  annotations.indices.contains(idx) else { return false }
            switch annotations[idx].content {
            case .stroke, .arrow, .rect, .text, .emoji:
                return true
            case .spotlight, .zoom, .crop:
                return false
            }
        }
        return true
    }

    /// Spotlight settings for the options panel (selected or in-progress annotation).
    func spotlightSettingsForEditing() -> (dimOpacity: CGFloat, blurRadius: CGFloat, region: CGRect)? {
        if let idx = selectedIndex,
           annotations.indices.contains(idx),
           case let .spotlight(region, dimOpacity, blurRadius) = annotations[idx].content {
            return (dimOpacity, blurRadius, region)
        }
        if case let .spotlight(region, dimOpacity, blurRadius)? = currentAnnotation {
            return (dimOpacity, blurRadius, region)
        }
        return nil
    }

    func spotlightAnnotationCount() -> Int {
        var count = annotations.reduce(into: 0) { partial, placed in
            if case .spotlight = placed.content { partial += 1 }
        }
        if case .spotlight = currentAnnotation { count += 1 }
        return count
    }

    var appliesSpotlightEffectGlobally: Bool {
        spotlightAnnotationCount() > 1
    }

    private func updateEditableSpotlight(
        region: CGRect? = nil,
        dimOpacity: CGFloat? = nil,
        blurRadius: CGFloat? = nil,
        pushUndo: Bool = true
    ) {
        if let dimOpacity { selectedSpotlightDimOpacity = dimOpacity }
        if let blurRadius { selectedSpotlightBlurRadius = blurRadius }

        if let idx = selectedIndex,
           annotations.indices.contains(idx),
           case let .spotlight(currentRegion, currentDim, currentBlur) = annotations[idx].content {
            let newContent: Annotation = .spotlight(
                region: region ?? currentRegion,
                dimOpacity: dimOpacity ?? currentDim,
                blurRadius: blurRadius ?? currentBlur
            )
            if pushUndo { pushUndoState() }
            annotations[idx].content = newContent
            needsDisplay = true
            onSelectionGeometryChanged?()
            return
        }

        if case let .spotlight(currentRegion, currentDim, currentBlur)? = currentAnnotation {
            currentAnnotation = .spotlight(
                region: region ?? currentRegion,
                dimOpacity: dimOpacity ?? currentDim,
                blurRadius: blurRadius ?? currentBlur
            )
            needsDisplay = true
            onSelectionGeometryChanged?()
        }
    }

    func applySpotlightDimOpacity(_ opacity: CGFloat) {
        let snapped = AppSettings.snapSpotlightDimOpacity(opacity)
        selectedSpotlightDimOpacity = snapped
        if appliesSpotlightEffectGlobally {
            updateAllSpotlights(dimOpacity: snapped)
        } else {
            updateEditableSpotlight(dimOpacity: snapped, pushUndo: false)
        }
    }

    func applySpotlightBlurRadius(_ radius: CGFloat) {
        let snapped = AppSettings.snapSpotlightBlurRadius(radius)
        selectedSpotlightBlurRadius = snapped
        if appliesSpotlightEffectGlobally {
            updateAllSpotlights(blurRadius: snapped)
        } else {
            updateEditableSpotlight(blurRadius: snapped, pushUndo: false)
        }
    }

    private func updateAllSpotlights(
        dimOpacity: CGFloat? = nil,
        blurRadius: CGFloat? = nil
    ) {
        var changed = false

        for index in annotations.indices {
            guard case let .spotlight(region, currentDim, currentBlur) = annotations[index].content else {
                continue
            }
            annotations[index].content = .spotlight(
                region: region,
                dimOpacity: dimOpacity ?? currentDim,
                blurRadius: blurRadius ?? currentBlur
            )
            changed = true
        }

        if case let .spotlight(region, currentDim, currentBlur)? = currentAnnotation {
            currentAnnotation = .spotlight(
                region: region,
                dimOpacity: dimOpacity ?? currentDim,
                blurRadius: blurRadius ?? currentBlur
            )
            changed = true
        }

        if let dimOpacity { selectedSpotlightDimOpacity = dimOpacity }
        if let blurRadius { selectedSpotlightBlurRadius = blurRadius }

        if changed {
            needsDisplay = true
            onSelectionGeometryChanged?()
        }
    }

    func applySpotlightRegion(_ region: CGRect) {
        updateEditableSpotlight(region: region, pushUndo: false)
    }

    func commitSpotlightEditUndo() {
        pushUndoState()
    }

    private func handleArrowMouseUp(at pt: CGPoint, forceStraight: Bool) {
        switch arrowPlacementState {
        case .drawingStart(let start):
            if arrowDragExceededThreshold, let cur = currentAnnotation {
                commitPlacedArrow(cur)
            } else {
                arrowPlacementState = .awaitingEndpoint(start: start)
                let bend = arrowPlacementBend(
                    from: start,
                    to: pt,
                    forceStraight: forceStraight,
                    pathStyle: selectedArrowPathStyle
                )
                currentAnnotation = makeArrow(from: start, to: pt, bend: bend)
            }
        case .drawingEnd:
            if let cur = currentAnnotation {
                commitPlacedArrow(cur)
            } else {
                resetArrowPlacement()
            }
        case .idle, .awaitingEndpoint:
            break
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Accepts keyboard focus without drawing AppKit's focus ring.
    override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isExporting else { return }
        let pt = convert(event.locationInWindow, from: nil)

        if let field = activeTextField, !field.frame.contains(pt) {
            commitActiveTextField()
        }

        if selectedTool == .select {
            if event.clickCount == 2,
               let idx = selectedIndex,
               idx < annotations.count,
               case let .arrow(from, to, bend, color, tipStyle, pathStyle, seed) = annotations[idx].content,
               pathStyle == .autoBend {
                let bendHandle = arrowBendHandle(from: from, to: to, bend: bend)
                let hitsBendHandle = hypot(pt.x - bendHandle.x, pt.y - bendHandle.y) <= 10
                if hitsBendHandle || hitTest(annotation: annotations[idx].content, point: pt) {
                    annotations[idx].content = .arrow(
                        from: from,
                        to: to,
                        bend: nil,
                        color: color,
                        tipStyle: tipStyle,
                        pathStyle: pathStyle,
                        seed: seed
                    )
                    selectDragMode = .none
                    needsDisplay = true
                    return
                }
            }

            var found = false
            for i in stride(from: annotations.count - 1, through: 0, by: -1) {
                if case .crop = annotations[i].content { continue }
                // Zoom selections apply to the overall recording and must not be
                // dragged while the player is zoomed during play/scrub.
                if case .zoom = annotations[i].content, !allowsZoomGeometryEditing {
                    continue
                }
                if hitTest(annotation: annotations[i].content, point: pt) {
                    setSelectedIndex(i)
                    selectDragSavedState = annotations
                    selectDidDrag = false
                    beginSelectDrag(at: pt, for: annotations[i].content)
                    found = true
                    break
                }
            }
            if !found {
                setSelectedIndex(nil)
                selectDragMode = .none
            }
            needsDisplay = true
            return
        }

        if selectedTool == .crop {
            handleCropMouseDown(at: pt)
            setActiveToolUse(true)
            needsDisplay = true
            return
        }

        if selectedTool == .arrow, case .awaitingEndpoint(let start) = arrowPlacementState {
            arrowPlacementState = .drawingEnd(start: start)
            arrowDragExceededThreshold = false
            dragStart = pt
            let forceStraight = event.modifierFlags.contains(.shift)
            let bend = arrowPlacementBend(
                from: start,
                to: pt,
                forceStraight: forceStraight,
                pathStyle: selectedArrowPathStyle
            )
            currentAnnotation = makeArrow(from: start, to: pt, bend: bend)
            needsDisplay = true
            return
        }

        onWillDraw?()
        setActiveToolUse(true)

        switch selectedTool {
        case .draw:
            strokePoints = [pt]
            currentAnnotation = .stroke(
                points: strokePoints,
                color: selectedColor,
                lineWidth: selectedStrokeTool.lineWidth,
                tool: selectedStrokeTool
            )
        case .arrow:
            arrowPlacementState = .drawingStart(start: pt)
            arrowDragExceededThreshold = false
            dragStart = pt
            activeArrowSeed = UInt64.random(in: 1 ... .max)
            currentAnnotation = makeArrow(from: pt, to: pt, bend: nil)
        case .rect:
            dragStart = pt
            currentAnnotation = .rect(rect: CGRect(origin: pt, size: .zero), color: selectedColor)
        case .spotlight:
            dragStart = pt
            currentAnnotation = .spotlight(
                region: CGRect(origin: pt, size: .zero),
                dimOpacity: selectedSpotlightDimOpacity,
                blurRadius: selectedSpotlightBlurRadius
            )
        case .zoom:
            // Zoom targets the recording frame only — ignore letterbox/pillarbox chrome.
            let content = videoContentFrame
            guard pt.x >= content.minX, pt.x <= content.maxX,
                  pt.y >= content.minY, pt.y <= content.maxY else {
                setActiveToolUse(false)
                return
            }
            dragStart = pt
            currentAnnotation = .zoom(rect: CGRect(origin: pt, size: .zero))
        case .text:
            let content = videoContentFrame
            guard pt.x >= content.minX, pt.x <= content.maxX,
                  pt.y >= content.minY, pt.y <= content.maxY else {
                setActiveToolUse(false)
                return
            }
            commitActiveTextField()
            placeTextField(at: clampPointToVideoContent(pt))
            return
        case .emoji:
            let winPt = convert(pt, to: nil)
            let screenPt = window.map { $0.convertPoint(toScreen: winPt) } ?? pt
            pendingEmojiPoint = pt
            activeEmojiPicker?.close()
            let picker = StickerPickerPanel(nearScreenPoint: screenPt, color: selectedColor) { [weak self] symbol in
                guard let self else { return }
                appendAnnotation(.emoji(center: pendingEmojiPoint, emoji: symbol, size: 40, color: selectedColor))
                activeEmojiPicker = nil
                needsDisplay = true
            }
            activeEmojiPicker = picker
            picker.show()
            return
        case .select:
            break
        case .crop:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        notifyActiveToolPointer(at: event)
        let pt = convert(event.locationInWindow, from: nil)

        if selectedTool == .crop {
            handleCropMouseDragged(to: pt)
            needsDisplay = true
            return
        }

        switch selectedTool {
        case .draw:
            strokePoints.append(pt)
            currentAnnotation = .stroke(
                points: strokePoints,
                color: selectedColor,
                lineWidth: selectedStrokeTool.lineWidth,
                tool: selectedStrokeTool
            )
        case .arrow:
            switch arrowPlacementState {
            case .drawingStart(let start), .drawingEnd(let start):
                if hypot(pt.x - dragStart.x, pt.y - dragStart.y) > arrowDragThreshold {
                    arrowDragExceededThreshold = true
                }
                let forceStraight = event.modifierFlags.contains(.shift)
                let bend = arrowPlacementBend(
                    from: start,
                    to: pt,
                    forceStraight: forceStraight,
                    pathStyle: selectedArrowPathStyle
                )
                currentAnnotation = makeArrow(from: start, to: pt, bend: bend)
            case .idle, .awaitingEndpoint:
                break
            }
        case .rect:
            currentAnnotation = .rect(
                rect: CGRect(
                    x: min(dragStart.x, pt.x), y: min(dragStart.y, pt.y),
                    width: abs(pt.x - dragStart.x), height: abs(pt.y - dragStart.y)
                ),
                color: selectedColor
            )
        case .spotlight:
            currentAnnotation = .spotlight(
                region: CGRect(
                    x: min(dragStart.x, pt.x), y: min(dragStart.y, pt.y),
                    width: abs(pt.x - dragStart.x), height: abs(pt.y - dragStart.y)
                ),
                dimOpacity: selectedSpotlightDimOpacity,
                blurRadius: selectedSpotlightBlurRadius
            )
        case .zoom:
            currentAnnotation = .zoom(
                rect: zoomDragRect(from: dragStart, to: clampPointToVideoContent(pt))
            )
        case .select:
            if let idx = selectedIndex {
                if case .zoom = annotations[idx].content, !allowsZoomGeometryEditing {
                    break
                }
                selectDidDrag = true
                switch selectDragMode {
                case .moveWhole:
                    let delta = CGPoint(x: pt.x - dragOffset.x, y: pt.y - dragOffset.y)
                    var next = moved(annotations[idx].content, by: delta)
                    if case let .zoom(rect) = next {
                        next = .zoom(rect: constrainedZoomRectPreservingSize(rect))
                    } else if case let .text(origin, text, color, maxWidth) = next {
                        next = .text(
                            origin: constrainedTextOrigin(origin, text: text, maxWidth: maxWidth),
                            text: text,
                            color: color,
                            maxWidth: maxWidth
                        )
                    }
                    annotations[idx].content = next
                    dragOffset = pt
                case .arrowStart:
                    if case let .arrow(_, to, bend, color, tipStyle, pathStyle, seed) = annotations[idx].content {
                        let forceStraight = event.modifierFlags.contains(.shift)
                        let start = pt
                        let newBend = arrowEditBend(
                            from: start,
                            to: to,
                            existing: bend,
                            forceStraight: forceStraight,
                            pathStyle: pathStyle
                        )
                        annotations[idx].content = .arrow(
                            from: start,
                            to: to,
                            bend: newBend,
                            color: color,
                            tipStyle: tipStyle,
                            pathStyle: pathStyle,
                            seed: seed
                        )
                    }
                case .arrowEnd:
                    if case let .arrow(from, _, bend, color, tipStyle, pathStyle, seed) = annotations[idx].content {
                        let forceStraight = event.modifierFlags.contains(.shift)
                        let end = pt
                        let newBend = arrowEditBend(
                            from: from,
                            to: end,
                            existing: bend,
                            forceStraight: forceStraight,
                            pathStyle: pathStyle
                        )
                        annotations[idx].content = .arrow(
                            from: from,
                            to: end,
                            bend: newBend,
                            color: color,
                            tipStyle: tipStyle,
                            pathStyle: pathStyle,
                            seed: seed
                        )
                    }
                case .arrowBend:
                    if case let .arrow(from, to, _, color, tipStyle, pathStyle, seed) = annotations[idx].content,
                       pathStyle == .autoBend {
                        // Free control point; hidden corners on either side keep the path at 90°.
                        annotations[idx].content = .arrow(
                            from: from,
                            to: to,
                            bend: pt,
                            color: color,
                            tipStyle: tipStyle,
                            pathStyle: pathStyle,
                            seed: seed
                        )
                    }
                case .textWidthLeft(let anchorRight):
                    if case let .text(origin, text, color, _) = annotations[idx].content {
                        let minWidth: CGFloat = 40
                        let content = videoContentFrame
                        let minOriginX = content.minX + Self.textHPadding
                        let newOriginX = min(
                            max(pt.x + Self.textHPadding, minOriginX),
                            anchorRight - minWidth
                        )
                        let newWidth = anchorRight - newOriginX
                        annotations[idx].content = .text(
                            origin: CGPoint(x: newOriginX, y: origin.y),
                            text: text,
                            color: color,
                            maxWidth: newWidth
                        )
                    }
                case .textWidthRight(let anchorLeft):
                    if case let .text(origin, text, color, _) = annotations[idx].content {
                        let minWidth: CGFloat = 40
                        let content = videoContentFrame
                        let maxContentRight = content.maxX - Self.textHPadding
                        let newWidth = max(
                            minWidth,
                            min(pt.x - Self.textHPadding, maxContentRight) - anchorLeft
                        )
                        annotations[idx].content = .text(
                            origin: origin,
                            text: text,
                            color: color,
                            maxWidth: newWidth
                        )
                    }
                case .rectResize(let handle, let anchor):
                    if case let .rect(_, color) = annotations[idx].content {
                        annotations[idx].content = .rect(
                            rect: resizedRect(anchor: anchor, handle: handle, to: pt),
                            color: color
                        )
                    } else if case let .spotlight(_, dimOpacity, blurRadius) = annotations[idx].content {
                        annotations[idx].content = .spotlight(
                            region: resizedRect(anchor: anchor, handle: handle, to: pt),
                            dimOpacity: dimOpacity,
                            blurRadius: blurRadius
                        )
                    } else if case .zoom = annotations[idx].content {
                        annotations[idx].content = .zoom(
                            rect: resizedZoomRect(
                                anchor: anchor,
                                handle: handle,
                                to: clampPointToVideoContent(pt)
                            )
                        )
                    } else if case .crop = annotations[idx].content {
                        annotations[idx].content = .crop(
                            rect: resizedRect(anchor: anchor, handle: handle, to: pt)
                        )
                    }
                case .none:
                    break
                }
                onSelectionGeometryChanged?()
            }
        default:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { setActiveToolUse(false) }

        if selectedTool == .crop {
            cropDragMode = .none
            needsDisplay = true
            return
        }

        if selectedTool == .arrow {
            let forceStraight = event.modifierFlags.contains(.shift)
            handleArrowMouseUp(at: convert(event.locationInWindow, from: nil), forceStraight: forceStraight)
            selectDragSavedState = nil
            selectDidDrag = false
            selectDragMode = .none
            needsDisplay = true
            return
        }

        if selectedTool == .spotlight, let cur = currentAnnotation {
            if case let .spotlight(region, _, _) = cur, region.width > 2, region.height > 2 {
                commitPlacedSpotlight(cur)
            } else {
                currentAnnotation = nil
            }
            selectDragSavedState = nil
            selectDidDrag = false
            selectDragMode = .none
            needsDisplay = true
            return
        }

        if selectedTool == .zoom, let cur = currentAnnotation {
            if case let .zoom(rect) = cur, rect.width > 2, rect.height > 2 {
                commitPlacedZoom(cur)
            } else {
                currentAnnotation = nil
            }
            selectDragSavedState = nil
            selectDidDrag = false
            selectDragMode = .none
            needsDisplay = true
            return
        }

        if let cur = currentAnnotation {
            appendAnnotation(cur)
            currentAnnotation = nil
            strokePoints = []
        }
        if let saved = selectDragSavedState, selectDidDrag {
            undoStack.append(saved)
            if undoStack.count > Self.maxUndoLevels {
                undoStack.removeFirst()
            }
            redoStack.removeAll()
        }
        selectDragSavedState = nil
        selectDidDrag = false
        selectDragMode = .none
        needsDisplay = true
    }

    // MARK: Text Tool

    private func textOrigin(for field: NSTextField) -> CGPoint {
        CGPoint(
            x: field.frame.minX + Self.textHPadding,
            y: field.frame.minY + Self.textVPadding
        )
    }

    private func textPillRect(origin: CGPoint, text: String, maxWidth: CGFloat?) -> CGRect {
        textMetrics(origin: origin, text: text, maxWidth: maxWidth).pillRect
    }

    private func resizeActiveTextField() {
        guard let field = activeTextField else { return }
        let origin = textOrigin(for: field)
        let measureText = field.stringValue.isEmpty
            ? (field.placeholderString ?? " ")
            : field.stringValue
        let content = videoContentFrame
        let availableWidth = max(1, content.maxX - origin.x - Self.textHPadding)
        let unconstrained = textMetrics(origin: origin, text: measureText, maxWidth: nil)
        let maxWidth: CGFloat? = unconstrained.contentWidth > availableWidth ? availableWidth : nil
        let clampedOrigin = constrainedTextOrigin(origin, text: measureText, maxWidth: maxWidth)
        field.frame = textPillRect(origin: clampedOrigin, text: measureText, maxWidth: maxWidth)
    }

    private func placeTextField(at pt: CGPoint) {
        let placeholder = "Type here…"
        let origin = constrainedTextOrigin(pt, text: placeholder, maxWidth: nil)
        let frame = textPillRect(origin: origin, text: placeholder, maxWidth: nil)

        let field = AnnotationTextField(frame: frame)
        field.installStableEditingCell()
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = selectedColor
        field.font = textFont()
        field.placeholderString = placeholder
        field.focusRingType = .none

        field.target = self
        field.action = #selector(enterPressed(_:))
        field.onEscape = { [weak self] in
            self?.commitActiveTextField()
            self?.onEscapeAction?()
        }
        field.onTextDidChange = { [weak self] in
            self?.resizeActiveTextField()
        }
        field.delegate = self

        addSubview(field)
        activeTextField = field
        window?.makeFirstResponder(field)
        field.stabilizeFocusedEditor(selectAll: false)
    }

    @objc private func enterPressed(_ sender: Any) {
        commitActiveTextField()
        window?.makeFirstResponder(self)
    }

    func commitActiveTextField() {
        guard let field = activeTextField else { return }
        activeTextField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let origin = constrainedTextOrigin(
                textOrigin(for: field),
                text: text,
                maxWidth: nil
            )
            appendAnnotation(.text(
                origin: origin,
                text: text,
                color: field.textColor ?? selectedColor,
                maxWidth: nil
            ))
        }
        field.removeFromSuperview()
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? AnnotationTextField, field === activeTextField else { return }
        commitActiveTextField()
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleUndoRedoKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleUndoRedoKeyEquivalent(event) { return }

        let ch = event.charactersIgnoringModifiers ?? ""

        if selectedTool == .select, event.keyCode == 51, let idx = selectedIndex {
            pushUndoState()
            annotations.remove(at: idx)
            setSelectedIndex(nil)
            needsDisplay = true
            return
        }

        switch ch {
        case " ":
            guard videoMode, onTogglePlayback != nil, activeTextField == nil else {
                super.keyDown(with: event)
                return
            }
            onTogglePlayback?()
        case "s": activate(.select)
        case "d": activate(.draw)
        case "a": activate(.arrow)
        case "r": activate(.rect)
        case "f": activate(.spotlight)
        case "z": activate(.zoom)
        case "c": activate(.crop)
        case "t": activate(.text)
        case "e": activate(.emoji)
        case "\u{1B}":
            commitActiveTextField()
            guard case .idle = arrowPlacementState else {
                resetArrowPlacement()
                needsDisplay = true
                return
            }
            onEscapeAction?()
        default:
            super.keyDown(with: event)
        }
    }

    private func activate(_ tool: AnnotationTool) {
        guard allowedTools.contains(tool) else { return }
        commitActiveTextField()
        activeEmojiPicker?.close()
        activeEmojiPicker = nil
        setSelectedIndex(nil)
        selectedTool = tool
        onToolChanged?(tool)
    }

    // MARK: Select Helpers

    private enum ArrowDragTarget {
        case start, end, bend, shaft
    }

    private func arrowDragTarget(
        point: CGPoint,
        from: CGPoint,
        to: CGPoint,
        bend: CGPoint?,
        pathStyle: ArrowPathStyle
    ) -> ArrowDragTarget {
        let hitRadius: CGFloat = 8
        let bendHitRadius: CGFloat = 10
        if hypot(point.x - from.x, point.y - from.y) <= hitRadius { return .start }
        if hypot(point.x - to.x, point.y - to.y) <= hitRadius { return .end }
        if pathStyle == .autoBend {
            let bendHandle = arrowBendHandle(from: from, to: to, bend: bend)
            if hypot(point.x - bendHandle.x, point.y - bendHandle.y) <= bendHitRadius { return .bend }
        }
        return .shaft
    }

    private func beginSelectDrag(at point: CGPoint, for annotation: Annotation) {
        if case let .arrow(from, to, bend, _, _, pathStyle, _) = annotation {
            switch arrowDragTarget(point: point, from: from, to: to, bend: bend, pathStyle: pathStyle) {
            case .start: selectDragMode = .arrowStart
            case .end: selectDragMode = .arrowEnd
            case .bend: selectDragMode = .arrowBend
            case .shaft:
                selectDragMode = .moveWhole
                dragOffset = point
            }
        } else if case let .text(origin, text, _, maxWidth) = annotation {
            let metrics = textMetrics(origin: origin, text: text, maxWidth: maxWidth)
            let hitRadius: CGFloat = 8
            if hypot(point.x - metrics.leftHandle.x, point.y - metrics.leftHandle.y) <= hitRadius {
                selectDragMode = .textWidthLeft(anchorRight: metrics.origin.x + metrics.contentWidth)
            } else if hypot(point.x - metrics.rightHandle.x, point.y - metrics.rightHandle.y) <= hitRadius {
                selectDragMode = .textWidthRight(anchorLeft: metrics.origin.x)
            } else {
                selectDragMode = .moveWhole
                dragOffset = point
            }
        } else if case let .rect(rect, _) = annotation {
            if let handle = rectHitTestHandle(at: point, in: rect) {
                selectDragMode = .rectResize(handle: handle, anchor: rect)
            } else {
                selectDragMode = .moveWhole
                dragOffset = point
            }
        } else if case let .spotlight(region, _, _) = annotation {
            if let handle = rectHitTestHandle(at: point, in: region) {
                selectDragMode = .rectResize(handle: handle, anchor: region)
            } else {
                selectDragMode = .moveWhole
                dragOffset = point
            }
        } else if case let .zoom(rect) = annotation {
            if let handle = rectHitTestHandle(at: point, in: rect) {
                selectDragMode = .rectResize(handle: handle, anchor: rect)
            } else {
                selectDragMode = .moveWhole
                dragOffset = point
            }
        } else if case let .crop(rect) = annotation {
            if let handle = rectHitTestHandle(at: point, in: rect) {
                selectDragMode = .rectResize(handle: handle, anchor: rect)
            } else {
                selectDragMode = .moveWhole
                dragOffset = point
            }
        } else {
            selectDragMode = .moveWhole
            dragOffset = point
        }
    }

    private func distanceFromPoint(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func rectCornerHitTargets(in rect: CGRect) -> [(CGPoint, RectResizeHandle)] {
        [
            (CGPoint(x: rect.minX, y: rect.minY), .bottomLeft),
            (CGPoint(x: rect.maxX, y: rect.minY), .bottomRight),
            (CGPoint(x: rect.maxX, y: rect.maxY), .topRight),
            (CGPoint(x: rect.minX, y: rect.maxY), .topLeft),
        ]
    }

    private func rectInterior(of rect: CGRect) -> CGRect {
        rect.insetBy(dx: rectCornerHitRadius + 2, dy: rectCornerHitRadius + 2)
    }

    private func rectHitTestHandle(at point: CGPoint, in rect: CGRect) -> RectResizeHandle? {
        for (p, handle) in rectCornerHitTargets(in: rect) {
            if hypot(point.x - p.x, point.y - p.y) <= rectCornerHitRadius {
                return handle
            }
        }

        let t = rectEdgeHitThickness / 2
        let inset = rectCornerHitRadius

        if point.y >= rect.minY - t, point.y <= rect.minY + t,
           point.x >= rect.minX + inset, point.x <= rect.maxX - inset {
            return .bottom
        }
        if point.y >= rect.maxY - t, point.y <= rect.maxY + t,
           point.x >= rect.minX + inset, point.x <= rect.maxX - inset {
            return .top
        }
        if point.x >= rect.minX - t, point.x <= rect.minX + t,
           point.y >= rect.minY + inset, point.y <= rect.maxY - inset {
            return .left
        }
        if point.x >= rect.maxX - t, point.x <= rect.maxX + t,
           point.y >= rect.minY + inset, point.y <= rect.maxY - inset {
            return .right
        }

        return nil
    }

    private func resizedRect(anchor: CGRect, handle: RectResizeHandle, to point: CGPoint) -> CGRect {
        let minSize = rectMinSize
        var minX = anchor.minX
        var minY = anchor.minY
        var maxX = anchor.maxX
        var maxY = anchor.maxY

        switch handle {
        case .topLeft:
            minX = min(point.x, maxX - minSize)
            maxY = max(point.y, minY + minSize)
        case .top:
            maxY = max(point.y, minY + minSize)
        case .topRight:
            maxX = max(point.x, minX + minSize)
            maxY = max(point.y, minY + minSize)
        case .right:
            maxX = max(point.x, minX + minSize)
        case .bottomRight:
            maxX = max(point.x, minX + minSize)
            minY = min(point.y, maxY - minSize)
        case .bottom:
            minY = min(point.y, maxY - minSize)
        case .bottomLeft:
            minX = min(point.x, maxX - minSize)
            minY = min(point.y, maxY - minSize)
        case .left:
            minX = min(point.x, maxX - minSize)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Aspect-fit frame of the recording inside this canvas (letterbox-aware).
    private var videoContentFrame: CGRect {
        let canvasSize = bounds.size
        if videoMediaSize.width > 0, videoMediaSize.height > 0 {
            return ZoomEffect.aspectFitRect(for: videoMediaSize, in: canvasSize)
        }
        if videoAspectRatio > 0 {
            return ZoomEffect.aspectFitRect(
                for: CGSize(width: videoAspectRatio, height: 1),
                in: canvasSize
            )
        }
        return bounds
    }

    private func clampPointToVideoContent(_ point: CGPoint) -> CGPoint {
        let frame = videoContentFrame
        guard frame.width > 0, frame.height > 0 else { return point }
        return CGPoint(
            x: min(max(point.x, frame.minX), frame.maxX),
            y: min(max(point.y, frame.minY), frame.maxY)
        )
    }

    /// Keeps a text annotation's pill inside the video/recording frame.
    private func constrainedTextOrigin(
        _ origin: CGPoint,
        text: String,
        maxWidth: CGFloat?
    ) -> CGPoint {
        let frame = videoContentFrame
        guard frame.width > 0, frame.height > 0 else { return origin }
        var o = origin
        var pill = textMetrics(origin: o, text: text, maxWidth: maxWidth).pillRect
        if pill.minX < frame.minX { o.x += frame.minX - pill.minX }
        if pill.minY < frame.minY { o.y += frame.minY - pill.minY }
        pill = textMetrics(origin: o, text: text, maxWidth: maxWidth).pillRect
        if pill.maxX > frame.maxX { o.x -= pill.maxX - frame.maxX }
        if pill.maxY > frame.maxY { o.y -= pill.maxY - frame.maxY }
        return o
    }

    /// Keeps a zoom rect inside the video frame without changing its size (move).
    private func constrainedZoomRectPreservingSize(_ rect: CGRect) -> CGRect {
        let frame = videoContentFrame
        guard frame.width > 0, frame.height > 0 else { return rect }
        var moved = rect
        if moved.width > frame.width {
            moved.size.width = frame.width
            if effectiveVideoAspectRatio > 0 {
                moved.size.height = moved.width / effectiveVideoAspectRatio
            }
        }
        if moved.height > frame.height {
            moved.size.height = frame.height
            if effectiveVideoAspectRatio > 0 {
                moved.size.width = moved.height * effectiveVideoAspectRatio
            }
        }
        if moved.minX < frame.minX { moved.origin.x += frame.minX - moved.minX }
        if moved.minY < frame.minY { moved.origin.y += frame.minY - moved.minY }
        if moved.maxX > frame.maxX { moved.origin.x -= moved.maxX - frame.maxX }
        if moved.maxY > frame.maxY { moved.origin.y -= moved.maxY - frame.maxY }
        return moved
    }

    /// Caps an aspect-locked zoom so it stays inside the video frame, anchored at `origin`.
    private func sizeLimitedZoomRect(
        from origin: CGPoint,
        proposed: CGRect,
        aspectRatio: CGFloat
    ) -> CGRect {
        let frame = videoContentFrame
        guard frame.width > 0, frame.height > 0, aspectRatio > 0 else { return proposed }

        let growingRight = proposed.maxX >= origin.x - 0.5
        let growingUp = proposed.maxY >= origin.y - 0.5
        let maxWidth = growingRight ? max(0, frame.maxX - origin.x) : max(0, origin.x - frame.minX)
        let maxHeight = growingUp ? max(0, frame.maxY - origin.y) : max(0, origin.y - frame.minY)
        let limitedWidth = min(proposed.width, maxWidth, maxHeight * aspectRatio)
        let limitedHeight = limitedWidth / aspectRatio
        guard limitedWidth > 0, limitedHeight > 0 else {
            return CGRect(origin: origin, size: .zero)
        }
        return CGRect(
            x: growingRight ? origin.x : origin.x - limitedWidth,
            y: growingUp ? origin.y : origin.y - limitedHeight,
            width: limitedWidth,
            height: limitedHeight
        )
    }

    /// Aspect-locked rect from a drag origin to the current pointer (zoom tool).
    private func zoomDragRect(from origin: CGPoint, to point: CGPoint) -> CGRect {
        let ratio = effectiveVideoAspectRatio
        let originInVideo = clampPointToVideoContent(origin)
        let pointInVideo = clampPointToVideoContent(point)
        guard ratio > 0 else {
            return CGRect(
                x: min(originInVideo.x, pointInVideo.x),
                y: min(originInVideo.y, pointInVideo.y),
                width: abs(pointInVideo.x - originInVideo.x),
                height: abs(pointInVideo.y - originInVideo.y)
            )
        }
        let proposed = aspectLockedRect(
            from: originInVideo,
            to: pointInVideo,
            aspectRatio: ratio,
            minSize: 1
        )
        return sizeLimitedZoomRect(from: originInVideo, proposed: proposed, aspectRatio: ratio)
    }

    private func resizedZoomRect(anchor: CGRect, handle: RectResizeHandle, to point: CGPoint) -> CGRect {
        let ratio = effectiveVideoAspectRatio
        let pointInVideo = clampPointToVideoContent(point)
        guard ratio > 0 else {
            return constrainedZoomRectPreservingSize(
                resizedRect(anchor: anchor, handle: handle, to: pointInVideo)
            )
        }
        let proposed = aspectLockedResizedRect(
            anchor: anchor,
            handle: handle,
            to: pointInVideo,
            aspectRatio: ratio,
            minSize: rectMinSize
        )
        // Re-anchor from the fixed opposite corner/edge used by the resize handle.
        let origin: CGPoint
        switch handle {
        case .topLeft:
            origin = CGPoint(x: anchor.maxX, y: anchor.minY)
        case .topRight:
            origin = CGPoint(x: anchor.minX, y: anchor.minY)
        case .bottomRight:
            origin = CGPoint(x: anchor.minX, y: anchor.maxY)
        case .bottomLeft:
            origin = CGPoint(x: anchor.maxX, y: anchor.maxY)
        case .top, .bottom, .left, .right:
            // Edge handles grow about the center — keep the result inside by translation/size.
            return constrainedZoomRectPreservingSize(proposed)
        }
        return sizeLimitedZoomRect(from: origin, proposed: proposed, aspectRatio: ratio)
    }

    private var effectiveVideoAspectRatio: CGFloat {
        if videoAspectRatio > 0 { return videoAspectRatio }
        // Fallback: match the canvas frame so zoom still fills without letterboxing.
        guard bounds.height > 0 else { return 0 }
        return bounds.width / bounds.height
    }

    /// Builds a rect locked to `aspectRatio` (width/height), anchored at `origin`.
    private func aspectLockedRect(
        from origin: CGPoint,
        to point: CGPoint,
        aspectRatio: CGFloat,
        minSize: CGFloat
    ) -> CGRect {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        var width = abs(dx)
        var height = abs(dy)

        if height < 0.001 || width / max(height, 0.001) > aspectRatio {
            height = width / aspectRatio
        } else {
            width = height * aspectRatio
        }

        width = max(width, minSize)
        height = max(height, minSize * (aspectRatio > 0 ? 1 / aspectRatio : 1))
        // Re-assert aspect after min-size clamp.
        if width / height > aspectRatio {
            height = width / aspectRatio
        } else {
            width = height * aspectRatio
        }

        let x = dx >= 0 ? origin.x : origin.x - width
        let y = dy >= 0 ? origin.y : origin.y - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func aspectLockedResizedRect(
        anchor: CGRect,
        handle: RectResizeHandle,
        to point: CGPoint,
        aspectRatio: CGFloat,
        minSize: CGFloat
    ) -> CGRect {
        // Opposite corner / edge stays fixed; size follows the pointer at recording aspect.
        let origin: CGPoint
        let toward: CGPoint

        switch handle {
        case .topLeft:
            origin = CGPoint(x: anchor.maxX, y: anchor.minY)
            toward = point
        case .topRight:
            origin = CGPoint(x: anchor.minX, y: anchor.minY)
            toward = point
        case .bottomRight:
            origin = CGPoint(x: anchor.minX, y: anchor.maxY)
            toward = point
        case .bottomLeft:
            origin = CGPoint(x: anchor.maxX, y: anchor.maxY)
            toward = point
        case .top:
            let height = max(abs(point.y - anchor.minY), minSize / max(aspectRatio, 0.001))
            let width = height * aspectRatio
            return CGRect(
                x: anchor.midX - width / 2,
                y: min(point.y, anchor.minY),
                width: width,
                height: height
            )
        case .bottom:
            let height = max(abs(point.y - anchor.maxY), minSize / max(aspectRatio, 0.001))
            let width = height * aspectRatio
            return CGRect(
                x: anchor.midX - width / 2,
                y: min(point.y, anchor.maxY),
                width: width,
                height: height
            )
        case .left:
            let width = max(abs(point.x - anchor.maxX), minSize)
            let height = width / aspectRatio
            return CGRect(
                x: min(point.x, anchor.maxX),
                y: anchor.midY - height / 2,
                width: width,
                height: height
            )
        case .right:
            let width = max(abs(point.x - anchor.minX), minSize)
            let height = width / aspectRatio
            return CGRect(
                x: min(point.x, anchor.minX),
                y: anchor.midY - height / 2,
                width: width,
                height: height
            )
        }

        return aspectLockedRect(from: origin, to: toward, aspectRatio: aspectRatio, minSize: minSize)
    }

    func hitTest(annotation: Annotation, point: CGPoint) -> Bool {
        switch annotation {
        case let .stroke(points, _, _, _):
            if points.count == 1, let p = points.first {
                return hypot(point.x - p.x, point.y - p.y) < 8
            }
            for i in 0 ..< points.count - 1 {
                if distanceFromPoint(point, toSegment: points[i], points[i + 1]) < 8 { return true }
            }
            return false
        case let .arrow(from, to, bend, _, _, pathStyle, seed):
            let points = arrowShaftPoints(from: from, to: to, bend: bend, pathStyle: pathStyle, seed: seed)
            for i in 0 ..< points.count - 1 {
                if distanceFromPoint(point, toSegment: points[i], points[i + 1]) < 8 { return true }
            }
            return false
        case let .rect(rect, _):
            return rectHitTestHandle(at: point, in: rect) != nil
                || rectInterior(of: rect).contains(point)
                || rect.insetBy(dx: -rectCornerHitRadius, dy: -rectCornerHitRadius).contains(point)
        case let .spotlight(region, _, _):
            return rectHitTestHandle(at: point, in: region) != nil
                || rectInterior(of: region).contains(point)
                || region.insetBy(dx: -rectCornerHitRadius, dy: -rectCornerHitRadius).contains(point)
        case let .zoom(rect):
            return rectHitTestHandle(at: point, in: rect) != nil
                || rectInterior(of: rect).contains(point)
                || rect.insetBy(dx: -rectCornerHitRadius, dy: -rectCornerHitRadius).contains(point)
        case let .crop(rect):
            return rectHitTestHandle(at: point, in: rect) != nil
                || rectInterior(of: rect).contains(point)
                || rect.insetBy(dx: -rectCornerHitRadius, dy: -rectCornerHitRadius).contains(point)
        case let .text(origin, text, _, maxWidth):
            return textMetrics(origin: origin, text: text, maxWidth: maxWidth).pillRect.contains(point)
        case let .emoji(center, _, size, _):
            return hypot(point.x - center.x, point.y - center.y) < size / 2 + 4
        }
    }

    func remapAnnotations(fromContent oldContent: CGRect, toContent newContent: CGRect) {
        guard oldContent.width > 0, oldContent.height > 0,
              newContent.width > 0, newContent.height > 0,
              oldContent != newContent else { return }

        let scale = (newContent.width / oldContent.width + newContent.height / oldContent.height) / 2
        annotations = annotations.map { placed in
            var copy = placed
            copy.content = transformed(placed.content, from: oldContent, to: newContent, scale: scale)
            return copy
        }
        if let current = currentAnnotation {
            currentAnnotation = transformed(current, from: oldContent, to: newContent, scale: scale)
        }
        needsDisplay = true
    }

    private func mapPoint(_ point: CGPoint, from oldContent: CGRect, to newContent: CGRect) -> CGPoint {
        let u = (point.x - oldContent.minX) / oldContent.width
        let v = (point.y - oldContent.minY) / oldContent.height
        return CGPoint(
            x: newContent.minX + u * newContent.width,
            y: newContent.minY + v * newContent.height
        )
    }

    private func mapRect(_ rect: CGRect, from oldContent: CGRect, to newContent: CGRect) -> CGRect {
        let topLeft = mapPoint(rect.origin, from: oldContent, to: newContent)
        let bottomRight = mapPoint(
            CGPoint(x: rect.maxX, y: rect.maxY),
            from: oldContent,
            to: newContent
        )
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }

    private func transformed(
        _ annotation: Annotation,
        from oldContent: CGRect,
        to newContent: CGRect,
        scale: CGFloat
    ) -> Annotation {
        switch annotation {
        case let .stroke(points, color, lineWidth, tool):
            return .stroke(
                points: points.map { mapPoint($0, from: oldContent, to: newContent) },
                color: color,
                lineWidth: lineWidth * scale,
                tool: tool
            )
        case let .arrow(from, to, bend, color, tipStyle, pathStyle, seed):
            return .arrow(
                from: mapPoint(from, from: oldContent, to: newContent),
                to: mapPoint(to, from: oldContent, to: newContent),
                bend: bend.map { mapPoint($0, from: oldContent, to: newContent) },
                color: color,
                tipStyle: tipStyle,
                pathStyle: pathStyle,
                seed: seed
            )
        case let .rect(rect, color):
            return .rect(rect: mapRect(rect, from: oldContent, to: newContent), color: color)
        case let .spotlight(region, dimOpacity, blurRadius):
            return .spotlight(
                region: mapRect(region, from: oldContent, to: newContent),
                dimOpacity: dimOpacity,
                blurRadius: blurRadius * scale
            )
        case let .zoom(rect):
            return .zoom(rect: mapRect(rect, from: oldContent, to: newContent))
        case let .crop(rect):
            return .crop(rect: mapRect(rect, from: oldContent, to: newContent))
        case let .text(origin, text, color, maxWidth):
            return .text(
                origin: mapPoint(origin, from: oldContent, to: newContent),
                text: text,
                color: color,
                maxWidth: maxWidth.map { $0 * scale }
            )
        case let .emoji(center, emoji, size, color):
            return .emoji(
                center: mapPoint(center, from: oldContent, to: newContent),
                emoji: emoji,
                size: size * scale,
                color: color
            )
        }
    }

    private func moved(_ annotation: Annotation, by delta: CGPoint) -> Annotation {
        switch annotation {
        case let .stroke(points, color, lineWidth, tool):
            return .stroke(
                points: points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
                color: color, lineWidth: lineWidth, tool: tool
            )
        case let .arrow(from, to, bend, color, tipStyle, pathStyle, seed):
            return .arrow(
                from: CGPoint(x: from.x + delta.x, y: from.y + delta.y),
                to: CGPoint(x: to.x + delta.x, y: to.y + delta.y),
                bend: bend.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
                color: color,
                tipStyle: tipStyle,
                pathStyle: pathStyle,
                seed: seed
            )
        case let .rect(rect, color):
            return .rect(rect: rect.offsetBy(dx: delta.x, dy: delta.y), color: color)
        case let .spotlight(region, dimOpacity, blurRadius):
            return .spotlight(
                region: region.offsetBy(dx: delta.x, dy: delta.y),
                dimOpacity: dimOpacity,
                blurRadius: blurRadius
            )
        case let .zoom(rect):
            return .zoom(rect: rect.offsetBy(dx: delta.x, dy: delta.y))
        case let .crop(rect):
            return .crop(rect: rect.offsetBy(dx: delta.x, dy: delta.y))
        case let .text(origin, text, color, maxWidth):
            return .text(
                origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y),
                text: text, color: color, maxWidth: maxWidth
            )
        case let .emoji(center, emoji, size, color):
            return .emoji(
                center: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
                emoji: emoji, size: size, color: color
            )
        }
    }

    private func boundingBox(for annotation: Annotation) -> CGRect {
        switch annotation {
        case let .stroke(points, _, lineWidth, _):
            guard !points.isEmpty else { return .zero }
            let xs = points.map(\.x), ys = points.map(\.y)
            let pad = lineWidth / 2 + 4
            return CGRect(
                x: xs.min()! - pad, y: ys.min()! - pad,
                width: xs.max()! - xs.min()! + pad * 2,
                height: ys.max()! - ys.min()! + pad * 2
            )
        case let .arrow(from, to, bend, _, _, pathStyle, seed):
            let points = arrowShaftPoints(from: from, to: to, bend: bend, pathStyle: pathStyle, seed: seed)
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            let minX = xs.min() ?? min(from.x, to.x)
            let maxX = xs.max() ?? max(from.x, to.x)
            let minY = ys.min() ?? min(from.y, to.y)
            let maxY = ys.max() ?? max(from.y, to.y)
            return CGRect(
                x: minX - 12, y: minY - 12,
                width: maxX - minX + 24, height: maxY - minY + 24
            )
        case let .rect(rect, _):
            return rect
        case let .spotlight(region, _, _):
            return region
        case let .zoom(rect):
            return rect
        case let .crop(rect):
            return rect
        case let .text(origin, text, _, maxWidth):
            return textMetrics(origin: origin, text: text, maxWidth: maxWidth).selectionRect
        case let .emoji(center, _, size, _):
            let r = size / 2 + StickerStyle.outlineWidth
            return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        }
    }

    // MARK: Flatten

    func flattenedImage(background: NSImage) -> NSImage {
        commitActiveTextField()
        guard bounds.width > 0, bounds.height > 0 else { return background }

        let cropRect: CGRect? = {
            if selectedTool == .crop, let rect = cropEditingRect, !isFullBoundsCrop(rect), rect.width > 1, rect.height > 1 {
                return rect
            }
            return annotations.compactMap { placed -> CGRect? in
                if case .crop(let rect) = placed.content { return rect }
                return nil
            }.last
        }()

        let canvasSize = bounds.size
        let imageSize = background.size

        if let crop = cropRect, crop.width > 1, crop.height > 1 {
            let sx = imageSize.width / canvasSize.width
            let sy = imageSize.height / canvasSize.height
            let imageCrop = CGRect(
                x: (crop.origin.x * sx).rounded(),
                y: (crop.origin.y * sy).rounded(),
                width: (crop.width * sx).rounded(),
                height: (crop.height * sy).rounded()
            )
            let croppedBackground = Self.croppedImage(background, to: imageCrop)
            let offset = CGPoint(x: -crop.origin.x, y: -crop.origin.y)
            let outputCanvasSize = crop.size
            return flattenedImage(
                background: croppedBackground,
                at: playbackTime,
                outputSize: CGSize(
                    width: (outputCanvasSize.width * sx).rounded(),
                    height: (outputCanvasSize.height * sy).rounded()
                ),
                mapFromCanvasSize: canvasSize,
                annotationOffset: offset,
                skipCropOverlays: true
            )
        }

        return flattenedImage(
            background: background,
            at: playbackTime,
            outputSize: canvasSize,
            mapFromCanvasSize: canvasSize
        )
    }

    private static func croppedImage(_ image: NSImage, to rect: CGRect) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cgImage.cropping(to: rect) else { return image }
        return NSImage(cgImage: cropped, size: rect.size)
    }

    func flattenedImage(
        background: NSImage,
        at time: Double,
        outputSize: CGSize,
        mapFromCanvasSize canvasSize: CGSize,
        annotationOffset: CGPoint = .zero,
        skipCropOverlays: Bool = false
    ) -> NSImage {
        commitActiveTextField()
        guard outputSize.width > 0, outputSize.height > 0 else { return background }

        let result = NSImage(size: outputSize)
        result.lockFocus()
        defer { result.unlockFocus() }

        background.draw(
            in: NSRect(origin: .zero, size: outputSize),
            from: NSRect(origin: .zero, size: background.size),
            operation: .sourceOver,
            fraction: 1.0
        )

        let previousBackground = stageBackgroundImage
        stageBackgroundImage = background
        defer { stageBackgroundImage = previousBackground }

        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if canvasSize.width > 0, canvasSize.height > 0,
               outputSize.width != canvasSize.width || outputSize.height != canvasSize.height {
                let sx = outputSize.width / canvasSize.width
                let sy = outputSize.height / canvasSize.height
                ctx.scaleBy(x: sx, y: sy)
            }
            let renderBounds = CGRect(origin: .zero, size: canvasSize)
            renderSpotlightLayers(
                annotations: annotations,
                current: nil,
                at: time,
                in: ctx,
                canvasBounds: renderBounds,
                annotationOffset: annotationOffset
            )
            for placed in annotations {
                if !videoMode || placed.isVisible(at: time) {
                    if case .zoom = placed.content { continue }
                    if case .spotlight = placed.content { continue }
                    if skipCropOverlays, case .crop = placed.content { continue }
                    let content = annotationOffset == .zero
                        ? placed.content
                        : moved(placed.content, by: annotationOffset)
                    render(content, in: ctx)
                }
            }
        }

        return result
    }

    func makeExportSnapshot() -> AnnotationExportSnapshot {
        commitActiveTextField()
        return AnnotationExportSnapshot(annotations: annotations, canvasSize: bounds.size)
    }

    /// Renders a single export frame using a frozen annotation snapshot. Must run on the main thread.
    func flattenedImageForExport(
        background: NSImage,
        at time: Double,
        outputSize: CGSize,
        mapFromCanvasSize canvasSize: CGSize,
        annotations: [PlacedAnnotation]
    ) -> NSImage {
        guard outputSize.width > 0, outputSize.height > 0 else { return background }

        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else {
            return background
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        background.draw(
            in: NSRect(origin: .zero, size: outputSize),
            from: NSRect(origin: .zero, size: background.size),
            operation: .sourceOver,
            fraction: 1.0
        )

        let previousBackground = stageBackgroundImage
        stageBackgroundImage = background
        defer { stageBackgroundImage = previousBackground }

        let ctx = graphicsContext.cgContext
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if canvasSize.width > 0, canvasSize.height > 0,
           outputSize.width != canvasSize.width || outputSize.height != canvasSize.height {
            let sx = outputSize.width / canvasSize.width
            let sy = outputSize.height / canvasSize.height
            ctx.scaleBy(x: sx, y: sy)
        }
        let renderBounds = CGRect(origin: .zero, size: canvasSize)
        renderSpotlightLayers(
            annotations: annotations,
            current: nil,
            at: time,
            in: ctx,
            canvasBounds: renderBounds
        )
        for placed in annotations {
            if placed.isVisible(at: time) {
                if case .zoom = placed.content { continue }
                if case .spotlight = placed.content { continue }
                render(placed.content, in: ctx)
            }
        }

        let result = NSImage(size: outputSize)
        result.addRepresentation(rep)
        return result
    }
}

// MARK: - CircleColorButton

final class CircleColorButton: NSButton {
    var color: NSColor
    var isCustomSlot: Bool = false
    var customPreviewColor: NSColor?
    /// Insets the drawn circle within the button bounds; hit area stays full `bounds`.
    var visualInset: CGFloat = 0

    var isColorSelected: Bool = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor, isCustomSlot: Bool = false, visualInset: CGFloat = 0) {
        self.color = color
        self.isCustomSlot = isCustomSlot
        self.visualInset = visualInset
        super.init(frame: .zero)
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dotBounds = bounds.insetBy(dx: visualInset, dy: visualInset)

        if isCustomSlot {
            drawCustomSlot(in: dotBounds, context: ctx)
        } else {
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: dotBounds)
        }

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokeEllipse(in: dotBounds.insetBy(dx: 0.25, dy: 0.25))

        if isColorSelected {
            let ringColor: NSColor = {
                if isCustomSlot {
                    return (customPreviewColor ?? NSColor.secondaryLabelColor).darkenedPaletteSteps()
                }
                return color.darkenedPaletteSteps()
            }()
            let ringWidth: CGFloat = 3
            ctx.setStrokeColor(ringColor.cgColor)
            ctx.setLineWidth(ringWidth)
            ctx.strokeEllipse(in: dotBounds.insetBy(dx: -ringWidth / 2, dy: -ringWidth / 2))
        }
    }

    private func drawCustomSlot(in rect: NSRect, context ctx: CGContext) {
        if let preview = customPreviewColor {
            ctx.setFillColor(preview.cgColor)
            ctx.fillEllipse(in: rect)
        } else {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: rect)
        }

        let ring = rect.insetBy(dx: 1.5, dy: 1.5)
        let segments = 24
        let center = CGPoint(x: ring.midX, y: ring.midY)
        let radius = min(ring.width, ring.height) / 2
        ctx.setLineWidth(2.5)
        for i in 0..<segments {
            let t0 = CGFloat(i) / CGFloat(segments)
            let t1 = CGFloat(i + 1) / CGFloat(segments)
            let c0 = NSColor(calibratedHue: t0, saturation: 0.95, brightness: 0.95, alpha: 1)
            let c1 = NSColor(calibratedHue: t1, saturation: 0.95, brightness: 0.95, alpha: 1)
            ctx.setStrokeColor(c0.cgColor)
            let a0 = t0 * .pi * 2 - .pi / 2
            let a1 = t1 * .pi * 2 - .pi / 2
            ctx.beginPath()
            ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
            ctx.strokePath()
            _ = c1
        }

        if customPreviewColor == nil {
            let plus = min(rect.width, rect.height) * 0.22
            ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: rect.midX - plus, y: rect.midY))
            ctx.addLine(to: CGPoint(x: rect.midX + plus, y: rect.midY))
            ctx.move(to: CGPoint(x: rect.midX, y: rect.midY - plus))
            ctx.addLine(to: CGPoint(x: rect.midX, y: rect.midY + plus))
            ctx.strokePath()
        }
    }
}

// MARK: - Color Grid Menu

final class ColorGridMenuPanel: NSObject {

    private let panel: NSPanel
    private let onSelectPalette: (Int) -> Void
    private let onSelectCustom: () -> Void
    private var colorButtons: [Int: CircleColorButton] = [:]
    private var customButton: CircleColorButton!
    private var clickOutsideMonitor: Any?
    private var anchorScreenRect: NSRect = .zero
    private var customPreviewColor: NSColor?
    var onVisibilityChanged: (() -> Void)?

    init(onSelectPalette: @escaping (Int) -> Void, onSelectCustom: @escaping () -> Void) {
        self.onSelectPalette = onSelectPalette
        self.onSelectCustom = onSelectCustom

        let cellSz: CGFloat = 28
        let dotInset: CGFloat = 6
        let gap: CGFloat = 6
        let pad: CGFloat = 8
        let cols: CGFloat = 3
        let panelW = pad * 2 + cols * cellSz + (cols - 1) * gap
        let panelH = panelW

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.hidesOnDeactivate = true

        super.init()
        buildUI(cellSz: cellSz, dotInset: dotInset, gap: gap, pad: pad)
    }

    private func buildUI(cellSz: CGFloat, dotInset: CGFloat, gap: CGFloat, pad: CGFloat) {
        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let vfx = NSVisualEffectView(frame: container.bounds)
        vfx.autoresizingMask = [.width, .height]
        vfx.material = .popover
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = DesignTokens.Radius.lg
        vfx.layer?.masksToBounds = true
        container.addSubview(vfx)

        for (i, color) in NSColor.annotationPalette.enumerated() {
            let row = i / 3
            let col = i % 3
            let x = pad + CGFloat(col) * (cellSz + gap)
            let y = pad + CGFloat(2 - row) * (cellSz + gap)
            let btn = CircleColorButton(color: color, visualInset: dotInset)
            btn.frame = CGRect(x: x, y: y, width: cellSz, height: cellSz)
            btn.tag = i
            btn.target = self
            btn.action = #selector(paletteTapped(_:))
            container.addSubview(btn)
            colorButtons[i] = btn
        }

        let customBtn = CircleColorButton(color: .white, isCustomSlot: true, visualInset: dotInset)
        customBtn.frame = CGRect(
            x: pad + 2 * (cellSz + gap),
            y: pad,
            width: cellSz,
            height: cellSz
        )
        customBtn.target = self
        customBtn.action = #selector(customTapped)
        container.addSubview(customBtn)
        customButton = customBtn

        panel.contentView = container
    }

    func show(
        aboveScreenRect buttonRect: NSRect,
        selectedColor: NSColor,
        customPreviewColor: NSColor?
    ) {
        hide()
        self.anchorScreenRect = buttonRect
        self.customPreviewColor = customPreviewColor
        customButton.customPreviewColor = customPreviewColor

        let paletteIdx = NSColor.paletteIndex(matching: selectedColor)
        for (i, btn) in colorButtons {
            btn.isColorSelected = (i == paletteIdx)
        }
        customButton.isColorSelected = (paletteIdx == nil)

        let panelW = panel.frame.width
        let panelX = (buttonRect.midX - panelW / 2).rounded()
        let panelY = buttonRect.maxY + 6
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.orderFront(nil)
        onVisibilityChanged?()

        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let contentView = self.panel.contentView {
                let point = contentView.convert(event.locationInWindow, from: nil)
                if contentView.bounds.contains(point) { return event }
            }
            if self.anchorScreenRect.contains(NSEvent.mouseLocation) { return event }
            self.hide()
            return event
        }
    }

    func hide() {
        let wasVisible = panel.isVisible
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        panel.orderOut(nil)
        if wasVisible { onVisibilityChanged?() }
    }

    var isVisible: Bool { panel.isVisible }

    @objc private func paletteTapped(_ sender: NSButton) {
        hide()
        onSelectPalette(sender.tag)
    }

    @objc private func customTapped() {
        hide()
        onSelectCustom()
    }
}

// MARK: - Figma-Style Color Picker

private final class ColorPickerSBView: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var saturation: CGFloat = 1
    var brightness: CGFloat = 1
    var onChanged: ((CGFloat, CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds

        let hueColor = NSColor(calibratedHue: hue, saturation: 1, brightness: 1, alpha: 1)
        ctx.setFillColor(hueColor.cgColor)
        ctx.fill(b)

        let white = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            white,
            start: CGPoint(x: b.minX, y: b.midY),
            end: CGPoint(x: b.maxX, y: b.midY),
            options: []
        )

        let black = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            black,
            start: CGPoint(x: b.midX, y: b.minY),
            end: CGPoint(x: b.midX, y: b.maxY),
            options: []
        )

        let x = b.minX + saturation * b.width
        let y = b.minY + (1 - brightness) * b.height
        let indicator = CGRect(x: x - 5, y: y - 5, width: 10, height: 10)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth( 2)
        ctx.strokeEllipse(in: indicator)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: indicator.insetBy(dx: 1, dy: 1))
    }

    private func update(from event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        saturation = min(1, max(0, loc.x / bounds.width))
        brightness = min(1, max(0, 1 - loc.y / bounds.height))
        onChanged?(saturation, brightness)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { update(from: event) }
    override func mouseDragged(with event: NSEvent) { update(from: event) }
}

private final class ColorPickerHueSlider: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var onChanged: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let steps = 60
        let stepW = b.width / CGFloat(steps)
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            let color = NSColor(calibratedHue: t, saturation: 1, brightness: 1, alpha: 1)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: b.minX + CGFloat(i) * stepW, y: b.minY, width: stepW + 1, height: b.height))
        }

        let x = b.minX + hue * b.width
        let thumb = CGRect(x: x - 4, y: b.midY - 6, width: 8, height: 12)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(thumb)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(thumb)
    }

    private func update(from event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        hue = min(1, max(0, loc.x / bounds.width))
        onChanged?(hue)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { update(from: event) }
    override func mouseDragged(with event: NSEvent) { update(from: event) }
}

final class FigmaStyleColorPickerPanel: NSObject, NSTextFieldDelegate {

    private let panel: NSPanel
    private let onColorChanged: (NSColor) -> Void
    private var clickOutsideMonitor: Any?
    private var anchorScreenRect: NSRect = .zero

    private var hue: CGFloat = 0
    private var saturation: CGFloat = 1
    private var brightness: CGFloat = 1

    private let sbView = ColorPickerSBView()
    private let hueSlider = ColorPickerHueSlider()
    private let hexField = NSTextField()
    private let previewSwatch = NSView()
    private var isUpdatingHex = false
    var onVisibilityChanged: (() -> Void)?

    init(onColorChanged: @escaping (NSColor) -> Void) {
        self.onColorChanged = onColorChanged

        let pad: CGFloat = 10
        let sbSize: CGFloat = 200
        let hueH: CGFloat = 14
        let rowH: CGFloat = 24
        let gap: CGFloat = 8
        let panelW = pad * 2 + sbSize
        let panelH = pad + sbSize + gap + hueH + gap + rowH + pad

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        super.init()
        buildUI(pad: pad, sbSize: sbSize, hueH: hueH, rowH: rowH, gap: gap)
    }

    private func buildUI(pad: CGFloat, sbSize: CGFloat, hueH: CGFloat, rowH: CGFloat, gap: CGFloat) {
        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let vfx = NSVisualEffectView(frame: container.bounds)
        vfx.autoresizingMask = [.width, .height]
        vfx.material = .popover
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = DesignTokens.Radius.lg
        vfx.layer?.masksToBounds = true
        container.addSubview(vfx)

        var y = pad

        sbView.frame = CGRect(x: pad, y: y, width: sbSize, height: sbSize)
        sbView.wantsLayer = true
        sbView.layer?.cornerRadius = DesignTokens.Radius.md
        sbView.layer?.masksToBounds = true
        sbView.onChanged = { [weak self] sat, bri in
            self?.setSaturationBrightness(saturation: sat, brightness: bri)
        }
        container.addSubview(sbView)
        y += sbSize + gap

        hueSlider.frame = CGRect(x: pad, y: y, width: sbSize, height: hueH)
        hueSlider.wantsLayer = true
        hueSlider.layer?.cornerRadius = DesignTokens.Radius.sm
        hueSlider.layer?.masksToBounds = true
        hueSlider.onChanged = { [weak self] h in
            self?.setHue(h)
        }
        container.addSubview(hueSlider)
        y += hueH + gap

        previewSwatch.frame = CGRect(x: pad, y: y, width: rowH, height: rowH)
        previewSwatch.wantsLayer = true
        previewSwatch.layer?.cornerRadius = DesignTokens.Radius.sm
        previewSwatch.layer?.borderWidth = 1
        previewSwatch.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        container.addSubview(previewSwatch)

        hexField.frame = CGRect(x: pad + rowH + 8, y: y, width: sbSize - rowH - 8, height: rowH)
        hexField.isBezeled = true
        hexField.bezelStyle = .roundedBezel
        hexField.font = NSFont.monospacedSystemFont(ofSize: DesignTokens.Typography.label.size, weight: .regular)
        hexField.placeholderString = "Hex"
        hexField.delegate = self
        container.addSubview(hexField)

        panel.contentView = container
    }

    func show(aboveScreenRect buttonRect: NSRect, initialColor: NSColor) {
        hide()
        anchorScreenRect = buttonRect
        setColor(initialColor, notify: false)

        let panelW = panel.frame.width
        let panelX = (buttonRect.midX - panelW / 2).rounded()
        let panelY = buttonRect.maxY + 6
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.makeKeyAndOrderFront(nil)
        onVisibilityChanged?()

        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let contentView = self.panel.contentView {
                let point = contentView.convert(event.locationInWindow, from: nil)
                if contentView.bounds.contains(point) { return event }
            }
            if self.anchorScreenRect.contains(NSEvent.mouseLocation) { return event }
            self.hide()
            return event
        }
    }

    func hide() {
        let wasVisible = panel.isVisible
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        panel.orderOut(nil)
        if wasVisible { onVisibilityChanged?() }
    }

    var isVisible: Bool { panel.isVisible }

    private func currentColor() -> NSColor {
        NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private func setColor(_ color: NSColor, notify: Bool) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (color.usingColorSpace(.deviceRGB) ?? color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = h.isNaN ? 0 : h
        saturation = s
        brightness = b
        syncViews(notify: notify)
    }

    private func setHue(_ h: CGFloat) {
        hue = h
        syncViews(notify: true)
    }

    private func setSaturationBrightness(saturation s: CGFloat, brightness b: CGFloat) {
        saturation = s
        brightness = b
        syncViews(notify: true)
    }

    private func syncViews(notify: Bool) {
        sbView.hue = hue
        sbView.saturation = saturation
        sbView.brightness = brightness
        hueSlider.hue = hue
        sbView.needsDisplay = true
        hueSlider.needsDisplay = true
        previewSwatch.layer?.backgroundColor = currentColor().cgColor

        isUpdatingHex = true
        hexField.stringValue = "#\(currentColor().hexString)"
        isUpdatingHex = false

        if notify {
            onColorChanged(currentColor())
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isUpdatingHex, obj.object as? NSTextField === hexField else { return }
        guard let color = NSColor(hexString: hexField.stringValue) else { return }
        setColor(color, notify: true)
    }
}

// MARK: - ToolTooltipPanel

final class ToolTooltipPanel: NSPanel {

    private let nameLabel: NSTextField
    private let shortcutLabel: NSTextField
    private let box: NSView

    init() {
        box = NSView(frame: .zero)
        nameLabel = NSTextField(labelWithString: "")
        shortcutLabel = NSTextField(labelWithString: "")

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 26),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        hasShadow = true
        ignoresMouseEvents = true

        box.wantsLayer = true
        box.layer?.backgroundColor = DesignTokens.Palette.neutral[.t900].ns.cgColor
        box.layer?.cornerRadius = 2

        nameLabel.font = NSFont.grabbit(.label)
        nameLabel.textColor = .white
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.drawsBackground = false

        shortcutLabel.font = NSFont.grabbit(.caption)
        shortcutLabel.textColor = NSColor.white.withAlphaComponent(0.48)
        shortcutLabel.isBezeled = false
        shortcutLabel.isEditable = false
        shortcutLabel.drawsBackground = false

        box.addSubview(nameLabel)
        box.addSubview(shortcutLabel)
        contentView = box
    }

    func show(for tool: AnnotationTool, aboveScreenRect buttonRect: NSRect) {
        nameLabel.stringValue = tool.displayName
        shortcutLabel.stringValue = tool.shortcutKey

        nameLabel.sizeToFit()
        shortcutLabel.sizeToFit()

        let hPad: CGFloat = 8
        let vPad: CGFloat = 5
        let gap: CGFloat = 5

        let nw = nameLabel.frame.width
        let nh = nameLabel.frame.height
        let sw = shortcutLabel.frame.width
        let sh = shortcutLabel.frame.height

        let totalW = hPad + nw + gap + sw + hPad
        let totalH = vPad + max(nh, sh) + vPad

        nameLabel.frame = NSRect(x: hPad, y: vPad, width: nw, height: nh)
        shortcutLabel.frame = NSRect(
            x: hPad + nw + gap,
            y: vPad + (nh - sh) / 2,
            width: sw, height: sh
        )
        box.frame = NSRect(x: 0, y: 0, width: totalW, height: totalH)

        let panelX = (buttonRect.midX - totalW / 2).rounded()
        let panelY = buttonRect.maxY + 6
        let finalFrame = NSRect(x: panelX, y: panelY, width: totalW, height: totalH)
        let startFrame = NSRect(x: panelX, y: panelY - 6, width: totalW, height: totalH)

        setFrame(startFrame, display: false)
        alphaValue = 0
        orderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(finalFrame, display: true)
        }
    }

    func hide() { orderOut(nil) }
}

// MARK: - View background (file setting)

enum AnnotationViewBackground {
    static let presetStyles: [RecordingBackgroundStyle] = [.none, .warm, .cool, .midnight]

    static func stageLayout(
        for screenshotSize: NSSize,
        background: RecordingBackgroundStyle
    ) -> (stage: NSSize, contentFrame: NSRect) {
        guard background != .none else {
            let stage = fittedStageSize(screenshotSize)
            return (stage, NSRect(origin: .zero, size: stage))
        }

        let canvasSize = RecordingBackgroundRenderer.canvasSize(for: 1)
        let stage = fittedStageSize(canvasSize)
        let content = RecordingBackgroundRenderer.windowFrame(
            inCanvas: screenshotSize,
            canvasSize: canvasSize
        )
        let scale = stage.width / canvasSize.width
        let contentFrame = NSRect(
            x: (content.origin.x * scale).rounded(),
            y: (content.origin.y * scale).rounded(),
            width: (content.width * scale).rounded(),
            height: (content.height * scale).rounded()
        )
        return (stage, contentFrame)
    }

    static func fittedStageSize(_ size: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: 800, height: 600) }
        let scale = min(1200 / size.width, 800 / size.height, 1.0)
        return NSSize(
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )
    }

    static func renderStage(
        screenshot: NSImage,
        layout: (stage: NSSize, contentFrame: NSRect),
        background: RecordingBackgroundStyle
    ) -> NSImage {
        let size = layout.stage
        guard size.width > 0, size.height > 0 else { return screenshot }

        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else {
            return screenshot
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        if background != .none,
           let bg = RecordingBackgroundRenderer.backgroundPreviewImage(for: background) {
            bg.draw(
                in: NSRect(origin: .zero, size: size),
                from: NSRect(origin: .zero, size: bg.size),
                operation: .sourceOver,
                fraction: 1
            )
        }

        screenshot.draw(
            in: layout.contentFrame,
            from: NSRect(origin: .zero, size: screenshot.size),
            operation: .sourceOver,
            fraction: 1
        )

        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }
}

// MARK: - DrawStyleMenuPanel

final class DrawStyleMenuPanel: NSObject {

    private let panel: NSPanel
    private let onSelect: (StrokeTool) -> Void
    private var styleButtons: [StrokeTool: NSButton] = [:]
    private var clickOutsideMonitor: Any?
    private var accentColor: NSColor = .systemBlue
    private var anchorScreenRect: NSRect = .zero
    private var selectedStyle: StrokeTool = .marker
    var onVisibilityChanged: (() -> Void)?

    init(onSelect: @escaping (StrokeTool) -> Void) {
        self.onSelect = onSelect

        let btnSz: CGFloat = 32
        let gap: CGFloat = 4
        let pad: CGFloat = 6
        let count = CGFloat(StrokeTool.allCases.count)
        let panelW = pad * 2 + btnSz
        let panelH = pad * 2 + count * btnSz + (count - 1) * gap

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.hidesOnDeactivate = true

        super.init()
        buildUI(btnSz: btnSz, gap: gap, pad: pad)
    }

    private func buildUI(btnSz: CGFloat, gap: CGFloat, pad: CGFloat) {
        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let vfx = NSVisualEffectView(frame: container.bounds)
        vfx.autoresizingMask = [.width, .height]
        vfx.material = .popover
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = DesignTokens.Radius.lg
        vfx.layer?.masksToBounds = true
        container.addSubview(vfx)

        var y = pad
        for (index, style) in StrokeTool.allCases.enumerated() {
            let btn = NSButton(frame: CGRect(x: pad, y: y, width: btnSz, height: btnSz))
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            let cfg = NSImage.SymbolConfiguration(pointSize: style.menuSymbolPointSize, weight: .medium)
            btn.image = NSImage(systemSymbolName: style.menuSymbol, accessibilityDescription: style.accessibilityLabel)?
                .withSymbolConfiguration(cfg)
            btn.imageScaling = .scaleProportionallyDown
            btn.wantsLayer = true
            btn.layer?.cornerRadius = DesignTokens.Radius.md
            btn.target = self
            btn.action = #selector(styleTapped(_:))
            btn.tag = index
            btn.toolTip = style.accessibilityLabel
            container.addSubview(btn)
            styleButtons[style] = btn
            y += btnSz + gap
        }

        panel.contentView = container
    }

    func show(
        aboveScreenRect buttonRect: NSRect,
        selectedStyle: StrokeTool,
        accentColor: NSColor
    ) {
        hide()
        self.accentColor = accentColor
        self.anchorScreenRect = buttonRect
        self.selectedStyle = selectedStyle
        refreshSelection()

        let panelW = panel.frame.width
        let panelX = (buttonRect.midX - panelW / 2).rounded()
        let panelY = buttonRect.maxY + 6
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.orderFront(nil)
        onVisibilityChanged?()

        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let contentView = self.panel.contentView {
                let point = contentView.convert(event.locationInWindow, from: nil)
                if contentView.bounds.contains(point) { return event }
            }
            if self.anchorScreenRect.contains(NSEvent.mouseLocation) { return event }
            self.hide()
            return event
        }
    }

    func hide() {
        let wasVisible = panel.isVisible
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        panel.orderOut(nil)
        if wasVisible { onVisibilityChanged?() }
    }

    var isVisible: Bool { panel.isVisible }

    private func refreshSelection() {
        for (style, btn) in styleButtons {
            let on = style == selectedStyle
            btn.contentTintColor = on ? accentColor : .labelColor
            btn.layer?.backgroundColor = on ? accentColor.withAlphaComponent(0.2).cgColor : .clear
        }
    }

    @objc private func styleTapped(_ sender: NSButton) {
        let styles = StrokeTool.allCases
        guard sender.tag < styles.count else { return }
        selectedStyle = styles[sender.tag]
        refreshSelection()
        hide()
        onSelect(selectedStyle)
    }
}

// MARK: - ArrowStyleMenuPanel

final class ArrowStyleMenuPanel: NSObject {

    private let panel: NSPanel
    private let onTipSelect: (ArrowTipStyle) -> Void
    private let onPathSelect: (ArrowPathStyle) -> Void
    private var tipButtons: [ArrowTipStyle: NSButton] = [:]
    private var pathButtons: [ArrowPathStyle: NSButton] = [:]
    private var clickOutsideMonitor: Any?
    private var accentColor: NSColor = .systemBlue
    private var anchorScreenRect: NSRect = .zero
    private var selectedTipStyle: ArrowTipStyle = .solid
    private var selectedPathStyle: ArrowPathStyle = .autoBend
    var onVisibilityChanged: (() -> Void)?

    private let tipTagBase = 0
    private let pathTagBase = 100

    init(
        onTipSelect: @escaping (ArrowTipStyle) -> Void,
        onPathSelect: @escaping (ArrowPathStyle) -> Void
    ) {
        self.onTipSelect = onTipSelect
        self.onPathSelect = onPathSelect

        let btnSz: CGFloat = 32
        let gap: CGFloat = 4
        let pad: CGFloat = 6
        let separatorH: CGFloat = 9
        let tipCount = CGFloat(ArrowTipStyle.allCases.count)
        let pathCount = CGFloat(ArrowPathStyle.allCases.count)
        let panelW = pad * 2 + btnSz
        let panelH = pad * 2
            + tipCount * btnSz + (tipCount - 1) * gap
            + separatorH
            + pathCount * btnSz + (pathCount - 1) * gap

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.hidesOnDeactivate = true

        super.init()
        buildUI(btnSz: btnSz, gap: gap, pad: pad, separatorH: separatorH)
    }

    private func buildUI(btnSz: CGFloat, gap: CGFloat, pad: CGFloat, separatorH: CGFloat) {
        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let vfx = NSVisualEffectView(frame: container.bounds)
        vfx.autoresizingMask = [.width, .height]
        vfx.material = .popover
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = DesignTokens.Radius.lg
        vfx.layer?.masksToBounds = true
        container.addSubview(vfx)

        // Bottom group (closest to toolbar): tip styles. Top group: path styles.
        var y = pad
        for (index, style) in ArrowTipStyle.allCases.enumerated() {
            let btn = makeStyleButton(
                symbol: style.menuSymbol,
                pointSize: style.menuSymbolPointSize,
                label: style.accessibilityLabel,
                tag: tipTagBase + index,
                frame: CGRect(x: pad, y: y, width: btnSz, height: btnSz)
            )
            container.addSubview(btn)
            tipButtons[style] = btn
            y += btnSz + gap
        }

        y -= gap
        let separator = NSView(frame: CGRect(x: pad + 4, y: y + (separatorH - 1) / 2, width: btnSz - 8, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        container.addSubview(separator)
        y += separatorH

        for (index, style) in ArrowPathStyle.allCases.enumerated() {
            let btn = makeStyleButton(
                symbol: style.menuSymbol,
                pointSize: style.menuSymbolPointSize,
                label: style.accessibilityLabel,
                tag: pathTagBase + index,
                frame: CGRect(x: pad, y: y, width: btnSz, height: btnSz)
            )
            container.addSubview(btn)
            pathButtons[style] = btn
            y += btnSz + gap
        }

        panel.contentView = container
    }

    private func makeStyleButton(
        symbol: String,
        pointSize: CGFloat,
        label: String,
        tag: Int,
        frame: CGRect
    ) -> NSButton {
        let btn = NSButton(frame: frame)
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(cfg)
        btn.imageScaling = .scaleProportionallyDown
        btn.wantsLayer = true
        btn.layer?.cornerRadius = DesignTokens.Radius.md
        btn.target = self
        btn.action = #selector(styleTapped(_:))
        btn.tag = tag
        btn.toolTip = label
        return btn
    }

    func show(
        aboveScreenRect buttonRect: NSRect,
        selectedTipStyle: ArrowTipStyle,
        selectedPathStyle: ArrowPathStyle,
        accentColor: NSColor
    ) {
        hide()
        self.accentColor = accentColor
        self.anchorScreenRect = buttonRect
        self.selectedTipStyle = selectedTipStyle
        self.selectedPathStyle = selectedPathStyle
        refreshSelection()

        let panelW = panel.frame.width
        let panelX = (buttonRect.midX - panelW / 2).rounded()
        let panelY = buttonRect.maxY + 6
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.orderFront(nil)
        onVisibilityChanged?()

        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let contentView = self.panel.contentView {
                let point = contentView.convert(event.locationInWindow, from: nil)
                if contentView.bounds.contains(point) { return event }
            }
            if self.anchorScreenRect.contains(NSEvent.mouseLocation) { return event }
            self.hide()
            return event
        }
    }

    func hide() {
        let wasVisible = panel.isVisible
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        panel.orderOut(nil)
        if wasVisible { onVisibilityChanged?() }
    }

    var isVisible: Bool { panel.isVisible }

    private func refreshSelection() {
        for (style, btn) in tipButtons {
            let on = style == selectedTipStyle
            btn.contentTintColor = on ? accentColor : .labelColor
            btn.layer?.backgroundColor = on ? accentColor.withAlphaComponent(0.2).cgColor : .clear
        }
        for (style, btn) in pathButtons {
            let on = style == selectedPathStyle
            btn.contentTintColor = on ? accentColor : .labelColor
            btn.layer?.backgroundColor = on ? accentColor.withAlphaComponent(0.2).cgColor : .clear
        }
    }

    @objc private func styleTapped(_ sender: NSButton) {
        if sender.tag >= pathTagBase {
            let styles = ArrowPathStyle.allCases
            let index = sender.tag - pathTagBase
            guard index < styles.count else { return }
            selectedPathStyle = styles[index]
            refreshSelection()
            hide()
            onPathSelect(selectedPathStyle)
            return
        }

        let styles = ArrowTipStyle.allCases
        guard sender.tag < styles.count else { return }
        selectedTipStyle = styles[sender.tag]
        refreshSelection()
        hide()
        onTipSelect(selectedTipStyle)
    }
}

// MARK: - Spotlight panel chrome

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private enum SpotlightPanelStyle {
    static let background = DesignTokens.Color.panelSurface.ns
    static let fieldBackground = NSColor.white
    static let fieldBorder = NSColor.black.withAlphaComponent(0.09)
    static let fieldCornerRadius: CGFloat = 5
    static let fieldHeight: CGFloat = 28
    static let panelWidth: CGFloat = 240
    static let padding: CGFloat = 12
    static let sectionGap: CGFloat = 14
    static let rowGap: CGFloat = 6
}

/// Value side of a spotlight metric field — accepts first click and key focus in a floating panel.
private final class SpotlightValueField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if window?.firstResponder !== currentEditor() {
            window?.makeFirstResponder(self)
            stabilizeFocusedEditor(selectAll: true)
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// Figma-style inline metric field: `[X  120]` on a white rounded background.
private final class SpotlightInlineField: NSView, NSTextFieldDelegate {
    let prefixLabel = NSTextField(labelWithString: "")
    let valueField = SpotlightValueField()
    var onValueChanged: (() -> Void)?

    var isEditingValue: Bool { isEditing }

    private var isHovered = false
    private var isEditing = false

    init(prefix: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = SpotlightPanelStyle.fieldBackground.cgColor
        layer?.cornerRadius = SpotlightPanelStyle.fieldCornerRadius
        updateChrome()

        prefixLabel.stringValue = prefix
        prefixLabel.font = NSFont.grabbit(.label)
        prefixLabel.textColor = DesignTokens.Color.textSecondary.ns
        prefixLabel.alignment = .left
        prefixLabel.isBezeled = false
        prefixLabel.isBordered = false
        prefixLabel.drawsBackground = false
        prefixLabel.isEditable = false
        prefixLabel.isSelectable = false

        valueField.font = NSFont.monospacedDigitSystemFont(ofSize: DesignTokens.Typography.body.size, weight: .regular)
        valueField.textColor = DesignTokens.Color.textPrimary.ns
        valueField.alignment = .right
        valueField.installStableEditingCell()
        valueField.isEditable = true
        valueField.isSelectable = true
        valueField.focusRingType = .none
        valueField.delegate = self

        addSubview(prefixLabel)
        addSubview(valueField)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateChrome()
        if !isEditing {
            NSCursor.iBeam.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateChrome()
        if !isEditing {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if window?.firstResponder !== valueField.currentEditor() {
            window?.makeFirstResponder(valueField)
            valueField.stabilizeFocusedEditor(selectAll: true)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        prefixLabel.frame = CGRect(x: pad, y: (bounds.height - 16) / 2, width: 14, height: 16)
        valueField.frame = CGRect(x: pad + 14, y: (bounds.height - 18) / 2, width: bounds.width - pad * 2 - 14, height: 18)
    }

    private func updateChrome() {
        if isEditing {
            layer?.borderWidth = 1.5
            layer?.borderColor = DesignTokens.Color.primary.ns.cgColor
        } else if isHovered {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        } else {
            layer?.borderWidth = 1
            layer?.borderColor = SpotlightPanelStyle.fieldBorder.cgColor
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditing = true
        updateChrome()
        (obj.object as? NSTextField)?.stabilizeFocusedEditor(selectAll: false)
        NSCursor.iBeam.set()
    }

    func controlTextDidChange(_ obj: Notification) {
        onValueChanged?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            adjustValue(by: 1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            adjustValue(by: -1)
            return true
        default:
            return false
        }
    }

    private func adjustValue(by delta: Int) {
        let parsed = valueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = Int(parsed) ?? 0
        let minimum = (prefixLabel.stringValue == "W" || prefixLabel.stringValue == "H") ? 1 : 0
        let next = max(minimum, current + delta)
        guard next != current else { return }
        valueField.stringValue = "\(next)"
        onValueChanged?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditing = false
        updateChrome()
        if isHovered {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
        onValueChanged?()
    }
}

/// Five-step discrete selector — inset segmented pill (no tick dots).
private final class SpotlightNotchRow: NSControl {
    var notchCount: Int = 5 {
        didSet {
            needsDisplay = true
            layoutThumb(animated: false)
        }
    }
    var selectedIndex: Int = 0 {
        didSet {
            guard oldValue != selectedIndex else { return }
            layoutThumb(animated: !suppressThumbAnimation)
        }
    }
    var onSelectionChanged: ((Int) -> Void)?

    private let thumbView = NSView()
    private var isHovered = false
    private var isDragging = false
    private var suppressThumbAnimation = false

    func setSelectedIndex(_ index: Int, animated: Bool) {
        guard index != selectedIndex else { return }
        suppressThumbAnimation = !animated
        selectedIndex = index
        suppressThumbAnimation = false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false

        thumbView.wantsLayer = true
        thumbView.layer?.backgroundColor = DesignTokens.Color.primary.cg
        thumbView.layer?.borderWidth = 0.5
        thumbView.layer?.borderColor = DesignTokens.Color.borderOnPrimary.cg
        addSubview(thumbView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func layout() {
        super.layout()
        layoutThumb(animated: false)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        if !isDragging {
            NSCursor.pointingHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        if !isDragging {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        isDragging = true
        NSCursor.closedHand.set()
        selectIndex(at: convert(event.locationInWindow, from: nil), notify: true)
    }

    override func mouseDragged(with event: NSEvent) {
        selectIndex(at: convert(event.locationInWindow, from: nil), notify: true)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: // Up
            stepSelection(by: 1)
        case 125: // Down
            stepSelection(by: -1)
        default:
            super.keyDown(with: event)
        }
    }

    private func stepSelection(by delta: Int) {
        let next = min(max(selectedIndex + delta, 0), notchCount - 1)
        guard next != selectedIndex else { return }
        selectedIndex = next
        onSelectionChanged?(next)
    }

    private func selectIndex(at point: NSPoint, notify: Bool) {
        let index = indexAt(point: point)
        guard index >= 0, index < notchCount else { return }
        guard index != selectedIndex else { return }
        selectedIndex = index
        if notify {
            onSelectionChanged?(index)
        }
    }

    private func indexAt(point: NSPoint) -> Int {
        guard bounds.width > 0, notchCount > 0 else { return 0 }
        let fraction = min(max(point.x / bounds.width, 0), 0.999)
        return Int(fraction * CGFloat(notchCount))
    }

    private var trackRect: CGRect {
        bounds.insetBy(dx: 0, dy: 2)
    }

    private func thumbFrame(for index: Int) -> CGRect {
        let track = trackRect
        guard notchCount > 0 else { return .zero }
        let segmentW = track.width / CGFloat(notchCount)
        let thumbInset: CGFloat = 2
        return CGRect(
            x: track.minX + segmentW * CGFloat(index) + thumbInset,
            y: track.minY + thumbInset,
            width: max(segmentW - thumbInset * 2, 4),
            height: track.height - thumbInset * 2
        )
    }

    private func layoutThumb(animated: Bool) {
        let target = thumbFrame(for: selectedIndex)
        thumbView.layer?.cornerRadius = target.height / 2
        thumbView.layer?.cornerCurve = .continuous

        guard animated else {
            thumbView.frame = target
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.64, 1)
            ctx.allowsImplicitAnimation = true
            thumbView.animator().frame = target
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let trackPath = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
        let trackFill = isHovered
            ? NSColor.black.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.06)
        trackFill.setFill()
        trackPath.fill()
    }
}

// MARK: - Spotlight region coordinates

/// Maps spotlight rects between canvas space (AppKit bottom-left origin) and
/// image-pixel space (top-left origin, full capture resolution).
enum SpotlightRegionCoordinates {
    static func displayRegion(
        _ canvasRegion: CGRect,
        contentFrame: CGRect,
        imagePixelSize: CGSize
    ) -> CGRect {
        guard contentFrame.width > 0, contentFrame.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0 else {
            return canvasRegion
        }
        let scaleX = imagePixelSize.width / contentFrame.width
        let scaleY = imagePixelSize.height / contentFrame.height
        return CGRect(
            x: (canvasRegion.minX - contentFrame.minX) * scaleX,
            y: (contentFrame.maxY - canvasRegion.maxY) * scaleY,
            width: canvasRegion.width * scaleX,
            height: canvasRegion.height * scaleY
        )
    }

    static func canvasRegion(
        _ displayRegion: CGRect,
        contentFrame: CGRect,
        imagePixelSize: CGSize
    ) -> CGRect {
        guard contentFrame.width > 0, contentFrame.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0 else {
            return displayRegion
        }
        let scaleX = imagePixelSize.width / contentFrame.width
        let scaleY = imagePixelSize.height / contentFrame.height
        let maxY = contentFrame.maxY - displayRegion.minY / scaleY
        return CGRect(
            x: contentFrame.minX + displayRegion.minX / scaleX,
            y: maxY - displayRegion.height / scaleY,
            width: displayRegion.width / scaleX,
            height: displayRegion.height / scaleY
        )
    }

    static func clampedDisplayRegion(_ region: CGRect, imagePixelSize: CGSize) -> CGRect {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return region }
        var r = region
        r.size.width = max(1, min(r.width, imagePixelSize.width))
        r.size.height = max(1, min(r.height, imagePixelSize.height))
        r.origin.x = max(0, min(r.origin.x, imagePixelSize.width - r.width))
        r.origin.y = max(0, min(r.origin.y, imagePixelSize.height - r.height))
        return r
    }
}

// MARK: - SpotlightOptionsPanel

final class SpotlightOptionsPanel: NSObject {

    private static let toolbarGap: CGFloat = 4

    private let panel: KeyablePanel
    private let container: NSView
    private let compactPanelHeight: CGFloat
    private let globalBannerHeight: CGFloat
    private let onDimOpacityChanged: (CGFloat) -> Void
    private let onBlurRadiusChanged: (CGFloat) -> Void
    private let onRegionChanged: (CGRect) -> Void
    private let onEditingEnded: () -> Void

    private var dimNameLabel: NSTextField!
    private var dimNotchRow: SpotlightNotchRow!
    private var blurNotchRow: SpotlightNotchRow!
    private var dimValueLabel: NSTextField!
    private var blurValueLabel: NSTextField!
    private var blurNameLabel: NSTextField!
    private var globalEffectsLabel: NSTextField!
    private var showsGlobalBanner = false
    private var xField: SpotlightInlineField!
    private var yField: SpotlightInlineField!
    private var wField: SpotlightInlineField!
    private var hField: SpotlightInlineField!
    private let numberFormatter: NumberFormatter
    private var clickOutsideMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var anchorScreenRect: NSRect = .zero
    private var toolbarAnchorScreenRect: NSRect = .zero
    var onVisibilityChanged: (() -> Void)?
    private var isUpdatingFromModel = false
    private var blurDebounceTimer: Timer?
    private var imagePixelSize: CGSize = .zero

    init(
        onDimOpacityChanged: @escaping (CGFloat) -> Void,
        onBlurRadiusChanged: @escaping (CGFloat) -> Void,
        onRegionChanged: @escaping (CGRect) -> Void,
        onEditingEnded: @escaping () -> Void
    ) {
        self.onDimOpacityChanged = onDimOpacityChanged
        self.onBlurRadiusChanged = onBlurRadiusChanged
        self.onRegionChanged = onRegionChanged
        self.onEditingEnded = onEditingEnded

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = 0
        self.numberFormatter = formatter

        let panelW = SpotlightPanelStyle.panelWidth
        let pad = SpotlightPanelStyle.padding
        let fieldH = SpotlightPanelStyle.fieldHeight
        let fieldGap: CGFloat = 8
        let fieldW = (panelW - pad * 2 - fieldGap) / 2
        let notchH: CGFloat = 20
        let metricRowH: CGFloat = 16
        let globalLabelH: CGFloat = 14

        let effectBlockH = (metricRowH + SpotlightPanelStyle.rowGap + notchH + SpotlightPanelStyle.sectionGap) * 2
        let positionBlockH = fieldH + fieldGap + fieldH
        compactPanelHeight = pad + effectBlockH + positionBlockH + pad
        globalBannerHeight = globalLabelH + SpotlightPanelStyle.rowGap

        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: compactPanelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true

        container = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: compactPanelHeight))

        super.init()

        container.wantsLayer = true
        container.layer?.backgroundColor = SpotlightPanelStyle.background.cgColor
        container.layer?.cornerRadius = DesignTokens.Radius.lg
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let globalLabel = NSTextField(labelWithString: "")
        globalLabel.font = NSFont.grabbit(.caption)
        globalLabel.textColor = DesignTokens.Color.textSecondary.ns
        globalLabel.isHidden = true
        container.addSubview(globalLabel)
        globalEffectsLabel = globalLabel

        func makeNameLabel(_ title: String) -> NSTextField {
            let nameLabel = NSTextField(labelWithString: title)
            nameLabel.font = NSFont.grabbit(.label)
            nameLabel.textColor = DesignTokens.Color.textPrimary.ns
            container.addSubview(nameLabel)
            return nameLabel
        }

        func makeValueLabel() -> NSTextField {
            let valueLabel = NSTextField(labelWithString: "")
            valueLabel.font = NSFont.grabbit(.label)
            valueLabel.textColor = DesignTokens.Color.textSecondary.ns
            valueLabel.alignment = .right
            container.addSubview(valueLabel)
            return valueLabel
        }

        dimNameLabel = makeNameLabel("Darkness")
        dimValueLabel = makeValueLabel()
        dimNotchRow = SpotlightNotchRow(frame: .zero)
        container.addSubview(dimNotchRow)

        blurNameLabel = makeNameLabel("Blurriness")
        blurValueLabel = makeValueLabel()
        blurNotchRow = SpotlightNotchRow(frame: .zero)
        container.addSubview(blurNotchRow)

        xField = SpotlightInlineField(prefix: "X")
        container.addSubview(xField)

        yField = SpotlightInlineField(prefix: "Y")
        container.addSubview(yField)

        wField = SpotlightInlineField(prefix: "W")
        container.addSubview(wField)

        hField = SpotlightInlineField(prefix: "H")
        container.addSubview(hField)

        layoutContent(showsGlobalBanner: false, fieldW: fieldW, fieldH: fieldH, fieldGap: fieldGap)

        xField.valueField.formatter = numberFormatter
        yField.valueField.formatter = numberFormatter
        wField.valueField.formatter = numberFormatter
        hField.valueField.formatter = numberFormatter

        dimNotchRow.onSelectionChanged = { [weak self] index in
            self?.dimNotchChanged(index)
        }
        blurNotchRow.onSelectionChanged = { [weak self] index in
            self?.blurNotchChanged(index)
        }

        let regionChanged = { [weak self] in
            guard let self, !self.isUpdatingFromModel else { return }
            self.applyRegionFromFields()
        }
        xField.onValueChanged = regionChanged
        yField.onValueChanged = regionChanged
        wField.onValueChanged = regionChanged
        hField.onValueChanged = regionChanged

        panel.contentView = container
    }

    private func layoutContent(
        showsGlobalBanner: Bool,
        fieldW: CGFloat,
        fieldH: CGFloat,
        fieldGap: CGFloat
    ) {
        let panelW = SpotlightPanelStyle.panelWidth
        let pad = SpotlightPanelStyle.padding
        let notchH: CGFloat = 20
        let metricRowH: CGFloat = 16
        let globalLabelH: CGFloat = 14
        let panelH = compactPanelHeight + (showsGlobalBanner ? globalBannerHeight : 0)

        container.frame = NSRect(x: 0, y: 0, width: panelW, height: panelH)
        panel.setContentSize(NSSize(width: panelW, height: panelH))

        var y = panelH - pad

        if showsGlobalBanner {
            y -= globalLabelH
            globalEffectsLabel.frame = CGRect(x: pad, y: y, width: panelW - pad * 2, height: globalLabelH)
            y -= SpotlightPanelStyle.rowGap
        }

        func placeEffectRow(
            nameLabel: NSTextField,
            valueLabel: NSTextField,
            notch: SpotlightNotchRow
        ) {
            y -= metricRowH
            nameLabel.frame = CGRect(x: pad, y: y, width: 100, height: metricRowH)
            valueLabel.frame = CGRect(x: panelW - pad - 52, y: y, width: 52, height: metricRowH)
            y -= SpotlightPanelStyle.rowGap + notchH
            notch.frame = CGRect(x: pad, y: y, width: panelW - pad * 2, height: notchH)
            y -= SpotlightPanelStyle.sectionGap
        }

        placeEffectRow(nameLabel: dimNameLabel, valueLabel: dimValueLabel, notch: dimNotchRow)
        placeEffectRow(nameLabel: blurNameLabel, valueLabel: blurValueLabel, notch: blurNotchRow)

        y -= fieldH
        xField.frame = CGRect(x: pad, y: y, width: fieldW, height: fieldH)
        yField.frame = CGRect(x: pad + fieldW + fieldGap, y: y, width: fieldW, height: fieldH)
        y -= fieldGap + fieldH

        wField.frame = CGRect(x: pad, y: y, width: fieldW, height: fieldH)
        hField.frame = CGRect(x: pad + fieldW + fieldGap, y: y, width: fieldW, height: fieldH)
    }

    deinit {
        blurDebounceTimer?.invalidate()
    }

    func show(
        aboveToolbarScreenRect toolbarRect: NSRect,
        anchorButtonScreenRect buttonRect: NSRect,
        dimOpacity: CGFloat,
        blurRadius: CGFloat,
        region: CGRect,
        affectsAllSpotlights: Bool,
        imagePixelSize: CGSize = .zero
    ) {
        hide()
        anchorScreenRect = buttonRect
        toolbarAnchorScreenRect = toolbarRect
        setAffectsAllSpotlights(affectsAllSpotlights)
        populate(
            dimOpacity: dimOpacity,
            blurRadius: blurRadius,
            region: region,
            imagePixelSize: imagePixelSize
        )

        let panelW = panel.frame.width
        let panelX = (toolbarRect.midX - panelW / 2).rounded()
        let panelY = toolbarRect.maxY + Self.toolbarGap
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.makeKeyAndOrderFront(nil)
        onVisibilityChanged?()

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            self?.hide()
        }

        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let contentView = self.panel.contentView {
                let point = contentView.convert(event.locationInWindow, from: nil)
                if contentView.bounds.contains(point) { return event }
            }
            if self.anchorScreenRect.contains(NSEvent.mouseLocation) { return event }
            self.hide()
            return event
        }
    }

    func hide() {
        let wasVisible = panel.isVisible
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        blurDebounceTimer?.invalidate()
        blurDebounceTimer = nil
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        if wasVisible {
            onEditingEnded()
        }
        panel.orderOut(nil)
        if wasVisible { onVisibilityChanged?() }
    }

    var isVisible: Bool { panel.isVisible }

    func populate(
        dimOpacity: CGFloat,
        blurRadius: CGFloat,
        region: CGRect,
        imagePixelSize: CGSize = .zero
    ) {
        isUpdatingFromModel = true
        defer { isUpdatingFromModel = false }

        if imagePixelSize.width > 0, imagePixelSize.height > 0 {
            self.imagePixelSize = imagePixelSize
        }

        let snappedDim = AppSettings.snapSpotlightDimOpacity(dimOpacity)
        let snappedBlur = AppSettings.snapSpotlightBlurRadius(blurRadius)
        dimNotchRow.setSelectedIndex(AppSettings.spotlightDimOpacityIndex(for: snappedDim), animated: false)
        blurNotchRow.setSelectedIndex(AppSettings.spotlightBlurRadiusIndex(for: snappedBlur), animated: false)
        dimNotchRow.needsDisplay = true
        blurNotchRow.needsDisplay = true
        updateDimLabel(snappedDim)
        updateBlurLabel(snappedBlur)

        setInlineField(xField, value: region.origin.x)
        setInlineField(yField, value: region.origin.y)
        setInlineField(wField, value: region.width)
        setInlineField(hField, value: region.height)
    }

    func updateRegion(_ region: CGRect, imagePixelSize: CGSize = .zero) {
        guard !isUpdatingFromModel, !isAnyFieldEditing else { return }
        if imagePixelSize.width > 0, imagePixelSize.height > 0 {
            self.imagePixelSize = imagePixelSize
        }
        isUpdatingFromModel = true
        setInlineField(xField, value: region.origin.x)
        setInlineField(yField, value: region.origin.y)
        setInlineField(wField, value: region.width)
        setInlineField(hField, value: region.height)
        isUpdatingFromModel = false
    }

    private var isAnyFieldEditing: Bool {
        xField.isEditingValue || yField.isEditingValue || wField.isEditingValue || hField.isEditingValue
    }

    func setAffectsAllSpotlights(_ affectsAll: Bool) {
        globalEffectsLabel.isHidden = !affectsAll
        globalEffectsLabel.stringValue = affectsAll
            ? "Effects apply to all spotlights"
            : ""

        guard affectsAll != showsGlobalBanner else { return }
        showsGlobalBanner = affectsAll

        let panelW = SpotlightPanelStyle.panelWidth
        let pad = SpotlightPanelStyle.padding
        let fieldGap: CGFloat = 8
        let fieldW = (panelW - pad * 2 - fieldGap) / 2
        let fieldH = SpotlightPanelStyle.fieldHeight
        layoutContent(showsGlobalBanner: affectsAll, fieldW: fieldW, fieldH: fieldH, fieldGap: fieldGap)

        guard panel.isVisible else { return }
        let panelX = (toolbarAnchorScreenRect.midX - panelW / 2).rounded()
        let panelY = toolbarAnchorScreenRect.maxY + Self.toolbarGap
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
    }

    private func updateDimLabel(_ value: CGFloat) {
        dimValueLabel.stringValue = "\(Int((value * 100).rounded()))%"
    }

    private func updateBlurLabel(_ value: CGFloat) {
        blurValueLabel.stringValue = "\(Int(value.rounded()))"
    }

    private func dimNotchChanged(_ index: Int) {
        let clamped = min(max(index, 0), AppSettings.spotlightDimOpacityNotches.count - 1)
        let value = AppSettings.spotlightDimOpacityNotches[clamped]
        dimNotchRow.setSelectedIndex(clamped, animated: false)
        updateDimLabel(value)
        onDimOpacityChanged(value)
    }

    private func blurNotchChanged(_ index: Int) {
        let clamped = min(max(index, 0), AppSettings.spotlightBlurRadiusNotches.count - 1)
        let value = AppSettings.spotlightBlurRadiusNotches[clamped]
        blurNotchRow.setSelectedIndex(clamped, animated: false)
        updateBlurLabel(value)
        blurDebounceTimer?.invalidate()
        blurDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            self?.onBlurRadiusChanged(value)
        }
    }

    private func setInlineField(_ field: SpotlightInlineField, value: CGFloat) {
        field.valueField.stringValue = numberFormatter.string(from: NSNumber(value: value.rounded())) ?? "0"
    }

    private func applyRegionFromFields() {
        guard let x = numberFormatter.number(from: xField.valueField.stringValue)?.doubleValue,
              let y = numberFormatter.number(from: yField.valueField.stringValue)?.doubleValue,
              let w = numberFormatter.number(from: wField.valueField.stringValue)?.doubleValue,
              let h = numberFormatter.number(from: hField.valueField.stringValue)?.doubleValue,
              w > 0, h > 0 else { return }
        var region = CGRect(x: x, y: y, width: w, height: h)
        if imagePixelSize.width > 0, imagePixelSize.height > 0 {
            region = SpotlightRegionCoordinates.clampedDisplayRegion(region, imagePixelSize: imagePixelSize)
            isUpdatingFromModel = true
            setInlineField(xField, value: region.origin.x)
            setInlineField(yField, value: region.origin.y)
            setInlineField(wField, value: region.width)
            setInlineField(hField, value: region.height)
            isUpdatingFromModel = false
        }
        onRegionChanged(region)
    }
}

// MARK: - ToolHoverButton

final class ToolHoverButton: NSButton {

    var tool: AnnotationTool?
    var onTooltipRequested: ((NSRect) -> Void)?
    var onTooltipDismissed: (() -> Void)?
    /// When true, tooltips show immediately instead of after the initial delay.
    var areTooltipsPrimed: (() -> Bool)?
    /// Hover wash — light-on-dark vs dark-on-light depending on toolbar chrome.
    var hoverOverlayColor: NSColor = NSColor.black.withAlphaComponent(0.06) {
        didSet {
            hoverOverlay?.backgroundColor = hoverOverlayColor.cgColor
        }
    }

    private static let initialTooltipDelay: TimeInterval = 1.0

    private var hoverOverlay: CALayer?
    private var tooltipTimer: Timer?
    private var isInsideBounds = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isInsideBounds else { return }
        isInsideBounds = true
        showHoverOverlay()
        scheduleTooltip()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isInsideBounds = false
        removeHoverOverlay()
        cancelTooltip()
        onTooltipDismissed?()
    }

    private func showHoverOverlay() {
        guard hoverOverlay == nil, let layer else { return }
        let hl = CALayer()
        hl.frame = layer.bounds
        hl.cornerRadius = layer.cornerRadius
        hl.backgroundColor = hoverOverlayColor.cgColor
        layer.addSublayer(hl)
        hoverOverlay = hl
    }

    private func removeHoverOverlay() {
        hoverOverlay?.removeFromSuperlayer()
        hoverOverlay = nil
    }

    private func scheduleTooltip() {
        tooltipTimer?.invalidate()
        let delay = areTooltipsPrimed?() == true ? 0 : Self.initialTooltipDelay
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isInsideBounds, let win = self.window else { return }
                let winRect = self.convert(self.bounds, to: nil)
                let screenRect = win.convertToScreen(winRect)
                self.onTooltipRequested?(screenRect)
            }
        }
    }

    private func cancelTooltip() {
        tooltipTimer?.invalidate()
        tooltipTimer = nil
    }
}

// MARK: - ToolbarPillView

final class ToolbarPillView: NSView {

    var selectedTool: AnnotationTool = .draw {
        didSet {
            refresh()
            if selectedTool == .select {
                setProximityFaded(false, passThroughMouse: false)
            } else if let win = window {
                updateProximityFade(at: win.mouseLocationOutsideOfEventStream)
            }
        }
    }
    var selectedColor: NSColor = NSColor.annotationPalette[0] { didSet { refresh() } }
    var selectedStrokeTool: StrokeTool = .marker { didSet { refresh() } }
    var selectedArrowTipStyle: ArrowTipStyle = .solid { didSet { refresh() } }
    var selectedArrowPathStyle: ArrowPathStyle = .autoBend { didSet { refresh() } }
    var selectedSpotlightDimOpacity: CGFloat = AppSettings.spotlightDimOpacityDefault { didSet { refresh() } }
    var selectedSpotlightBlurRadius: CGFloat = AppSettings.spotlightBlurRadiusDefault { didSet { refresh() } }
    /// When true, the color swatch is replaced by spotlight accessory controls.
    var showsSpotlightAccessoryControls: Bool = false {
        didSet {
            guard oldValue != showsSpotlightAccessoryControls else { return }
            scheduleAccessoryLayout(animated: accessoryLayoutAnimated)
        }
    }
    /// When false, the color swatch and its leading divider are hidden.
    /// Starts false so first layout matches select/zoom (no color) — avoids a left→center
    /// slide when the library recreates the pill on capture switch.
    var showsColorAccessoryControls: Bool = false {
        didSet {
            guard oldValue != showsColorAccessoryControls else { return }
            scheduleAccessoryLayout(animated: accessoryLayoutAnimated)
        }
    }
    /// Gates resize/recenter animation for accessory show/hide (tool changes: on; bind/wire: off).
    private var accessoryLayoutAnimated = true
    var customColor: NSColor?

    var onToolSelected: ((AnnotationTool) -> Void)?
    var onColorSelected: ((NSColor) -> Void)?
    var onStrokeToolSelected: ((StrokeTool) -> Void)?
    var onArrowTipStyleSelected: ((ArrowTipStyle) -> Void)?
    var onArrowPathStyleSelected: ((ArrowPathStyle) -> Void)?
    var onSpotlightDimOpacityChanged: ((CGFloat) -> Void)?
    var onSpotlightBlurRadiusChanged: ((CGFloat) -> Void)?
    var onSpotlightRegionChanged: ((CGRect) -> Void)?
    var onSpotlightOptionsEditingEnded: (() -> Void)?
    /// Converts canvas-space spotlight rects to image-pixel coords for the options panel.
    var mapSpotlightRegionToPanel: ((CGRect) -> CGRect)?
    /// Converts image-pixel coords from the options panel back to canvas space.
    var mapSpotlightRegionFromPanel: ((CGRect) -> CGRect)?
    var spotlightImagePixelSize: CGSize = .zero

    private let availableTools: [AnnotationTool]

    private var toolButtons: [AnnotationTool: ToolHoverButton] = [:]
    private var colorSwatchButton: CircleColorButton!
    private var spotlightOptionsButton: NSButton!
    private var accessorySeparator: NSView!
    private let tooltipPanel = ToolTooltipPanel()
    private var tooltipsPrimed = false
    private var drawStyleMenu: DrawStyleMenuPanel!
    private var arrowStyleMenu: ArrowStyleMenuPanel!
    private(set) var spotlightOptionsMenu: SpotlightOptionsPanel!
    private var colorGridMenu: ColorGridMenuPanel!
    private var customColorPicker: FigmaStyleColorPickerPanel!
    private var backgroundView: NSView!
    private let toolButtonSize: CGFloat = 32
    /// Vertical inset around tool buttons (matches horizontal `toolSectionPadding`).
    private var pillHeight: CGFloat { toolButtonSize + toolSectionPadding * 2 }
    private let toolButtonCornerRadius = DesignTokens.Radius.md
    private var toolIconPointSize: CGFloat { toolButtonSize * (14 / 28) }
    private var accessoryIconPointSize: CGFloat { toolButtonSize * (13 / 28) }
    /// Concentric with tool buttons: container radius − inset = button radius.
    private var pillCornerRadius: CGFloat {
        toolButtonCornerRadius + (pillHeight - toolButtonSize) / 2
    }
    private let toolSectionPadding: CGFloat = 6
    private var toolsSectionEndX: CGFloat = 0
    /// Cached so we only re-apply layer colors when light/dark chrome flips.
    private var usesDarkChrome = false

    private var dragStartMouseLocation: NSPoint?
    private var dragStartFrameOrigin: NSPoint?

    /// When set, dragging is clamped to this rect in the superview's coordinate space.
    var dragBounds: CGRect?
    /// Tracks whether the user has manually repositioned the toolbar.
    var hasBeenManuallyRepositioned = false

    private let proximityMargin: CGFloat = 16
    private let fadedAlpha: CGFloat = 0.3
    private var mouseMonitor: Any?
    private var isProximityFaded = false
    private var isRepositionDragging = false
    private var passThroughMouse = false
    private var pressStartedInToolbar = false
    private var isCanvasActivelyUsingTool = false
    private var dragCursorTrackingArea: NSTrackingArea?
    private(set) var isAnimatingAccessoryLayout = false
    /// Coalesces back-to-back spotlight/color accessory updates into one layout pass.
    private var pendingAccessoryLayoutAnimated: Bool?

    init(
        frame: NSRect,
        availableTools: [AnnotationTool] = AnnotationTool.videoTools
    ) {
        self.availableTools = availableTools
        super.init(frame: frame)
        build()
    }

    override init(frame: NSRect) {
        self.availableTools = AnnotationTool.videoTools
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    deinit {
        removeMouseMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.acceptsMouseMovedEvents = true
            installMouseMonitor()
            refreshChrome(force: true)
        } else {
            removeMouseMonitor()
            pressStartedInToolbar = false
            setProximityFaded(false, passThroughMouse: false)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChrome(force: true)
    }

    static func defaultOrigin(pillSize: NSSize, in containerSize: NSSize, bottomInset: CGFloat = 16) -> NSPoint {
        NSPoint(
            x: ((containerSize.width - pillSize.width) / 2).rounded(),
            y: bottomInset
        )
    }

    private func build() {
        wantsLayer = true

        let h = pillHeight
        let bg = NSView(frame: bounds)
        bg.autoresizingMask = [.width, .height]
        bg.wantsLayer = true
        applyPillCornerRadius(to: bg.layer)
        applyPillShadow(to: bg.layer)
        addSubview(bg)
        backgroundView = bg

        drawStyleMenu = DrawStyleMenuPanel { [weak self] style in
            guard let self else { return }
            self.selectedStrokeTool = style
            self.onStrokeToolSelected?(style)
        }

        arrowStyleMenu = ArrowStyleMenuPanel(
            onTipSelect: { [weak self] style in
                guard let self else { return }
                self.selectedArrowTipStyle = style
                self.onArrowTipStyleSelected?(style)
            },
            onPathSelect: { [weak self] style in
                guard let self else { return }
                self.selectedArrowPathStyle = style
                self.onArrowPathStyleSelected?(style)
            }
        )

        spotlightOptionsMenu = SpotlightOptionsPanel(
            onDimOpacityChanged: { [weak self] opacity in
                self?.onSpotlightDimOpacityChanged?(opacity)
            },
            onBlurRadiusChanged: { [weak self] radius in
                self?.onSpotlightBlurRadiusChanged?(radius)
            },
            onRegionChanged: { [weak self] region in
                guard let self else { return }
                let canvasRegion = self.mapSpotlightRegionFromPanel?(region) ?? region
                self.onSpotlightRegionChanged?(canvasRegion)
            },
            onEditingEnded: { [weak self] in
                self?.onSpotlightOptionsEditingEnded?()
            }
        )

        colorGridMenu = ColorGridMenuPanel(
            onSelectPalette: { [weak self] index in
                guard let self else { return }
                let color = NSColor.annotationPalette[index]
                self.customColor = nil
                self.selectedColor = color
                self.onColorSelected?(color)
            },
            onSelectCustom: { [weak self] in
                self?.showCustomColorPicker()
            }
        )

        customColorPicker = FigmaStyleColorPickerPanel { [weak self] color in
            guard let self else { return }
            self.customColor = color
            self.selectedColor = color
            self.onColorSelected?(color)
        }

        let refreshPanelChrome: () -> Void = { [weak self] in
            self?.refresh()
        }
        drawStyleMenu.onVisibilityChanged = refreshPanelChrome
        arrowStyleMenu.onVisibilityChanged = refreshPanelChrome
        colorGridMenu.onVisibilityChanged = refreshPanelChrome
        customColorPicker.onVisibilityChanged = refreshPanelChrome
        spotlightOptionsMenu.onVisibilityChanged = refreshPanelChrome

        let btnSz = toolButtonSize
        let btnY = (h - btnSz) / 2
        var x: CGFloat = toolSectionPadding

        for (i, tool) in availableTools.enumerated() {
            let btn = ToolHoverButton(frame: CGRect(x: x, y: btnY, width: btnSz, height: btnSz))
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.title = ""
            let cfg = NSImage.SymbolConfiguration(pointSize: toolIconPointSize, weight: .medium)
            btn.image = NSImage(systemSymbolName: tool.sfSymbol, accessibilityDescription: tool.sfSymbol)?
                            .withSymbolConfiguration(cfg)
            btn.imageScaling = .scaleProportionallyDown
            btn.wantsLayer = true
            btn.layer?.cornerRadius = toolButtonCornerRadius
            btn.tag = i
            btn.target = self
            btn.action = #selector(toolTapped(_:))
            btn.tool = tool
            btn.areTooltipsPrimed = { [weak self] in self?.tooltipsPrimed ?? false }
            btn.onTooltipRequested = { [weak self] screenRect in
                self?.showTooltip(for: tool, at: screenRect)
            }
            btn.onTooltipDismissed = { [weak self] in
                self?.tooltipPanel.hide()
            }
            addSubview(btn)
            toolButtons[tool] = btn
            x += btnSz + 2
        }

        x += toolSectionPadding
        toolsSectionEndX = x
        accessorySeparator = makeSeparator(at: x, height: h)
        addSubview(accessorySeparator)

        let swSz = btnSz
        let swInset: CGFloat = 6
        let swatch = CircleColorButton(color: selectedColor, visualInset: swInset)
        swatch.frame = CGRect(x: 0, y: btnY, width: swSz, height: swSz)
        swatch.target = self
        swatch.action = #selector(colorSwatchTapped)
        swatch.toolTip = "Color"
        addSubview(swatch)
        colorSwatchButton = swatch

        let optionsBtn = NSButton(frame: CGRect(x: 0, y: btnY, width: btnSz, height: btnSz))
        optionsBtn.bezelStyle = .regularSquare
        optionsBtn.isBordered = false
        let optionsCfg = NSImage.SymbolConfiguration(pointSize: accessoryIconPointSize, weight: .medium)
        optionsBtn.image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "Spotlight options"
        )?.withSymbolConfiguration(optionsCfg)
        optionsBtn.imageScaling = .scaleProportionallyDown
        optionsBtn.wantsLayer = true
        optionsBtn.layer?.cornerRadius = toolButtonCornerRadius
        optionsBtn.target = self
        optionsBtn.action = #selector(spotlightOptionsTapped)
        optionsBtn.toolTip = "Spotlight options"
        optionsBtn.isHidden = true
        addSubview(optionsBtn)
        spotlightOptionsButton = optionsBtn

        layoutAccessoryControls()
        refreshChrome(force: true)
        updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        backgroundView?.frame = bounds
        applyPillCornerRadius(to: backgroundView?.layer)
        applyPillShadow(to: backgroundView?.layer)
        // Letterbox hosts can change fill without an appearance notification.
        // Defer so we don't mutate `appearance` mid-layout.
        DispatchQueue.main.async { [weak self] in
            self?.refreshChrome(force: false)
        }
    }

    private func applyPillCornerRadius(to layer: CALayer?) {
        layer?.cornerRadius = pillCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
    }

    private func applyPillShadow(to layer: CALayer?) {
        guard let layer else { return }
        DesignTokens.Elevation.panel.apply(
            to: layer,
            roundedPathIn: layer.bounds,
            cornerRadius: pillCornerRadius
        )
    }

    /// Applies spotlight/color accessory visibility in one pass.
    /// - Parameter animated: `true` for in-session tool/selection changes; `false` when
    ///   binding a new capture so the pill does not slide/recenter from the left.
    func setAccessoryControls(
        showsSpotlight: Bool,
        showsColor: Bool,
        animated: Bool
    ) {
        let previous = accessoryLayoutAnimated
        accessoryLayoutAnimated = animated
        showsSpotlightAccessoryControls = showsSpotlight
        showsColorAccessoryControls = showsColor
        accessoryLayoutAnimated = previous
    }

    /// Defers layout so paired spotlight/color flag updates animate as one resize.
    private func scheduleAccessoryLayout(animated: Bool) {
        let wasPending = pendingAccessoryLayoutAnimated != nil
        pendingAccessoryLayoutAnimated = (pendingAccessoryLayoutAnimated ?? false) || animated
        guard !wasPending else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shouldAnimate = self.pendingAccessoryLayoutAnimated ?? false
            self.pendingAccessoryLayoutAnimated = nil
            self.layoutAccessoryControls(animated: shouldAnimate)
            self.refresh()
        }
    }

    private func centeredAccessoryOrigin(forWidth width: CGFloat, preservingY y: CGFloat) -> NSPoint {
        if let dragBounds {
            return NSPoint(
                x: dragBounds.minX + ((dragBounds.width - width) / 2).rounded(),
                y: y
            )
        }
        if let superview {
            return NSPoint(
                x: ((superview.bounds.width - width) / 2).rounded(),
                y: y
            )
        }
        return NSPoint(x: frame.origin.x, y: y)
    }

    private func targetAccessoryOrigin(forWidth newWidth: CGFloat) -> NSPoint {
        var origin = frame.origin
        if !hasBeenManuallyRepositioned {
            origin = centeredAccessoryOrigin(forWidth: newWidth, preservingY: origin.y)
        }
        if let dragBounds {
            if origin.x + newWidth > dragBounds.maxX {
                origin.x = dragBounds.maxX - newWidth
            }
            if origin.x < dragBounds.minX {
                origin.x = dragBounds.minX
            }
        }
        return origin
    }

    private func layoutAccessoryControls(animated: Bool = false) {
        // Don't clobber an in-flight resize; apply the latest target when it finishes.
        if isAnimatingAccessoryLayout {
            pendingAccessoryLayoutAnimated = (pendingAccessoryLayoutAnimated ?? false) || animated
            return
        }

        let h = pillHeight
        let btnSz = toolButtonSize
        let btnY = (h - btnSz) / 2
        var x = toolsSectionEndX

        let showSpotlightAccessory = showsSpotlightAccessoryControls
        let showColorAccessory = showsColorAccessoryControls
        let showsAnyAccessory = showSpotlightAccessory || showColorAccessory

        if showsAnyAccessory {
            accessorySeparator.frame.origin.x = x
            accessorySeparator.isHidden = false
            x += 9
        } else {
            accessorySeparator.isHidden = true
        }

        if showSpotlightAccessory {
            spotlightOptionsButton.frame.origin = CGPoint(x: x, y: btnY)
            x += btnSz + 2
        } else if showColorAccessory {
            colorSwatchButton.frame.origin = CGPoint(x: x, y: btnY)
            x += btnSz + 2
        }

        let trailingPadding = toolSectionPadding
        let newWidth: CGFloat
        if !showsAnyAccessory {
            // toolsSectionEndX includes accessory gutter; trim to match the left inset.
            newWidth = toolsSectionEndX - 2
        } else {
            newWidth = x + trailingPadding
        }
        let oldWidth = bounds.width
        let oldOrigin = frame.origin
        let targetOrigin = targetAccessoryOrigin(forWidth: newWidth)
        let sizeChanged = oldWidth > 0 && abs(oldWidth - newWidth) > 0.5
        let originChanged = abs(oldOrigin.x - targetOrigin.x) > 0.5
            || abs(oldOrigin.y - targetOrigin.y) > 0.5
        let shouldAnimate = animated && (sizeChanged || originChanged)

        if shouldAnimate {
            let expanding = newWidth >= oldWidth
            applyAccessoryVisibility(
                showSpotlight: showSpotlightAccessory,
                showColor: showColorAccessory,
                deferSpotlightHide: !expanding && sizeChanged
            )

            isAnimatingAccessoryLayout = true
            layer?.cornerRadius = pillCornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true

            let targetFrame = NSRect(origin: targetOrigin, size: NSSize(width: newWidth, height: h))

            var accessoryViews: [NSView] = [accessorySeparator]
            if showSpotlightAccessory { accessoryViews.append(spotlightOptionsButton) }
            if showColorAccessory { accessoryViews.append(colorSwatchButton) }
            if expanding && sizeChanged {
                accessoryViews.forEach { $0.alphaValue = 0 }
            }

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = expanding ? 0.28 : 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                ctx.allowsImplicitAnimation = true
                self.animator().frame = targetFrame
                if expanding && sizeChanged {
                    accessoryViews.forEach { $0.animator().alphaValue = 1 }
                }
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.isAnimatingAccessoryLayout = false
                self.layer?.masksToBounds = false
                accessoryViews.forEach { $0.alphaValue = 1 }
                self.applyAccessoryVisibility(
                    showSpotlight: self.showsSpotlightAccessoryControls,
                    showColor: self.showsColorAccessoryControls,
                    deferSpotlightHide: false
                )
                self.layout()
                let followUpAnimated = self.pendingAccessoryLayoutAnimated
                self.pendingAccessoryLayoutAnimated = nil
                self.layoutAccessoryControls(animated: followUpAnimated ?? false)
            })
        } else {
            applyAccessoryVisibility(
                showSpotlight: showSpotlightAccessory,
                showColor: showColorAccessory,
                deferSpotlightHide: false
            )
            frame = NSRect(origin: targetOrigin, size: NSSize(width: newWidth, height: h))
        }
    }

    private func applyAccessoryVisibility(
        showSpotlight: Bool,
        showColor: Bool,
        deferSpotlightHide: Bool = false
    ) {
        if showSpotlight {
            colorSwatchButton.isHidden = true
            if deferSpotlightHide {
                spotlightOptionsButton.isHidden = true
            } else {
                spotlightOptionsButton.isHidden = false
            }
        } else {
            spotlightOptionsButton.isHidden = true
            colorSwatchButton.isHidden = !showColor
        }
    }

    private func clampAccessoryFrameToDragBounds() {
        guard let dragBounds else { return }
        if frame.maxX > dragBounds.maxX {
            frame.origin.x = dragBounds.maxX - bounds.width
        }
        if frame.minX < dragBounds.minX {
            frame.origin.x = dragBounds.minX
        }
    }

    func clampToDragBoundsIfNeeded() {
        clampAccessoryFrameToDragBounds()
    }

    private func makeSeparator(at x: CGFloat, height: CGFloat) -> NSView {
        let v = NSView(frame: CGRect(x: x, y: 8, width: 1, height: height - 16))
        v.wantsLayer = true
        return v
    }

    // MARK: Actions

    @objc private func toolTapped(_ sender: NSButton) {
        tooltipPanel.hide()
        colorGridMenu.hide()
        customColorPicker.hide()
        spotlightOptionsMenu.hide()
        let tools = availableTools
        guard sender.tag < tools.count else { return }
        let tool = tools[sender.tag]

        if tool == .draw, tool == selectedTool, let btn = toolButtons[.draw], let win = window {
            arrowStyleMenu.hide()
            if drawStyleMenu.isVisible {
                drawStyleMenu.hide()
            } else {
                let btnRect = btn.convert(btn.bounds, to: nil)
                let screenRect = win.convertToScreen(btnRect)
                drawStyleMenu.show(
                    aboveScreenRect: screenRect,
                    selectedStyle: selectedStrokeTool,
                    accentColor: DesignTokens.Color.primary.ns
                )
            }
            return
        }

        if tool == .arrow, tool == selectedTool, let btn = toolButtons[.arrow], let win = window {
            drawStyleMenu.hide()
            if arrowStyleMenu.isVisible {
                arrowStyleMenu.hide()
            } else {
                let btnRect = btn.convert(btn.bounds, to: nil)
                let screenRect = win.convertToScreen(btnRect)
                arrowStyleMenu.show(
                    aboveScreenRect: screenRect,
                    selectedTipStyle: selectedArrowTipStyle,
                    selectedPathStyle: selectedArrowPathStyle,
                    accentColor: DesignTokens.Color.primary.ns
                )
            }
            return
        }

        drawStyleMenu.hide()
        arrowStyleMenu.hide()
        onToolSelected?(tool)
    }

    private func showTooltip(for tool: AnnotationTool, at screenRect: NSRect) {
        tooltipsPrimed = true
        tooltipPanel.show(for: tool, aboveScreenRect: screenRect)
    }

    @objc private func colorSwatchTapped() {
        drawStyleMenu.hide()
        arrowStyleMenu.hide()
        customColorPicker.hide()

        guard let win = window else { return }
        let btnRect = colorSwatchButton.convert(colorSwatchButton.bounds, to: nil)
        let screenRect = win.convertToScreen(btnRect)

        if colorGridMenu.isVisible {
            colorGridMenu.hide()
        } else {
            colorGridMenu.show(
                aboveScreenRect: screenRect,
                selectedColor: selectedColor,
                customPreviewColor: customColor
            )
        }
    }

    @objc private func spotlightOptionsTapped() {
        drawStyleMenu.hide()
        arrowStyleMenu.hide()
        colorGridMenu.hide()
        customColorPicker.hide()

        guard let win = window else { return }
        let btnRect = spotlightOptionsButton.convert(spotlightOptionsButton.bounds, to: nil)
        let toolbarRect = convert(bounds, to: nil)
        let btnScreenRect = win.convertToScreen(btnRect)
        let toolbarScreenRect = win.convertToScreen(toolbarRect)

        if spotlightOptionsMenu.isVisible {
            spotlightOptionsMenu.hide()
        } else {
            onSpotlightOptionsWillShow?()
            let panelRegion = mapSpotlightRegionToPanel?(spotlightOptionsRegion) ?? spotlightOptionsRegion
            spotlightOptionsMenu.show(
                aboveToolbarScreenRect: toolbarScreenRect,
                anchorButtonScreenRect: btnScreenRect,
                dimOpacity: selectedSpotlightDimOpacity,
                blurRadius: selectedSpotlightBlurRadius,
                region: panelRegion,
                affectsAllSpotlights: spotlightAffectsAllInstances,
                imagePixelSize: spotlightImagePixelSize
            )
        }
    }

    /// Region shown in the options panel; set by the host before opening.
    var spotlightOptionsRegion: CGRect = .zero
    var spotlightAffectsAllInstances: Bool = false
    var onSpotlightOptionsWillShow: (() -> Void)?

    private func showCustomColorPicker() {
        guard let win = window else { return }
        let btnRect = colorSwatchButton.convert(colorSwatchButton.bounds, to: nil)
        let screenRect = win.convertToScreen(btnRect)
        let initial = customColor ?? selectedColor
        customColorPicker.show(aboveScreenRect: screenRect, initialColor: initial)
    }

    // MARK: Refresh

    /// Hosts call this after changing the stage/letterbox fill behind the pill.
    func refreshChromeForHostIfNeeded() {
        refreshChrome(force: false)
    }

    private func refreshChrome(force: Bool) {
        let dark = shouldUseDarkChrome()
        guard force || dark != usesDarkChrome else { return }
        usesDarkChrome = dark
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let surface = dark
            ? DesignTokens.Palette.neutral[.t900].ns
            : DesignTokens.Palette.neutral[.t100].ns
        let separator = dark
            ? DesignTokens.Palette.neutral[.t100].ns.withAlphaComponent(0.12)
            : DesignTokens.Palette.neutral[.t1000].ns.withAlphaComponent(0.12)
        let hover = dark
            ? DesignTokens.Palette.neutral[.t100].ns.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.06)

        backgroundView?.layer?.backgroundColor = surface.cgColor
        accessorySeparator?.layer?.backgroundColor = separator.cgColor
        for btn in toolButtons.values {
            btn.hoverOverlayColor = hover
        }
        refresh()
    }

    /// Dark chrome when floating over a dark letterbox/stage, else follow effective appearance.
    private func shouldUseDarkChrome() -> Bool {
        if let backdrop = solidBackdropColor() {
            return !backdrop.isLightAnnotationBackground
        }
        return effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func solidBackdropColor() -> NSColor? {
        var view: NSView? = superview
        while let current = view {
            if let cg = current.layer?.backgroundColor,
               let color = NSColor(cgColor: cg),
               color.alphaComponent > 0.9 {
                return color
            }
            view = current.superview
        }
        return nil
    }

    private func refresh() {
        let cfg = NSImage.SymbolConfiguration(pointSize: toolIconPointSize, weight: .medium)
        // Pair icon tint with the resolved pill surface (not system appearance alone).
        let inactiveTint = usesDarkChrome
            ? DesignTokens.Palette.neutral[.t200].ns
            : DesignTokens.Palette.neutral[.t1000].ns
        let activeTint = NSColor.white
        let activeFill = usesDarkChrome
            ? DesignTokens.Palette.neutral[.t100].ns.withAlphaComponent(0.18).cgColor
            : DesignTokens.Color.toastDarkFill.ns.cgColor
        for (tool, btn) in toolButtons {
            let on = tool == selectedTool || isPanelOpen(for: tool)
            btn.layer?.backgroundColor = on ? activeFill : .clear
            btn.contentTintColor = on ? activeTint : inactiveTint
            let symbol = tool == .draw ? selectedStrokeTool.menuSymbol : tool.sfSymbol
            btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
                .withSymbolConfiguration(cfg)
        }
        colorSwatchButton.color = selectedColor
        let colorPanelOpen = colorGridMenu.isVisible || customColorPicker.isVisible
        colorSwatchButton.layer?.cornerRadius = toolButtonCornerRadius
        colorSwatchButton.layer?.backgroundColor = colorPanelOpen ? activeFill : .clear
        colorSwatchButton.needsDisplay = true

        if let spotlightOptionsButton {
            let on = spotlightOptionsMenu.isVisible
            spotlightOptionsButton.layer?.backgroundColor = on ? activeFill : .clear
            spotlightOptionsButton.contentTintColor = on ? activeTint : inactiveTint
        }

        if selectedTool != .draw {
            drawStyleMenu?.hide()
        }
        if selectedTool != .arrow {
            arrowStyleMenu?.hide()
        }
        if showsSpotlightAccessoryControls {
            colorGridMenu?.hide()
            customColorPicker?.hide()
        } else {
            spotlightOptionsMenu?.hide()
        }
        if !showsColorAccessoryControls {
            colorGridMenu?.hide()
            customColorPicker?.hide()
        }
    }

    private func isPanelOpen(for tool: AnnotationTool) -> Bool {
        switch tool {
        case .draw: return drawStyleMenu.isVisible
        case .arrow: return arrowStyleMenu.isVisible
        default: return false
        }
    }

    func syncSpotlightOptionsPanelRegion(_ region: CGRect) {
        guard spotlightOptionsMenu.isVisible else { return }
        spotlightOptionsRegion = region
        let panelRegion = mapSpotlightRegionToPanel?(region) ?? region
        spotlightOptionsMenu.updateRegion(panelRegion, imagePixelSize: spotlightImagePixelSize)
    }

    func syncSpotlightOptionsPanel(
        dimOpacity: CGFloat,
        blurRadius: CGFloat,
        region: CGRect,
        affectsAllSpotlights: Bool? = nil
    ) {
        selectedSpotlightDimOpacity = AppSettings.snapSpotlightDimOpacity(dimOpacity)
        selectedSpotlightBlurRadius = AppSettings.snapSpotlightBlurRadius(blurRadius)
        spotlightOptionsRegion = region
        if let affectsAllSpotlights {
            spotlightAffectsAllInstances = affectsAllSpotlights
        }
        guard spotlightOptionsMenu.isVisible else { return }
        let panelRegion = mapSpotlightRegionToPanel?(region) ?? region
        spotlightOptionsMenu.populate(
            dimOpacity: dimOpacity,
            blurRadius: blurRadius,
            region: panelRegion,
            imagePixelSize: spotlightImagePixelSize
        )
        spotlightOptionsMenu.setAffectsAllSpotlights(spotlightAffectsAllInstances)
    }

    // MARK: Proximity fade

    func setCanvasActivelyUsingTool(_ active: Bool) {
        guard isCanvasActivelyUsingTool != active else { return }
        isCanvasActivelyUsingTool = active
        if !active {
            setProximityFaded(false, passThroughMouse: false)
        } else if let win = window {
            updateProximityFade(at: win.mouseLocationOutsideOfEventStream)
        }
    }

    func handleCanvasToolPointer(at locationInWindow: NSPoint) {
        updateProximityFade(at: locationInWindow)
    }

    private func toolbarRectInWindow() -> CGRect {
        guard window != nil else { return .zero }
        return convert(bounds, to: nil)
    }

    private func proximityRectInWindow() -> CGRect {
        guard window != nil else { return .zero }
        return convert(bounds, to: nil).insetBy(dx: -proximityMargin, dy: -proximityMargin)
    }

    private func installMouseMonitor() {
        removeMouseMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                self.pressStartedInToolbar = self.toolbarRectInWindow().contains(event.locationInWindow)
            case .leftMouseUp:
                self.pressStartedInToolbar = false
            default:
                break
            }
            self.updateProximityFade(at: event.locationInWindow)
            return event
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    private func updateProximityFade(at locationInWindow: NSPoint) {
        guard window != nil else {
            setProximityFaded(false, passThroughMouse: false)
            return
        }
        let inProximity = proximityRectInWindow().contains(locationInWindow)
        let shouldFade = isCanvasActivelyUsingTool && inProximity && !pressStartedInToolbar
        let shouldPassThrough = shouldFade && !isRepositionDragging
        setProximityFaded(shouldFade, passThroughMouse: shouldPassThrough)
    }

    private func setProximityFaded(_ faded: Bool, passThroughMouse: Bool) {
        let targetAlpha = faded ? fadedAlpha : 1
        if faded != isProximityFaded {
            isProximityFaded = faded
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                animator().alphaValue = targetAlpha
            }
        } else if !faded && alphaValue != 1 {
            alphaValue = 1
        }
        self.passThroughMouse = passThroughMouse
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if passThroughMouse { return nil }
        return super.hitTest(point)
    }

    // MARK: Drag repositioning

    private func isDraggable(at point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        guard let hit = super.hitTest(point) else { return false }
        if hit === self || hit === backgroundView { return true }
        if hit is NSControl { return false }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isDraggable(at: point) else {
            super.mouseDown(with: event)
            return
        }
        dragStartMouseLocation = event.locationInWindow
        dragStartFrameOrigin = frame.origin
        isRepositionDragging = true
        hasBeenManuallyRepositioned = true
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        if isRepositionDragging {
            NSCursor.closedHand.set()
        }
        guard let startMouse = dragStartMouseLocation,
              let startOrigin = dragStartFrameOrigin,
              let parent = superview else {
            super.mouseDragged(with: event)
            return
        }
        let parentStart = parent.convert(startMouse, from: nil)
        let parentCurrent = parent.convert(event.locationInWindow, from: nil)
        let dx = parentCurrent.x - parentStart.x
        let dy = parentCurrent.y - parentStart.y
        var newOrigin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
        let clampRect = dragBounds ?? parent.bounds
        newOrigin.x = max(clampRect.minX, min(newOrigin.x, clampRect.maxX - frame.width))
        newOrigin.y = max(clampRect.minY, min(newOrigin.y, clampRect.maxY - frame.height))
        frame.origin = newOrigin
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseLocation = nil
        dragStartFrameOrigin = nil
        isRepositionDragging = false
        updateProximityFade(at: event.locationInWindow)
        updateDragCursor(at: convert(event.locationInWindow, from: nil))
        super.mouseUp(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let dragCursorTrackingArea {
            removeTrackingArea(dragCursorTrackingArea)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .cursorUpdate, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        dragCursorTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateDragCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateDragCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateDragCursor(at point: NSPoint) {
        guard window?.isKeyWindow == true else {
            NSCursor.arrow.set()
            return
        }
        if isRepositionDragging {
            NSCursor.closedHand.set()
        } else if isDraggable(at: point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
    }
}

// MARK: - Annotation action bar

final class AnnotationActionBarView: NSView {
    var showsOpenInGrabbit = true {
        didSet {
            openInGrabbitButton.isHidden = !showsOpenInGrabbit
            layoutButtons()
        }
    }

    var foregroundColor: NSColor = .labelColor {
        didSet { applyForegroundColor() }
    }

    var onOpenInGrabbit: (() -> Void)?
    var onCopy: (() -> Void)?

    private let copyButton = NSButton()
    private let openInGrabbitButton = NSButton()
    private let iconButtonSize: CGFloat = 22

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        configureIconButton(copyButton, symbolName: "doc.on.doc", label: "Copy", action: #selector(copyTapped))
        configureTextButton(openInGrabbitButton, title: "Open in Grabbit", action: #selector(openInGrabbitTapped))

        addSubview(copyButton)
        addSubview(openInGrabbitButton)
        layoutButtons()
    }

    private func configureIconButton(
        _ button: NSButton,
        symbolName: String,
        label: String,
        action: Selector
    ) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
            .withSymbolConfiguration(cfg)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = foregroundColor
        button.target = self
        button.action = action
        button.toolTip = label
    }

    private func configureTextButton(_ button: NSButton, title: String, action: Selector) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.title = title
        button.font = NSFont.grabbit(.body)
        button.contentTintColor = foregroundColor
        button.target = self
        button.action = action
        button.toolTip = title
    }

    private func applyForegroundColor() {
        copyButton.contentTintColor = foregroundColor
        openInGrabbitButton.contentTintColor = foregroundColor
    }

    private func layoutButtons() {
        let gap: CGFloat = 8
        let trailingPadding = DesignTokens.Spacing.md
        let barH: CGFloat = bounds.height > 0 ? bounds.height : 28

        var x: CGFloat = 0
        let copyY = (barH - iconButtonSize) / 2
        copyButton.isHidden = false
        copyButton.frame = NSRect(x: x, y: copyY, width: iconButtonSize, height: iconButtonSize)
        x += iconButtonSize + gap

        if showsOpenInGrabbit {
            openInGrabbitButton.isHidden = false
            openInGrabbitButton.sizeToFit()
            let textH = max(openInGrabbitButton.fittingSize.height, iconButtonSize)
            let textW = ceil(openInGrabbitButton.fittingSize.width)
            let textY = (barH - textH) / 2
            openInGrabbitButton.frame = NSRect(x: x, y: textY, width: textW, height: textH)
            x += textW
        } else {
            openInGrabbitButton.isHidden = true
            if x > 0 { x -= gap }
        }

        frame.size = NSSize(width: x + trailingPadding, height: barH)
    }

    override func layout() {
        super.layout()
        layoutButtons()
    }

    override func resetCursorRects() {
        discardCursorRects()
        for button in [copyButton, openInGrabbitButton] where !button.isHidden {
            addCursorRect(button.frame, cursor: .pointingHand)
        }
    }

    @objc private func copyTapped() { onCopy?() }
    @objc private func openInGrabbitTapped() { onOpenInGrabbit?() }
}

// MARK: - AnnotationWindow

final class AnnotationWindow: NSWindow {

    private static var current: AnnotationWindow?

    private var screenshot: NSImage
    private var viewBackground: RecordingBackgroundStyle = .none
    private var sideBySideSettings = SideBySideSettings()
    private var sideBySideComposition: SideBySideComposition?
    private let canvas: AnnotationCanvasView
    private var backgroundImageView: NSImageView?
    private var screenshotImageView: NSImageView?
    private var leftImageView: NSImageView?
    private var rightImageView: NSImageView?
    private var pill: ToolbarPillView!
    private var shipItPanel: ShipItPanelView!
    private var actionBar: AnnotationActionBarView!
    private var undoRedoKeyMonitor: Any?
    private var fileName: String
    private var titleControl: AnnotationTitlebarTitleControl!
    private var fileSettingsPanel: AnnotationFileSettingsPanel!

    private let toolbarBottomInset: CGFloat = 16
    private let titlebarColor: NSColor
    private var contentContainer: NSView?
    private var stageContentFrame: NSRect = .zero
    private var savedAnnotationContentFrame: NSRect = .zero

    // MARK: Entry Point

    static func show(image: NSImage, fileName: String? = nil, captureID: UUID? = nil, windowInfo: WindowSignature? = nil) {
        DispatchQueue.main.async {
            current = AnnotationWindow(image: image, fileName: fileName, captureID: captureID)
            current?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: Init

    private let captureID: UUID?

    private init(image: NSImage, fileName: String?, captureID: UUID?) {
        self.captureID = captureID
        self.screenshot = image
        self.titlebarColor = image.annotationTitlebarColor()
        let displayName = fileName ?? CaptureNaming.baseName()
        self.fileName = displayName
        let imageSize = AnnotationWindow.fittedSize(for: image)
        self.canvas = AnnotationCanvasView(frame: NSRect(origin: .zero, size: imageSize))

        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let styleMask: NSWindow.StyleMask = [.titled, .closable]
        let frameRect = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: imageSize),
            styleMask: styleMask
        )
        let centeredFrame = NSRect(
            x: screenRect.midX - frameRect.width / 2,
            y: screenRect.midY - frameRect.height / 2,
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
            title: displayName,
            backgroundColor: titlebarColor,
            laysContentBelowTitlebar: true
        )

        let titlebarForeground = titlebarColor.annotationTitlebarForeground
        titleControl = AnnotationTitlebarTitleControl(
            title: displayName,
            foregroundColor: titlebarForeground
        )
        titleControl.target = self
        titleControl.action = #selector(titleControlTapped)
        AnnotationTitlebarStyle.installCenteredTitle(titleControl, in: self)

        fileSettingsPanel = AnnotationFileSettingsPanel(
            onNameCommitted: { [weak self] newName in
                self?.applyFileName(newName)
            },
            onSaveLocationChanged: { [weak self] in
                self?.fileSettingsPanel.refreshSaveLocation()
            }
        )

        actionBar = AnnotationActionBarView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        actionBar.foregroundColor = titlebarForeground
        actionBar.showsOpenInGrabbit = captureID != nil
        AnnotationTitlebarStyle.installTrailingAccessory(actionBar, in: self)

        buildLayout()
        wire()
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
            layoutShipItPanel(in: contentContainer)
        }
    }

    // MARK: Layout

    private static func fittedSize(for image: NSImage) -> NSSize {
        AnnotationViewBackground.fittedStageSize(image.size)
    }

    private func buildLayout() {
        pill = ToolbarPillView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 44),
            availableTools: AnnotationTool.screenshotTools
        )

        shipItPanel = ShipItPanelView(frame: .zero)
        shipItPanel.showsSideBySide = true
        shipItPanel.selectedBackground = viewBackground
        shipItPanel.sideBySideSettings = sideBySideSettings
        shipItPanel.onBackgroundChanged = { [weak self] style in
            self?.applyViewBackground(style)
        }
        shipItPanel.onSideBySideChanged = { [weak self] settings in
            self?.applySideBySideSettings(settings)
        }
        shipItPanel.onPresentationChanged = { [weak self] in
            guard let self, let container = contentContainer else { return }
            layoutShipItPanel(in: container)
        }
        refreshShipItSideBySideChoices()

        applyStageLayout()
    }

    private func applyStageLayout() {
        guard let container = contentContainer ?? setupContentContainer() else { return }

        let oldStageSize = canvas.frame.size
        let oldContentFrame = savedAnnotationContentFrame.width > 0 && savedAnnotationContentFrame.height > 0
            ? savedAnnotationContentFrame
            : NSRect(origin: .zero, size: oldStageSize)

        let stageSize: NSSize
        let newContentFrame: NSRect

        if sideBySideSettings.isEnabled,
           let previous = sideBySideSettings.previousImage {
            let composition = SideBySideLayout.compose(
                current: screenshot,
                previous: previous,
                order: sideBySideSettings.order,
                background: viewBackground
            )
            sideBySideComposition = composition
            stageSize = composition.stageSize
            newContentFrame = NSRect(origin: .zero, size: stageSize)
            layoutSideBySideImages(in: container, composition: composition)
        } else {
            sideBySideComposition = nil
            let layout = AnnotationViewBackground.stageLayout(
                for: screenshot.size,
                background: viewBackground
            )
            stageSize = layout.stage
            newContentFrame = viewBackground == .none
                ? NSRect(origin: .zero, size: stageSize)
                : layout.contentFrame
            stageContentFrame = layout.contentFrame
            layoutSingleImage(in: container, layout: layout)
        }

        if oldStageSize.width > 0, oldStageSize.height > 0,
           !canvas.annotations.isEmpty,
           oldContentFrame != newContentFrame {
            canvas.remapAnnotations(fromContent: oldContentFrame, toContent: newContentFrame)
        }

        setContentSize(stageSize)
        container.setFrameSize(stageSize)
        container.superview?.setFrameSize(stageSize)

        canvas.frame = NSRect(origin: .zero, size: stageSize)
        savedAnnotationContentFrame = newContentFrame
        updateSpotlightCoordinateMapping()
        updateCanvasStageBackground()
        pill.dragBounds = NSRect(origin: .zero, size: stageSize)
        if pill.hasBeenManuallyRepositioned {
            pill.clampToDragBoundsIfNeeded()
        } else if !pill.isAnimatingAccessoryLayout {
            pill.frame.origin = ToolbarPillView.defaultOrigin(
                pillSize: pill.frame.size,
                in: stageSize,
                bottomInset: toolbarBottomInset
            )
        }
        bringToolbarToFront(in: container)
        layoutShipItPanel(in: container)

        if let contentContainer {
            AnnotationTitlebarStyle.layoutContentContainer(
                contentContainer,
                in: self,
                laysContentBelowTitlebar: true
            )
        }
        AnnotationTitlebarStyle.layoutCenteredTitle(in: self)
    }

    private func setupContentContainer() -> NSView? {
        let layout = AnnotationViewBackground.stageLayout(
            for: screenshot.size,
            background: viewBackground
        )
        stageContentFrame = layout.contentFrame

        let shell = NSView(frame: NSRect(origin: .zero, size: layout.stage))
        shell.wantsLayer = true
        shell.layer?.backgroundColor = titlebarColor.cgColor
        shell.autoresizingMask = [.width, .height]

        let container = NSView(frame: NSRect(origin: .zero, size: layout.stage))
        shell.addSubview(container)

        container.addSubview(canvas)
        pill.dragBounds = NSRect(origin: .zero, size: layout.stage)
        if pill.hasBeenManuallyRepositioned {
            pill.clampToDragBoundsIfNeeded()
        } else {
            pill.frame.origin = ToolbarPillView.defaultOrigin(
                pillSize: pill.frame.size,
                in: layout.stage,
                bottomInset: toolbarBottomInset
            )
        }
        container.addSubview(pill, positioned: .above, relativeTo: canvas)
        container.addSubview(shipItPanel, positioned: .above, relativeTo: canvas)
        layoutShipItPanel(in: container)

        contentView = shell
        contentContainer = container
        makeFirstResponder(canvas)
        return container
    }

    private func bringToolbarToFront(in container: NSView) {
        if shipItPanel.isPresented {
            container.addSubview(shipItPanel, positioned: .above, relativeTo: nil)
        }
        container.addSubview(pill, positioned: .above, relativeTo: nil)
    }

    private func layoutShipItPanel(in container: NSView) {
        shipItPanel.layoutOverlay(in: container.bounds)
    }

    private func refreshShipItSideBySideChoices() {
        shipItPanel.sideBySideChoices = CaptureHistory.shared.screenshotChoices(excluding: captureID).map {
            ShipItSideBySideChoice(
                id: $0.entry.id,
                thumbnail: $0.image,
                title: $0.entry.displayName
            )
        }
        if shipItPanel.sideBySideSettings.previousImage == nil,
           let previous = CaptureHistory.shared.previousScreenshot(excluding: captureID) {
            var settings = shipItPanel.sideBySideSettings
            settings.previousCaptureID = previous.entry.id
            settings.previousImage = previous.image
            shipItPanel.sideBySideSettings = settings
            sideBySideSettings = settings
        }
    }

    private func layoutSingleImage(in container: NSView, layout: (stage: NSSize, contentFrame: NSRect)) {
        leftImageView?.removeFromSuperview()
        rightImageView?.removeFromSuperview()
        leftImageView = nil
        rightImageView = nil

        if viewBackground != .none {
            if let bgView = backgroundImageView {
                bgView.frame = NSRect(origin: .zero, size: layout.stage)
                bgView.image = RecordingBackgroundRenderer.backgroundPreviewImage(for: viewBackground)
                container.addSubview(bgView, positioned: .below, relativeTo: canvas)
            } else {
                let bgView = NSImageView(frame: NSRect(origin: .zero, size: layout.stage))
                bgView.imageScaling = .scaleAxesIndependently
                bgView.imageAlignment = .alignCenter
                bgView.wantsLayer = true
                bgView.image = RecordingBackgroundRenderer.backgroundPreviewImage(for: viewBackground)
                container.addSubview(bgView, positioned: .below, relativeTo: canvas)
                backgroundImageView = bgView
            }
        } else {
            backgroundImageView?.removeFromSuperview()
            backgroundImageView = nil
        }

        if let imageView = screenshotImageView {
            imageView.frame = layout.contentFrame
            imageView.image = screenshot
            container.addSubview(imageView, positioned: .below, relativeTo: canvas)
        } else {
            let imageView = NSImageView(frame: layout.contentFrame)
            imageView.image = screenshot
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.wantsLayer = true
            container.addSubview(imageView, positioned: .below, relativeTo: canvas)
            screenshotImageView = imageView
        }
    }

    private func layoutSideBySideImages(in container: NSView, composition: SideBySideComposition) {
        screenshotImageView?.removeFromSuperview()
        screenshotImageView = nil

        if viewBackground != .none {
            if let bgView = backgroundImageView {
                bgView.frame = NSRect(origin: .zero, size: composition.stageSize)
                bgView.image = SideBySideLayout.renderStage(
                    composition,
                    background: viewBackground
                )
                container.addSubview(bgView, positioned: .below, relativeTo: canvas)
            } else {
                let bgView = NSImageView(frame: NSRect(origin: .zero, size: composition.stageSize))
                bgView.imageScaling = .scaleAxesIndependently
                bgView.imageAlignment = .alignCenter
                bgView.wantsLayer = true
                bgView.image = SideBySideLayout.renderStage(
                    composition,
                    background: viewBackground
                )
                container.addSubview(bgView, positioned: .below, relativeTo: canvas)
                backgroundImageView = bgView
            }
            leftImageView?.isHidden = true
            rightImageView?.isHidden = true
            return
        }

        backgroundImageView?.removeFromSuperview()
        backgroundImageView = nil

        if let leftView = leftImageView {
            leftView.frame = composition.leftFrame
            leftView.image = composition.leftImage
            leftView.isHidden = false
            container.addSubview(leftView, positioned: .below, relativeTo: canvas)
        } else {
            let leftView = NSImageView(frame: composition.leftFrame)
            leftView.image = composition.leftImage
            leftView.imageScaling = .scaleProportionallyUpOrDown
            leftView.imageAlignment = .alignCenter
            leftView.wantsLayer = true
            container.addSubview(leftView, positioned: .below, relativeTo: canvas)
            leftImageView = leftView
        }

        if let rightView = rightImageView {
            rightView.frame = composition.rightFrame
            rightView.image = composition.rightImage
            rightView.isHidden = false
            container.addSubview(rightView, positioned: .below, relativeTo: canvas)
        } else {
            let rightView = NSImageView(frame: composition.rightFrame)
            rightView.image = composition.rightImage
            rightView.imageScaling = .scaleProportionallyUpOrDown
            rightView.imageAlignment = .alignCenter
            rightView.wantsLayer = true
            container.addSubview(rightView, positioned: .below, relativeTo: canvas)
            rightImageView = rightView
        }
    }

    private func applyViewBackground(_ style: RecordingBackgroundStyle) {
        guard style != viewBackground else { return }
        viewBackground = style
        shipItPanel.selectedBackground = style
        applyStageLayout()
    }

    private func applySideBySideSettings(_ settings: SideBySideSettings) {
        let wasEnabled = sideBySideSettings.isEnabled
        sideBySideSettings = settings
        shipItPanel.sideBySideSettings = settings

        if settings.isEnabled, settings.previousImage == nil {
            sideBySideSettings.isEnabled = false
            shipItPanel.sideBySideSettings.isEnabled = false
            return
        }

        if wasEnabled != settings.isEnabled || settings.isEnabled {
            canvas.annotations = []
            canvas.currentAnnotation = nil
            canvas.selectedIndex = nil
            canvas.needsDisplay = true
            updateScreenshotCropMask(nil)
        }

        applyStageLayout()
    }

    // MARK: Wire

    private func updateCanvasStageBackground() {
        let stageImage: NSImage
        if let composition = sideBySideComposition {
            stageImage = SideBySideLayout.renderStage(composition, background: viewBackground)
        } else {
            let layout = AnnotationViewBackground.stageLayout(
                for: screenshot.size,
                background: viewBackground
            )
            stageImage = AnnotationViewBackground.renderStage(
                screenshot: screenshot,
                layout: layout,
                background: viewBackground
            )
        }
        canvas.stageBackgroundImage = stageImage
        canvas.needsDisplay = true
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

    private func spotlightImageCoordinateContext() -> (contentFrame: CGRect, imagePixelSize: CGSize) {
        if let composition = sideBySideComposition {
            return (composition.canvasFrame, composition.stageSize)
        }
        let contentFrame = savedAnnotationContentFrame.width > 0 && savedAnnotationContentFrame.height > 0
            ? savedAnnotationContentFrame
            : NSRect(origin: .zero, size: canvas.frame.size)
        return (contentFrame, screenshot.size)
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
        canvas.allowedTools = Set(AnnotationTool.screenshotTools)
        canvas.selectedTool = .select
        pill.selectedTool = .select
        pill.selectedColor = NSColor.annotationPalette[0]
        pill.selectedSpotlightDimOpacity = canvas.selectedSpotlightDimOpacity
        pill.selectedSpotlightBlurRadius = canvas.selectedSpotlightBlurRadius
        updateSpotlightCoordinateMapping()
        updateCanvasStageBackground()

        canvas.onToolChanged = { [weak self] tool in
            guard let self else { return }
            self.pill.selectedTool = tool
            self.updateToolbarAccessoryControls()
        }

        canvas.onEscapeAction = { [weak self] in
            self?.flattenCopyAndClose()
        }

        canvas.onCommittedCropPreviewChanged = { [weak self] cropRect in
            self?.updateScreenshotCropMask(cropRect)
        }

        canvas.onSelectionChanged = { [weak self] _ in
            self?.updateToolbarAccessoryControls()
        }

        canvas.onSelectionGeometryChanged = { [weak self] in
            guard let self,
                  let settings = self.canvas.spotlightSettingsForEditing() else { return }
            self.pill.syncSpotlightOptionsPanelRegion(settings.region)
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

        actionBar.onCopy = { [weak self] in
            self?.performCopyWithToast()
        }

        actionBar.onOpenInGrabbit = { [weak self] in
            self?.performOpenInGrabbit()
        }

        undoRedoKeyMonitor = canvas.installUndoRedoKeyMonitor(for: self)
        updateToolbarAccessoryControls(animated: false)
    }

    private func updateScreenshotCropMask(_ cropRect: CGRect?) {
        let imageView: NSImageView?
        if sideBySideComposition != nil {
            if viewBackground != .none {
                imageView = backgroundImageView
            } else {
                imageView = sideBySideSettings.order == .currentLeft ? leftImageView : rightImageView
            }
        } else {
            imageView = screenshotImageView
        }

        guard let imageView else { return }
        if let cropRect, cropRect.width > 1, cropRect.height > 1 {
            let mask = CAShapeLayer()
            mask.path = CGPath(rect: cropRect, transform: nil)
            imageView.layer?.mask = mask
        } else {
            imageView.layer?.mask = nil
        }
    }

    override func close() {
        // Native macOS markup closes by committing edits — no separate Save.
        _ = autosavePendingEdits()
        fileSettingsPanel.hide()
        if let undoRedoKeyMonitor {
            NSEvent.removeMonitor(undoRedoKeyMonitor)
            self.undoRedoKeyMonitor = nil
        }
        super.close()
    }

    // MARK: Title / file settings

    @objc private func titleControlTapped() {
        if fileSettingsPanel.isVisible {
            fileSettingsPanel.hide()
            return
        }

        let controlRect = titleControl.convert(titleControl.bounds, to: nil)
        let screenRect = convertToScreen(controlRect)
        fileSettingsPanel.show(
            from: self,
            anchorScreenRect: screenRect,
            name: fileName,
            saveLocation: AppSettings.destinationFolderDisplayPath
        )
    }

    private func applyFileName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != fileName else { return }

        if let captureID {
            guard CaptureHistory.shared.renameCapture(id: captureID, to: trimmed) else {
                ToastWindow.show(message: "Couldn’t rename file")
                return
            }
        }

        fileName = trimmed
        AnnotationTitlebarStyle.updateCenteredTitle(trimmed, in: self)
        titleControl.setTitle(trimmed)
        AnnotationTitlebarStyle.layoutCenteredTitle(in: self)
    }

    // MARK: Actions

    @discardableResult
    private func flattenAndCopy() -> Bool {
        let img = flattenedOutputImage()
        guard let tiff = img.tiffRepresentation else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setData(tiff, forType: .tiff)
    }

    @discardableResult
    private func flattenAndSave() -> Bool {
        let img = flattenedOutputImage()
        guard let captureID,
              CaptureHistory.shared.replaceScreenshot(id: captureID, with: img) else {
            return false
        }

        screenshot = img
        viewBackground = .none
        sideBySideSettings = SideBySideSettings()
        shipItPanel.selectedBackground = .none
        shipItPanel.sideBySideSettings = SideBySideSettings()
        shipItPanel.dismiss()
        screenshotImageView?.image = img
        canvas.annotations = []
        canvas.currentAnnotation = nil
        canvas.selectedIndex = nil
        canvas.needsDisplay = true
        updateScreenshotCropMask(nil)
        applyStageLayout()
        return true
    }

    private func flattenedOutputImage() -> NSImage {
        if let composition = sideBySideComposition {
            let bg = SideBySideLayout.renderStage(composition, background: viewBackground)
            return canvas.flattenedImage(background: bg)
        }

        let layout = AnnotationViewBackground.stageLayout(
            for: screenshot.size,
            background: viewBackground
        )
        let stageImage = AnnotationViewBackground.renderStage(
            screenshot: screenshot,
            layout: layout,
            background: viewBackground
        )
        return canvas.flattenedImage(background: stageImage)
    }

    private func performCopyWithToast() {
        guard flattenAndCopy() else { return }
        ToastWindow.show(message: "Copied to clipboard")
    }

    private var hasPendingEdits: Bool {
        !canvas.annotations.isEmpty
            || viewBackground != .none
            || sideBySideComposition != nil
    }

    /// Silently bake annotations into the already-saved capture file when needed.
    @discardableResult
    private func autosavePendingEdits() -> Bool {
        guard captureID != nil, hasPendingEdits else { return true }
        guard flattenAndSave() else {
            ToastWindow.show(message: "Couldn’t save")
            return false
        }
        return true
    }

    private func performOpenInGrabbit() {
        guard let captureID else { return }
        guard autosavePendingEdits() else { return }
        close()
        CaptureLibraryWindow.show(selecting: captureID)
    }

    private func flattenCopyAndClose() {
        flattenAndCopy()
        close()
    }
}

// MARK: - Annotation titlebar file settings

final class AnnotationTitlebarTitleControl: NSButton {
    private let maxTitleWidth: CGFloat = 280
    private let showsFileSettingsChrome: Bool

    var foregroundColor: NSColor = .labelColor {
        didSet { contentTintColor = foregroundColor }
    }

    init(
        title: String,
        foregroundColor: NSColor = .labelColor,
        showsFileSettingsChrome: Bool = true
    ) {
        self.foregroundColor = foregroundColor
        self.showsFileSettingsChrome = showsFileSettingsChrome
        super.init(frame: .zero)
        bezelStyle = .inline
        isBordered = false
        font = NSFont.grabbit(.body)
        lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        contentTintColor = foregroundColor
        setTitle(title)
        if showsFileSettingsChrome {
            toolTip = "Rename and file settings"
        } else {
            toolTip = nil
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard showsFileSettingsChrome else { return false }
        return super.sendAction(action, to: target)
    }

    override func resetCursorRects() {
        discardCursorRects()
        if showsFileSettingsChrome {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    func setTitle(_ title: String, maxWidth: CGFloat? = nil) {
        self.title = title
        sizeToFit()
        let fitted = fittingSize
        let widthCap = max(40, min(maxTitleWidth, maxWidth ?? maxTitleWidth))
        frame.size = NSSize(
            width: min(max(fitted.width, 40), widthCap),
            height: max(fitted.height, 22)
        )
    }
}

final class AnnotationFileSettingsPanel: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let nameField: NSTextField
    private let saveLocationLabel: NSTextField
    private let formatLabel: NSTextField
    private let onNameCommitted: (String) -> Void
    private let onSaveLocationChanged: () -> Void
    private var clickOutsideMonitor: Any?
    private var anchorScreenRect: NSRect = .zero
    private weak var hostWindow: NSWindow?

    init(
        onNameCommitted: @escaping (String) -> Void,
        onSaveLocationChanged: @escaping () -> Void
    ) {
        self.onNameCommitted = onNameCommitted
        self.onSaveLocationChanged = onSaveLocationChanged

        let panelWidth: CGFloat = 280
        let panelHeight: CGFloat = 168
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.hidesOnDeactivate = true

        nameField = NSTextField(string: "")
        saveLocationLabel = NSTextField(labelWithString: "")
        formatLabel = NSTextField(labelWithString: "PNG")

        super.init()

        let side: CGFloat = 14
        let rowH: CGFloat = 22
        let fieldH: CGFloat = 24
        var y = panelHeight - side - 14

        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let vfx = NSVisualEffectView(frame: container.bounds)
        vfx.autoresizingMask = [.width, .height]
        vfx.material = .popover
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = DesignTokens.Radius.lg
        vfx.layer?.masksToBounds = true
        container.addSubview(vfx)

        let nameHeader = sectionLabel("Name", x: side, y: y, width: panelWidth - side * 2)
        container.addSubview(nameHeader)
        y -= rowH + 4

        nameField.frame = NSRect(x: side, y: y - fieldH + 4, width: panelWidth - side * 2, height: fieldH)
        nameField.font = NSFont.grabbit(.body)
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.delegate = self
        container.addSubview(nameField)
        y -= fieldH + 14

        let saveHeader = sectionLabel("Save to", x: side, y: y, width: 60)
        container.addSubview(saveHeader)

        saveLocationLabel.font = NSFont.grabbit(.label)
        saveLocationLabel.textColor = DesignTokens.Color.textSecondary.ns
        saveLocationLabel.lineBreakMode = .byTruncatingMiddle
        saveLocationLabel.frame = NSRect(x: side + 58, y: y, width: panelWidth - side * 2 - 58 - 72, height: 16)
        container.addSubview(saveLocationLabel)

        let changeButton = NSButton(title: "Change…", target: self, action: #selector(changeSaveLocation))
        changeButton.bezelStyle = .rounded
        changeButton.controlSize = .small
        changeButton.font = NSFont.grabbit(.label)
        changeButton.frame = NSRect(x: panelWidth - side - 68, y: y - 2, width: 68, height: 22)
        container.addSubview(changeButton)
        y -= rowH + 12

        let formatHeader = sectionLabel("Format", x: side, y: y, width: 60)
        container.addSubview(formatHeader)

        formatLabel.font = NSFont.grabbit(.label)
        formatLabel.textColor = DesignTokens.Color.textSecondary.ns
        formatLabel.frame = NSRect(x: side + 58, y: y, width: panelWidth - side * 2 - 58, height: 16)
        container.addSubview(formatLabel)

        panel.contentView = container
    }

    private func sectionLabel(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.grabbit(.caption)
        label.textColor = DesignTokens.Color.textSecondary.ns
        label.frame = NSRect(x: x, y: y, width: width, height: 14)
        return label
    }

    func show(
        from window: NSWindow,
        anchorScreenRect: NSRect,
        name: String,
        saveLocation: String
    ) {
        hide()
        hostWindow = window
        self.anchorScreenRect = anchorScreenRect
        nameField.stringValue = name
        saveLocationLabel.stringValue = saveLocation

        let panelW = panel.frame.width
        let panelX = (anchorScreenRect.midX - panelW / 2).rounded()
        let panelY = anchorScreenRect.minY - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.orderFront(nil)
        window.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)

        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let contentView = self.panel.contentView {
                let point = contentView.convert(event.locationInWindow, from: nil)
                if contentView.bounds.contains(point) { return event }
            }
            if self.anchorScreenRect.contains(NSEvent.mouseLocation) { return event }
            self.hide()
            return event
        }
    }

    func hide() {
        if panel.isVisible {
            commitNameIfNeeded()
        }
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        panel.orderOut(nil)
        hostWindow = nil
    }

    var isVisible: Bool { panel.isVisible }

    func refreshSaveLocation() {
        saveLocationLabel.stringValue = AppSettings.destinationFolderDisplayPath
    }

    private func commitNameIfNeeded() {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onNameCommitted(trimmed)
    }

    @objc private func changeSaveLocation() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose"
        openPanel.message = "Choose where Grabbit saves recordings and exports."
        openPanel.directoryURL = AppSettings.destinationFolderURL

        openPanel.beginSheetModal(for: hostWindow ?? panel) { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            AppSettings.destinationFolderURL = url
            self?.refreshSaveLocation()
            self?.onSaveLocationChanged()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitNameIfNeeded()
            hide()
            return true
        }
        return false
    }
}

// MARK: - Annotation titlebar

enum AnnotationTitlebarStyle {
    private static weak var centeredTitleControl: NSView?

    static func apply(
        to window: NSWindow,
        title: String,
        backgroundColor color: NSColor,
        laysContentBelowTitlebar: Bool = false,
        usesSystemAppearance: Bool = false
    ) {
        window.title = title
        if laysContentBelowTitlebar {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
        } else {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
        }
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        window.backgroundColor = color
        if usesSystemAppearance {
            window.appearance = nil
        } else {
            window.appearance = NSAppearance(named: color.isLightAnnotationBackground ? .aqua : .darkAqua)
        }
        window.isMovableByWindowBackground = !laysContentBelowTitlebar
        hideNonCloseWindowButtons(on: window)
        DispatchQueue.main.async {
            layoutCloseButton(in: window)
        }
    }

    static func installCenteredTitle(_ control: NSView, in window: NSWindow) {
        centeredTitleControl = control
        window.titleVisibility = .hidden
        DispatchQueue.main.async {
            layoutCenteredTitle(in: window)
        }
    }

    static func updateCenteredTitle(_ title: String, in window: NSWindow) {
        if let control = centeredTitleControl as? AnnotationTitlebarTitleControl {
            control.setTitle(title)
            layoutCenteredTitle(in: window)
        } else {
            window.title = title
        }
    }

    static func installTrailingAccessory(_ view: NSView, in window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = view
        window.addTitlebarAccessoryViewController(accessory)
        // Accessories finish positioning asynchronously — relayout the title so it
        // doesn't sit under Copy / Open in Grabbit (especially on narrow aspect-fitted windows).
        DispatchQueue.main.async {
            layoutCenteredTitle(in: window)
        }
    }

    private static let closeButtonLeftPadding = DesignTokens.Spacing.md
    private static let closeButtonTopPadding: CGFloat = 10

    private static func hideNonCloseWindowButtons(on window: NSWindow) {
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    static func layoutCloseButton(in window: NSWindow) {
        guard let closeButton = window.standardWindowButton(.closeButton),
              let container = closeButton.superview else { return }

        let size = closeButton.frame.size
        let y = container.isFlipped
            ? closeButtonTopPadding
            : container.bounds.height - size.height - closeButtonTopPadding
        closeButton.setFrameOrigin(NSPoint(x: closeButtonLeftPadding, y: y))
        layoutCenteredTitle(in: window)
    }

    static func layoutCenteredTitle(in window: NSWindow) {
        guard let control = centeredTitleControl,
              let closeButton = window.standardWindowButton(.closeButton),
              let titlebar = closeButton.superview else { return }

        if control.superview !== titlebar {
            titlebar.addSubview(control)
        }

        let gap = DesignTokens.Spacing.sm
        let leftLimit = closeButton.frame.maxX + gap
        var rightLimit = titlebar.bounds.width - gap
        for accessory in window.titlebarAccessoryViewControllers {
            let accessoryView = accessory.view
            guard accessoryView.superview != nil else { continue }
            let frameInTitlebar = accessoryView.convert(accessoryView.bounds, to: titlebar)
            // Ignore zero-size / not-yet-laid-out accessories so we don't clamp to 0.
            guard frameInTitlebar.width > 1 else { continue }
            rightLimit = min(rightLimit, frameInTitlebar.minX - gap)
        }

        let availableWidth = max(40, rightLimit - leftLimit)
        if let titleControl = control as? AnnotationTitlebarTitleControl {
            titleControl.setTitle(titleControl.title, maxWidth: availableWidth)
        } else {
            control.frame.size.width = min(max(control.frame.width, 40), availableWidth)
        }

        let controlWidth = control.frame.width
        let idealX = ((titlebar.bounds.width - controlWidth) / 2).rounded(.down)
        var x = idealX
        // Keep the name fully inside [leftLimit, rightLimit]. When trailing buttons
        // would force it off-center, pin beside the close button instead of overlapping.
        if x + controlWidth > rightLimit {
            x = rightLimit - controlWidth
        }
        if x < leftLimit {
            x = leftLimit
        }

        let y = titlebar.isFlipped
            ? closeButtonTopPadding + (closeButton.frame.height - control.frame.height) / 2
            : titlebar.bounds.height - closeButtonTopPadding - closeButton.frame.height
            + (closeButton.frame.height - control.frame.height) / 2
        control.setFrameOrigin(NSPoint(x: x, y: y))
        control.autoresizingMask = [.minYMargin, .maxYMargin]
    }

    /// Positions annotation content in the window. When `laysContentBelowTitlebar` is true,
    /// content fills the area below the standard titlebar instead of underlapping it.
    static func layoutContentContainer(
        _ container: NSView,
        in window: NSWindow,
        laysContentBelowTitlebar: Bool = false
    ) {
        guard let contentView = window.contentView else { return }
        if laysContentBelowTitlebar {
            container.frame = contentView.bounds
            container.autoresizingMask = [.width, .height]
        } else {
            let safeRect = contentView.convert(window.contentLayoutRect, from: nil)
            container.frame = safeRect
            container.autoresizingMask = [.width, .maxYMargin]
        }
        layoutCloseButton(in: window)
    }
}

private extension NSColor {
    var isLightAnnotationBackground: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return true }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.55
    }

    var annotationTitlebarForeground: NSColor {
        isLightAnnotationBackground
            ? DesignTokens.Color.textPrimary.ns
            : DesignTokens.Color.textOnPrimary.ns
    }
}

private extension NSImage {
    func annotationTitlebarColor() -> NSColor {
        guard let tiff = tiffRepresentation,
              let ciImage = CIImage(data: tiff) else {
            return .windowBackgroundColor
        }

        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return .windowBackgroundColor }

        let stripHeight = max(1, extent.height * 0.03)
        let cropRect = CGRect(
            x: extent.minX + extent.width * 0.1,
            y: extent.maxY - stripHeight,
            width: extent.width * 0.8,
            height: stripHeight
        )
        let cropped = ciImage.cropped(to: cropRect)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: cropped,
            kCIInputExtentKey: CIVector(cgRect: cropped.extent),
        ]),
              let output = filter.outputImage else {
            return .windowBackgroundColor
        }

        var rgba = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output,
            toBitmap: &rgba,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return NSColor(
            red: CGFloat(rgba[0]) / 255,
            green: CGFloat(rgba[1]) / 255,
            blue: CGFloat(rgba[2]) / 255,
            alpha: 1
        )
    }
}
