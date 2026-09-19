//
//  ScreenshotEngine.swift
//  Grabbit
//
//  Created by Ethan Watson on 6/27/26.
//

import AppKit
import CoreImage
import ScreenCaptureKit

class ScreenshotEngine {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func captureWindow(
        _ windowID: CGWindowID,
        background: RecordingBackgroundStyle = .none,
        completion: @escaping (NSImage?) -> Void
    ) {
        Task {
            do {
                let availableContent = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard let window = availableContent.windows.first(where: { $0.windowID == windowID }) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                let filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.scalesToFit = false

                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let windowImage = CIImage(cgImage: cgImage)

                let outputImage: CIImage
                if background == .none {
                    outputImage = windowImage
                } else {
                    let canvasSize = RecordingBackgroundRenderer.canvasSize(for: scale)
                    outputImage = RecordingBackgroundRenderer.composite(
                        windowImage: windowImage,
                        background: background,
                        canvasSize: canvasSize,
                        scale: scale
                    )
                }

                let extent = outputImage.extent
                guard let result = ciContext.createCGImage(outputImage, from: extent) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                let logicalSize: NSSize
                if background == .none {
                    logicalSize = NSSize(width: window.frame.width, height: window.frame.height)
                } else {
                    logicalSize = RecordingBackgroundRenderer.canvasSize(for: 1)
                }

                let nsImage = NSImage(cgImage: result, size: logicalSize)
                DispatchQueue.main.async { completion(nsImage) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    static func captureWindowCGImage(
        _ windowID: CGWindowID
    ) async -> (cgImage: CGImage, logicalSize: NSSize)? {
        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let window = availableContent.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.scalesToFit = false
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (cgImage, NSSize(width: window.frame.width, height: window.frame.height))
        } catch {
            return nil
        }
    }

    static func captureRegion(_ rect: CGRect, completion: @escaping (NSImage?) -> Void) {
        Task {
            do {
                let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

                guard let display = availableContent.displays.first(where: { display in
                    let displayFrame = CGRect(x: display.frame.origin.x,
                                             y: display.frame.origin.y,
                                             width: CGFloat(display.width),
                                             height: CGFloat(display.height))
                    return displayFrame.intersects(rect)
                }) ?? availableContent.displays.first else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                // Exclude library / settings / capture chrome so region & full-screen
                // shots never include Grabbit itself (window capture is already scoped).
                let exclude = WindowSelector.grabbitOwnedWindows(in: availableContent)
                let filter = SCContentFilter(display: display, excludingWindows: exclude)

                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let config = SCStreamConfiguration()
                config.width = Int(rect.width * scale)
                config.height = Int(rect.height * scale)
                let displayOriginX = display.frame.origin.x
                let displayOriginY = display.frame.origin.y
                let displayHeight = CGFloat(display.height)

                let localRect = CGRect(
                    x: rect.origin.x - displayOriginX,
                    y: displayHeight - (rect.origin.y - displayOriginY) - rect.height,
                    width: rect.width,
                    height: rect.height
                )

                config.sourceRect = localRect
                config.scalesToFit = false

                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let nsImage = NSImage(cgImage: cgImage, size: rect.size)
                DispatchQueue.main.async { completion(nsImage) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
