//
//  ScrollingCaptureEngine.swift
//  Grabbit
//
//  Auto-scrolls a window and stitches frames into one tall screenshot.
//

import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

enum ScrollingCaptureEngine {
    private static let maxFrames = 48
    private static let maxPixelHeight = 16_384
    private static let settleNanoseconds: UInt64 = 220_000_000
    private static let lazyRetryNanoseconds: UInt64 = 380_000_000

    struct Result {
        let image: NSImage
        let frame: CGRect
    }

    enum Outcome {
        case success(Result)
        case cancelled
        case failed
    }

    @MainActor
    static func capture(windowID: CGWindowID) async -> Outcome {
        ToastWindow.show(
            message: "Scrolling capture…  Esc to stop",
            chrome: .darkNeutral,
            autoDismiss: false
        )

        let originalMouse = NSEvent.mouseLocation
        NSCursor.hide()
        var escapeLocal: Any?
        var escapeGlobal: Any?
        var cancelled = false

        escapeLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            cancelled = true
            return nil
        }
        escapeGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            cancelled = true
        }

        defer {
            NSCursor.unhide()
            restoreMouse(to: originalMouse)
            if let escapeLocal { NSEvent.removeMonitor(escapeLocal) }
            if let escapeGlobal { NSEvent.removeMonitor(escapeGlobal) }
            ToastWindow.dismissCurrent()
        }

        guard let session = await WindowSession.load(windowID: windowID) else {
            return .failed
        }

        moveMouse(to: session.scrollAimPoint)
        try? await Task.sleep(nanoseconds: 80_000_000)
        if cancelled || Task.isCancelled { return .cancelled }

        await session.scrollToTop()
        try? await Task.sleep(nanoseconds: settleNanoseconds)
        if cancelled || Task.isCancelled { return .cancelled }

        guard let first = await captureBitmap(windowID: windowID) else { return .failed }
        var chrome = ChromeInsets.detect(in: first, pid: session.pid, windowFrame: session.frame)

        session.scrollDown(distance: max(140, (first.height - chrome.header - chrome.footer) / 2))
        try? await Task.sleep(nanoseconds: settleNanoseconds)
        if cancelled || Task.isCancelled { return .cancelled }

        guard var second = await captureBitmap(windowID: windowID), second.width == first.width else {
            if let image = first.makeNSImage() {
                return .success(Result(image: image, frame: session.frame))
            }
            return .failed
        }

        if second.isNearlyEqual(to: first, chrome: chrome) {
            try? await Task.sleep(nanoseconds: lazyRetryNanoseconds)
            if cancelled || Task.isCancelled { return .cancelled }
            if let retry = await captureBitmap(windowID: windowID), retry.width == first.width {
                second = retry
            }
            if second.isNearlyEqual(to: first, chrome: chrome) {
                if let image = first.makeNSImage() {
                    return .success(Result(image: image, frame: session.frame))
                }
                return .failed
            }
        }

        chrome = chrome.refined(previous: first, next: second)
        var stitched = StitchedContent(first: first, chrome: chrome)
        if let delta = first.scrollDelta(to: second, chrome: chrome), delta > 4 {
            _ = stitched.append(newRowsFrom: second, delta: delta)
        }

        var previous = second
        var frames = 2

        while frames < maxFrames, stitched.pixelHeight < maxPixelHeight {
            if cancelled || Task.isCancelled { return .cancelled }

            session.scrollDown(distance: stitched.recommendedScrollPixels)
            try? await Task.sleep(nanoseconds: settleNanoseconds)
            if cancelled || Task.isCancelled { return .cancelled }

            guard var next = await captureBitmap(windowID: windowID) else { break }
            if next.width != first.width {
                break
            }

            if next.isNearlyEqual(to: previous, chrome: chrome) {
                try? await Task.sleep(nanoseconds: lazyRetryNanoseconds)
                if cancelled || Task.isCancelled { return .cancelled }
                if let retry = await captureBitmap(windowID: windowID), retry.width == first.width {
                    next = retry
                }
                if next.isNearlyEqual(to: previous, chrome: chrome) {
                    break
                }
            }

            guard let delta = previous.scrollDelta(to: next, chrome: chrome), delta > 4 else {
                break
            }

            if !stitched.append(newRowsFrom: next, delta: delta) {
                break
            }

            previous = next
            frames += 1
        }

        guard let image = stitched.makeImage(lastFrame: previous, logicalSize: first.logicalSize) else {
            return .failed
        }
        return .success(Result(image: image, frame: session.frame))
    }

    @MainActor
    private static func captureBitmap(windowID: CGWindowID) async -> Bitmap? {
        guard let captured = await ScreenshotEngine.captureWindowCGImage(windowID) else { return nil }
        return Bitmap(image: captured.cgImage, logicalSize: captured.logicalSize)
    }

    @MainActor
    private static func moveMouse(to cocoaPoint: NSPoint) {
        let quartz = quartzPoint(from: cocoaPoint)
        if let move = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartz,
            mouseButton: .left
        ) {
            move.post(tap: .cghidEventTap)
        }
        CGWarpMouseCursorPosition(quartz)
    }

    @MainActor
    private static func restoreMouse(to cocoaPoint: NSPoint) {
        CGWarpMouseCursorPosition(quartzPoint(from: cocoaPoint))
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }

    private static func quartzPoint(from cocoaPoint: NSPoint) -> CGPoint {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let maxY = primary?.frame.maxY ?? cocoaPoint.y
        return CGPoint(x: cocoaPoint.x, y: maxY - cocoaPoint.y)
    }
}

// MARK: - Window session (scroll target)

private struct WindowSession {
    let windowID: CGWindowID
    let pid: pid_t
    var frame: CGRect
    let scrollAimPoint: NSPoint

    @MainActor
    static func load(windowID: CGWindowID) async -> WindowSession? {
        let windows = await WindowSelector.fetchRecordableWindows()
        guard let window = windows.first(where: { $0.windowID == windowID }),
              let pid = window.owningApplication?.processID else { return nil }
        let frame = window.frame
        let aim = NSPoint(
            x: frame.midX,
            y: frame.minY + frame.height * 0.55
        )
        return WindowSession(windowID: windowID, pid: pid_t(pid), frame: frame, scrollAimPoint: aim)
    }

    @MainActor
    func scrollToTop() async {
        AXScrolling.scrollToTop(pid: pid)
        for _ in 0..<10 {
            postScroll(pixels: 4_000, down: false)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    @MainActor
    func scrollDown(distance: Int) {
        let pixels = max(120, min(distance, 1_800))
        postScroll(pixels: pixels, down: true)
    }

    @MainActor
    private func postScroll(pixels: Int, down: Bool) {
        let delta = Int32(down ? -pixels : pixels)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Accessibility helpers

private enum AXScrolling {
    static func scrollToTop(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        guard let window = focusedWindow(app),
              let bar = verticalScrollBar(in: window, depth: 0, budget: Budget()) else { return }
        var minValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(bar, kAXMinValueAttribute as CFString, &minValue) == .success,
           let minNum = minValue as? NSNumber {
            AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, minNum)
        } else {
            AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 0 as CFNumber)
        }
    }

    static func contentChrome(
        pid: pid_t,
        windowFrame: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> ChromeInsets? {
        let app = AXUIElementCreateApplication(pid)
        guard let window = focusedWindow(app),
              let area = largestScrollArea(in: window, depth: 0, budget: Budget()),
              let axFrame = frame(of: area) else { return nil }

        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let maxY = primary?.frame.maxY ?? windowFrame.maxY
        let windowTop = maxY - windowFrame.maxY
        let localY = axFrame.origin.y - windowTop
        let scale = CGFloat(imageHeight) / max(windowFrame.height, 1)

        let header = Int((localY * scale).rounded(.down))
        let contentHeight = Int((axFrame.height * scale).rounded(.down))
        let footer = imageHeight - header - contentHeight
        let clampedHeader = max(0, min(header, imageHeight / 2))
        let clampedFooter = max(0, min(footer, imageHeight / 3))
        guard clampedHeader + clampedFooter < imageHeight - 24 else { return nil }
        _ = imageWidth
        return ChromeInsets(header: clampedHeader, footer: clampedFooter)
    }

    private struct Budget {
        var remaining = 220
        mutating func take() -> Bool {
            remaining -= 1
            return remaining >= 0
        }
    }

    private static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let window = value {
            return (window as! AXUIElement)
        }
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return nil }
        return windows.first
    }

    private static func largestScrollArea(
        in element: AXUIElement,
        depth: Int,
        budget: Budget
    ) -> AXUIElement? {
        var budget = budget
        guard depth < 14, budget.take() else { return nil }
        var best: (AXUIElement, CGFloat)?
        visitScrollAreas(element, depth: depth, budget: &budget) { area, size in
            if best == nil || size > best!.1 {
                best = (area, size)
            }
        }
        return best?.0
    }

    private static func visitScrollAreas(
        _ element: AXUIElement,
        depth: Int,
        budget: inout Budget,
        visit: (AXUIElement, CGFloat) -> Void
    ) {
        guard depth < 14, budget.take() else { return }
        if role(of: element) == kAXScrollAreaRole as String,
           let frame = frame(of: element) {
            visit(element, frame.width * frame.height)
        }
        for child in children(of: element) {
            visitScrollAreas(child, depth: depth + 1, budget: &budget, visit: visit)
        }
    }

    private static func verticalScrollBar(
        in element: AXUIElement,
        depth: Int,
        budget: Budget
    ) -> AXUIElement? {
        var budget = budget
        return findVerticalScrollBar(element, depth: depth, budget: &budget)
    }

    private static func findVerticalScrollBar(
        _ element: AXUIElement,
        depth: Int,
        budget: inout Budget
    ) -> AXUIElement? {
        guard depth < 14, budget.take() else { return nil }
        if role(of: element) == kAXScrollBarRole as String {
            var orientation: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXOrientationAttribute as CFString, &orientation) == .success,
               let orientation = orientation as? String,
               orientation == (kAXVerticalOrientationValue as String) {
                return element
            }
        }
        var scrollBar: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXVerticalScrollBarAttribute as CFString, &scrollBar) == .success,
           let scrollBar {
            return (scrollBar as! AXUIElement)
        }
        for child in children(of: element) {
            if let found = findVerticalScrollBar(child, depth: depth + 1, budget: &budget) {
                return found
            }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionRef = positionValue,
              let sizeRef = sizeValue else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        let posAX = positionRef as! AXValue
        let sizeAX = sizeRef as! AXValue
        AXValueGetValue(posAX, .cgPoint, &origin)
        AXValueGetValue(sizeAX, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}

// MARK: - Chrome + stitching

private struct ChromeInsets {
    var header: Int
    var footer: Int

    static func detect(in bitmap: Bitmap, pid: pid_t, windowFrame: CGRect) -> ChromeInsets {
        if let ax = AXScrolling.contentChrome(
            pid: pid,
            windowFrame: windowFrame,
            imageWidth: bitmap.width,
            imageHeight: bitmap.height
        ) {
            return ax
        }
        return ChromeInsets(header: 0, footer: 0)
    }

    func refined(previous: Bitmap, next: Bitmap) -> ChromeInsets {
        let detectedHeader = previous.matchingPrefixHeight(with: next)
        let detectedFooter = previous.matchingSuffixHeight(with: next)
        let maxHeader = previous.height / 2
        let maxFooter = previous.height / 3
        return ChromeInsets(
            header: min(max(header, detectedHeader), maxHeader),
            footer: min(max(footer, detectedFooter), maxFooter)
        )
    }
}

private struct StitchedContent {
    let width: Int
    let chrome: ChromeInsets
    let viewportContentHeight: Int
    private let headerRows: [UInt8]
    private var contentRows: [UInt8]
    private let bytesPerPixel = 4

    var pixelHeight: Int { contentRows.count / max(width * bytesPerPixel, 1) }

    var recommendedScrollPixels: Int {
        max(140, Int(Double(viewportContentHeight) * 0.45))
    }

    init(first: Bitmap, chrome: ChromeInsets) {
        self.width = first.width
        self.chrome = chrome
        self.viewportContentHeight = max(1, first.height - chrome.header - chrome.footer)
        self.headerRows = first.rowBytes(in: 0..<chrome.header)
        self.contentRows = first.rowBytes(in: chrome.header..<(first.height - chrome.footer))
    }

    mutating func append(newRowsFrom bitmap: Bitmap, delta: Int) -> Bool {
        let footer = chrome.footer
        let bottom = bitmap.height - footer
        let start = max(chrome.header, bottom - delta)
        guard start < bottom else { return false }
        contentRows.append(contentsOf: bitmap.rowBytes(in: start..<bottom))
        return true
    }

    func makeImage(lastFrame: Bitmap, logicalSize: NSSize) -> NSImage? {
        let header = chrome.header
        let footer = min(chrome.footer, lastFrame.height)
        let contentHeight = pixelHeight
        let totalHeight = header + contentHeight + footer
        guard totalHeight > 0, width > 0 else { return nil }

        let bytesPerRow = width * bytesPerPixel
        let totalBytes = totalHeight * bytesPerRow
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: totalBytes)
        output.initialize(repeating: 0, count: totalBytes)
        defer { output.deallocate() }

        var destY = 0
        headerRows.withUnsafeBytes { buffer in
            guard header > 0, let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            output.update(from: base, count: header * bytesPerRow)
        }
        destY += header

        contentRows.withUnsafeBytes { buffer in
            guard contentHeight > 0, let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            (output + destY * bytesPerRow).update(from: base, count: contentHeight * bytesPerRow)
        }
        destY += contentHeight

        if footer > 0 {
            let footerStart = lastFrame.height - footer
            lastFrame.copyRows(
                footerStart..<lastFrame.height,
                to: output,
                destinationY: destY,
                destinationHeight: totalHeight
            )
        }

        guard let context = CGContext(
            data: output,
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage = context.makeImage() else { return nil }

        let scale = CGFloat(width) / max(logicalSize.width, 1)
        let size = NSSize(width: logicalSize.width, height: CGFloat(totalHeight) / max(scale, 1))
        return NSImage(cgImage: cgImage, size: size)
    }
}

// MARK: - Bitmap

private final class Bitmap: @unchecked Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: UnsafeMutablePointer<UInt8>
    let logicalSize: NSSize

    init?(image: CGImage, logicalSize: NSSize) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: height * bytesPerRow)
        pixels.initialize(repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            pixels.deallocate()
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
        self.logicalSize = logicalSize
    }

    deinit {
        pixels.deallocate()
    }

    func makeNSImage() -> NSImage? {
        let bytesPerRow = self.bytesPerRow
        guard let context = CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: logicalSize)
    }

    func rowBytes(in range: Range<Int>) -> [UInt8] {
        let bytes = width * 4
        var out: [UInt8] = []
        out.reserveCapacity(range.count * bytes)
        for y in range {
            guard y >= 0, y < height else { continue }
            let src = pixels + y * bytesPerRow
            out.append(contentsOf: UnsafeBufferPointer(start: src, count: bytes))
        }
        return out
    }

    func isNearlyEqual(to other: Bitmap, chrome: ChromeInsets) -> Bool {
        guard width == other.width, height == other.height else { return false }
        let start = chrome.header
        let end = height - chrome.footer
        guard end - start > 8 else { return rowsMatch(other, yRange: 0..<height, threshold: 6) }
        return rowsMatch(other, yRange: start..<end, threshold: 6)
    }

    func matchingPrefixHeight(with other: Bitmap) -> Int {
        guard width == other.width, height == other.height else { return 0 }
        let limit = height / 2
        var y = 0
        while y < limit, rowDifference(y, other, y) < 14 {
            y += 1
        }
        return y
    }

    func matchingSuffixHeight(with other: Bitmap) -> Int {
        guard width == other.width, height == other.height else { return 0 }
        let limit = height / 3
        var n = 0
        while n < limit, rowDifference(height - 1 - n, other, other.height - 1 - n) < 14 {
            n += 1
        }
        return n
    }

    func scrollDelta(to next: Bitmap, chrome: ChromeInsets) -> Int? {
        guard width == next.width else { return nil }
        let header = chrome.header
        let contentBottom = min(height, next.height) - chrome.footer
        let contentHeight = contentBottom - header
        guard contentHeight > 24 else { return nil }

        let probeOrigin = header + min(12, max(0, contentHeight / 20))
        let probeCount = min(16, max(8, contentHeight / 4))
        var bestDelta = 0
        var bestDiff = Double.greatestFiniteMagnitude

        for delta in 0..<contentHeight {
            let previousY = probeOrigin + delta
            if previousY + probeCount > contentBottom { break }
            if probeOrigin + probeCount > min(next.height, height) - chrome.footer { break }
            var diff = 0.0
            for i in 0..<probeCount {
                diff += rowDifference(previousY + i, next, probeOrigin + i)
            }
            diff /= Double(probeCount)
            if diff < 7 {
                return delta
            }
            if diff < bestDiff {
                bestDiff = diff
                bestDelta = delta
            }
        }

        return bestDiff < 18 ? bestDelta : nil
    }

    func copyRows(
        _ range: Range<Int>,
        to destination: UnsafeMutablePointer<UInt8>,
        destinationY: Int,
        destinationHeight: Int
    ) {
        let bytes = width * 4
        for (offset, y) in range.enumerated() {
            let destRow = destinationY + offset
            guard destRow >= 0, destRow < destinationHeight, y >= 0, y < height else { continue }
            let dest = destination + destRow * bytes
            let src = pixels + y * bytesPerRow
            dest.update(from: src, count: bytes)
        }
    }

    private func rowsMatch(_ other: Bitmap, yRange: Range<Int>, threshold: Double) -> Bool {
        var total = 0.0
        var count = 0
        for y in yRange {
            total += rowDifference(y, other, y)
            count += 1
        }
        guard count > 0 else { return true }
        return total / Double(count) < threshold
    }

    private func rowDifference(_ y: Int, _ other: Bitmap, _ otherY: Int) -> Double {
        let rowA = pixels + y * bytesPerRow
        let rowB = other.pixels + otherY * other.bytesPerRow
        var diff = 0
        var count = 0
        var x = 0
        while x < width {
            let i = x * 4
            diff += abs(Int(rowA[i]) - Int(rowB[i]))
            diff += abs(Int(rowA[i + 1]) - Int(rowB[i + 1]))
            diff += abs(Int(rowA[i + 2]) - Int(rowB[i + 2]))
            count += 3
            x += 8
        }
        return Double(diff) / Double(max(count, 1))
    }
}
