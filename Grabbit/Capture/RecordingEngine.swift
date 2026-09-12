//
//  RecordingEngine.swift
//  Grabbit
//
//  Created by Ethan Watson on 6/27/26.
//

import ScreenCaptureKit
@preconcurrency import AVFoundation
import AppKit
import CoreImage

// MARK: - RecordingCaptureTarget

enum RecordingCaptureTarget: Equatable {
    case fullScreen
    case window(CGWindowID)
    case app(bundleIdentifier: String)
    case region(CGRect)
}

// MARK: - RecordingBackgroundStyle

enum RecordingBackgroundStyle: Equatable {
    case none
    case warm
    case cool
    case midnight
    case custom(path: String)

    var menuTitle: String {
        switch self {
        case .none:     return "None"
        case .warm:     return "Warm"
        case .cool:     return "Cool"
        case .midnight: return "Midnight"
        case .custom:   return "Custom Image"
        }
    }
}

class RecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate,
                       AVCaptureAudioDataOutputSampleBufferDelegate {

    static let shared = RecordingEngine()

    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((URL?) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?

    /// Whether a recording is currently active.
    private(set) var isRecording = false
    /// True from the moment startRecording() is called until the stream either starts or fails.
    private(set) var isStartingRecording = false

    private var includeMic: Bool = false
    private var includeSystemAudio: Bool = false
    private var micDeviceID: String?
    private var captureTarget: RecordingCaptureTarget = .fullScreen
    private var recordingBackground: RecordingBackgroundStyle = .none
    private var usesBackgroundComposite = false

    // MARK: - Private recording state

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // Microphone
    private var audioCaptureSession: AVCaptureSession?
    private var micAnchorPTS: CMTime?
    private var sessionAnchorTime: CMTime = .invalid

    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var streamRunning = false
    private var outputURL: URL?
    private var sessionStarted = false
    private var recordingPixelScale: Int = 1

    // MARK: - Prewarm

    /// Triggers the SCK permission dialog before the user starts a recording.
    func prewarm() {
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    // MARK: - Start Recording

    func startRecording(
        captureTarget: RecordingCaptureTarget = .fullScreen,
        recordingBackground: RecordingBackgroundStyle = .none,
        micEnabled: Bool = false,
        systemAudioEnabled: Bool = false,
        micDeviceID: String? = nil
    ) {
        assert(Thread.isMainThread)
        guard !isRecording, !isStartingRecording else { return }
        isStartingRecording = true
        self.captureTarget = captureTarget
        self.recordingBackground = recordingBackground
        self.includeMic = micEnabled
        self.includeSystemAudio = systemAudioEnabled
        self.micDeviceID = micDeviceID
        let backingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
        recordingPixelScale = Int(backingScale)

        Task {
            do {
                // Fetch shareable content (also validates SCK permission).
                let availableContent: SCShareableContent
                do {
                    availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                } catch {
                    DispatchQueue.main.async {
                        self.isStartingRecording = false
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                        )
                        self.onRecordingFailed?(RecordingError.permissionDenied)
                    }
                    return
                }

                let scale = recordingPixelScale

                let filter: SCContentFilter
                let streamW: Int
                let streamH: Int
                let outputW: Int
                let outputH: Int

                switch captureTarget {
                case .fullScreen:
                    let mainID = CGMainDisplayID()
                    guard let display = availableContent.displays.first(where: { $0.displayID == mainID })
                                     ?? availableContent.displays.first else {
                        DispatchQueue.main.async {
                            self.isStartingRecording = false
                            self.onRecordingFailed?(RecordingError.noDisplayFound)
                        }
                        return
                    }
                    filter = SCContentFilter(display: display, excludingWindows: [])
                    streamW = display.width * scale
                    streamH = display.height * scale
                    outputW = streamW
                    outputH = streamH
                    usesBackgroundComposite = false

                case .window(let windowID):
                    guard let window = availableContent.windows.first(where: { $0.windowID == windowID }) else {
                        DispatchQueue.main.async {
                            self.isStartingRecording = false
                            self.onRecordingFailed?(RecordingError.windowNotFound)
                        }
                        return
                    }
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    streamW = Int(window.frame.width) * scale
                    streamH = Int(window.frame.height) * scale
                    let needsCanvasLayout = recordingBackground != .none
                    if needsCanvasLayout {
                        outputW = 1920 * scale
                        outputH = 1080 * scale
                        usesBackgroundComposite = true
                    } else {
                        outputW = streamW
                        outputH = streamH
                        usesBackgroundComposite = false
                    }

                case .app(let bundleIdentifier):
                    guard let layout = WindowSelector.appCaptureLayout(
                        bundleIdentifier: bundleIdentifier,
                        in: availableContent
                    ) else {
                        DispatchQueue.main.async {
                            self.isStartingRecording = false
                            self.onRecordingFailed?(RecordingError.appNotFound)
                        }
                        return
                    }
                    filter = SCContentFilter(
                        display: layout.display,
                        including: [layout.application],
                        exceptingWindows: []
                    )
                    streamW = Int(layout.frame.width) * scale
                    streamH = Int(layout.frame.height) * scale
                    outputW = streamW
                    outputH = streamH
                    usesBackgroundComposite = false

                case .region(let rect):
                    guard let display = availableContent.displays.first(where: { display in
                        let displayFrame = CGRect(
                            x: display.frame.origin.x,
                            y: display.frame.origin.y,
                            width: CGFloat(display.width),
                            height: CGFloat(display.height)
                        )
                        return displayFrame.intersects(rect)
                    }) ?? availableContent.displays.first else {
                        DispatchQueue.main.async {
                            self.isStartingRecording = false
                            self.onRecordingFailed?(RecordingError.noDisplayFound)
                        }
                        return
                    }
                    filter = SCContentFilter(display: display, excludingWindows: [])
                    streamW = Int(rect.width) * scale
                    streamH = Int(rect.height) * scale
                    outputW = streamW
                    outputH = streamH
                    usesBackgroundComposite = false
                }

                let pixelW = outputW
                let pixelH = outputH

                // Stream configuration
                let config = SCStreamConfiguration()
                config.width = streamW
                config.height = streamH
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = true
                config.capturesAudio = includeSystemAudio
                config.sampleRate = 48_000
                config.channelCount = 2

                switch captureTarget {
                case .region(let rect):
                    if let display = WindowSelector.display(matching: rect, in: availableContent) {
                        config.sourceRect = WindowSelector.sourceRect(for: rect, on: display)
                        config.scalesToFit = false
                    }
                case .app(let bundleIdentifier):
                    if let layout = WindowSelector.appCaptureLayout(
                        bundleIdentifier: bundleIdentifier,
                        in: availableContent
                    ) {
                        config.sourceRect = layout.sourceRect
                        config.scalesToFit = false
                    }
                default:
                    break
                }

                // Output file
                try AppSettings.ensureDestinationFolderExists()
                let folderURL = AppSettings.destinationFolderURL
                let url = CaptureNaming.uniqueURL(
                    in: folderURL,
                    preferredFilename: CaptureNaming.recordingFilename()
                )
                self.outputURL = url

                // Asset writer + video input
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                self.assetWriter = writer

                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: pixelW,
                    AVVideoHeightKey: pixelH
                ]
                let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                vInput.expectsMediaDataInRealTime = true
                self.videoInput = vInput
                writer.add(vInput)

                // Pixel buffer adaptor (provides a pool for composited frames)
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: vInput,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                        kCVPixelBufferWidthKey as String: pixelW,
                        kCVPixelBufferHeightKey as String: pixelH,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                    ]
                )
                self.pixelBufferAdaptor = adaptor

                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 48_000,
                    AVEncoderBitRateKey: 128_000
                ]

                // System audio (ScreenCaptureKit — shares timeline with video).
                if includeSystemAudio {
                    let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    sysInput.expectsMediaDataInRealTime = true
                    self.systemAudioInput = sysInput
                    writer.add(sysInput)
                }

                // Microphone (optional — AVCapture clock is retimestamped to the screen stream).
                if includeMic {
                    let micGranted = await Self.requestMicrophoneAccess()
                    if micGranted {
                        let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                        micInput.expectsMediaDataInRealTime = true
                        self.micAudioInput = micInput
                        writer.add(micInput)

                        let micSession = AVCaptureSession()
                        let micDevice = micDeviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
                            ?? AVCaptureDevice.default(for: .audio)
                        if let micDevice,
                           let deviceInput = try? AVCaptureDeviceInput(device: micDevice),
                           micSession.canAddInput(deviceInput) {
                            micSession.addInput(deviceInput)
                        }
                        let audioOut = AVCaptureAudioDataOutput()
                        audioOut.setSampleBufferDelegate(self, queue: .global(qos: .userInitiated))
                        if micSession.canAddOutput(audioOut) {
                            micSession.addOutput(audioOut)
                        }
                        self.audioCaptureSession = micSession
                        micSession.startRunning()
                    } else {
                        DispatchQueue.main.async {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                            )
                        }
                    }
                }

                // Begin writing, then start the screen stream.
                writer.startWriting()

                let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
                self.stream = captureStream
                let mediaQueue = DispatchQueue.global(qos: .userInitiated)
                try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: mediaQueue)
                if includeSystemAudio {
                    try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: mediaQueue)
                }
                try await captureStream.startCapture()

                self.isRecording = true
                self.streamRunning = true
                DispatchQueue.main.async {
                    self.isStartingRecording = false
                    self.onRecordingStarted?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isStartingRecording = false
                    self.onRecordingFailed?(error)
                }
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRecording else { return }

        switch type {
        case .screen:
            guard let vInput = videoInput, vInput.isReadyForMoreMediaData else { return }
            let pts = buffer.presentationTimeStamp
            beginSessionIfNeeded(at: pts)

            guard let screenPB = CMSampleBufferGetImageBuffer(buffer) else { return }

            if usesBackgroundComposite, let composited = compositeOntoRecordingBackground(screenPB) {
                pixelBufferAdaptor?.append(composited, withPresentationTime: pts)
            } else {
                vInput.append(buffer)
            }

        case .audio:
            guard let sysInput = systemAudioInput, sysInput.isReadyForMoreMediaData else { return }
            let pts = buffer.presentationTimeStamp
            beginSessionIfNeeded(at: pts)
            sysInput.append(buffer)

        default:
            break
        }
    }

    private func beginSessionIfNeeded(at pts: CMTime) {
        guard !sessionStarted else { return }
        sessionStarted = true
        sessionAnchorTime = pts
        assetWriter?.startSession(atSourceTime: pts)
    }

    // MARK: - Recording background compositing

    /// Places a window capture onto a gradient or image background (Borumi-style).
    private func compositeOntoRecordingBackground(_ windowBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let scale = CGFloat(recordingPixelScale)
        let canvasSize = RecordingBackgroundRenderer.canvasSize(for: scale)
        let windowImage = CIImage(cvPixelBuffer: windowBuffer)
        let composited = RecordingBackgroundRenderer.composite(
            windowImage: windowImage,
            background: recordingBackground,
            canvasSize: canvasSize,
            scale: scale
        )
        return renderToPixelBuffer(composited, width: Int(canvasSize.width), height: Int(canvasSize.height))
    }

    private func renderToPixelBuffer(_ image: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        var outBuffer: CVPixelBuffer?
        if let pool = pixelBufferAdaptor?.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
        }
        if outBuffer == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outBuffer)
        }
        guard let outBuffer else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let finiteImage = image.clampedToExtent().cropped(to: bounds)
        ciContext.render(
            finiteImage,
            to: outBuffer,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return outBuffer
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        #if DEBUG
        print("[RecordingEngine] Stream stopped with error: \(error)")
        #endif
        streamRunning = false
        guard isRecording else { return }
        isRecording = false
        sessionStarted = false
        audioCaptureSession?.stopRunning()
        audioCaptureSession = nil
        micAnchorPTS = nil
        sessionAnchorTime = .invalid
        videoInput?.markAsFinished()
        micAudioInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        let url = outputURL
        assetWriter?.finishWriting {
            #if DEBUG
            print("[RecordingEngine] File finalized after stream error: \(url?.lastPathComponent ?? "nil")")
            #endif
            DispatchQueue.main.async { self.onRecordingStopped?(url) }
        }
    }

    // MARK: - Stop Recording

    func stopRecording() {
        isRecording = false
        sessionStarted = false
        Task {
            if streamRunning {
                streamRunning = false
                try? await stream?.stopCapture()
            }
            audioCaptureSession?.stopRunning()
            audioCaptureSession = nil
            micAnchorPTS = nil
            sessionAnchorTime = .invalid
            videoInput?.markAsFinished()
            micAudioInput?.markAsFinished()
            systemAudioInput?.markAsFinished()
            let adaptor = pixelBufferAdaptor
            pixelBufferAdaptor = nil
            _ = adaptor  // release after inputs are marked finished
            let url = outputURL
            guard assetWriter?.status == .writing else {
                DispatchQueue.main.async { self.onRecordingStopped?(url) }
                return
            }
            assetWriter?.finishWriting {
                DispatchQueue.main.async { self.onRecordingStopped?(url) }
            }
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording, sessionStarted,
              let micInput = micAudioInput, micInput.isReadyForMoreMediaData,
              let aligned = alignMicBufferToSession(sampleBuffer) else { return }
        micInput.append(aligned)
    }

    // MARK: - Mic timestamp alignment

    /// Maps AVCapture audio timestamps onto the ScreenCaptureKit session timeline.
    private func alignMicBufferToSession(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard sessionAnchorTime.isValid else { return nil }

        let micPTS = CMSampleBufferGetPresentationTimeStamp(buffer)
        if micAnchorPTS == nil {
            micAnchorPTS = micPTS
        }
        guard let anchor = micAnchorPTS else { return nil }

        let relative = CMTimeSubtract(micPTS, anchor)
        let alignedPTS = CMTimeAdd(sessionAnchorTime, relative)

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer),
            presentationTimeStamp: alignedPTS,
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        )
        return status == noErr ? out : nil
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

// MARK: - Errors

private enum RecordingError: LocalizedError {
    case noDisplayFound
    case permissionDenied
    case windowNotFound
    case appNotFound

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for screen recording."
        case .permissionDenied:
            return "Screen recording permission is required. Please grant access in System Settings → Privacy & Security → Screen Recording, then try again."
        case .windowNotFound:
            return "The selected window could not be found. It may have been closed."
        case .appNotFound:
            return "The selected app could not be found. It may have been quit."
        }
    }
}
