//
//  LibraryIntro.swift
//  Grabbit
//
//  Notion-style intro card shown as a modal overlay inside Capture Library
//  (“Show All…”) or Settings (DEBUG launcher).
//

import AppKit
import AVFoundation
import Combine
import SwiftUI

// MARK: - Slides

private struct IntroSlide: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let videoResource: String
    let systemImage: String
    let fill: Color
    let tint: Color

    static let all: [IntroSlide] = [
        IntroSlide(
            id: 0,
            title: "Auto Organize in Grabbit",
            subtitle: "Suggests a filename and project so your library stays organized without the busywork.",
            videoResource: "intro-auto-tagging",
            systemImage: "sparkles",
            fill: DesignTokens.Palette.grape[.t200].swiftUI,
            tint: DesignTokens.Palette.grape[.t700].swiftUI
        ),
        IntroSlide(
            id: 1,
            title: "Spotlight tool",
            subtitle: "Dim everything else and put the focus exactly where you want it.",
            videoResource: "intro-spotlight",
            systemImage: IntroSlide.spotlightSymbol,
            fill: DesignTokens.Palette.blue[.t200].swiftUI,
            tint: DesignTokens.Palette.blue[.t700].swiftUI
        ),
        IntroSlide(
            id: 2,
            title: "Zoom tool",
            subtitle: "Punch in on the details that matter while you walk through a recording.",
            videoResource: "intro-zoom",
            systemImage: "plus.magnifyingglass",
            fill: DesignTokens.Palette.tangerine[.t200].swiftUI,
            tint: DesignTokens.Palette.tangerine[.t700].swiftUI
        ),
    ]

    /// Same preferred / fallback pair as `AnnotationTool.spotlight`.
    private static let spotlightSymbol: String = {
        let preferred = "squareshape.on.pattern.diagonalline"
        if NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil {
            return preferred
        }
        return "squareshape.dotted.squareshape"
    }()
}

// MARK: - Slideshow controller

@MainActor
private final class IntroSlideshowController: ObservableObject {
    @Published private(set) var slideIndex: Int = 0
    @Published private(set) var progress: Double = 0

    let player = AVPlayer()

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var fallbackTask: Task<Void, Never>?
    private var isAdvancing = false
    /// False after `stop()` so in-flight KVO / end / sleep callbacks cannot restart playback.
    private var isActive = false
    /// Bumped on every load and on stop to drop stale async work.
    private var loadGeneration = 0

    var currentSlide: IntroSlide { IntroSlide.all[slideIndex] }

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func start() {
        isActive = true
        loadSlide(at: 0, autoplay: true)
    }

    func stop() {
        isActive = false
        loadGeneration += 1
        fallbackTask?.cancel()
        fallbackTask = nil
        isAdvancing = false
        player.pause()
        tearDownObservers()
        // Clear the item only after pause + observer teardown so FigFilePlayer / VRP
        // aren't poked mid-render when the modal is dismissed.
        player.replaceCurrentItem(with: nil)
    }

    func selectSlide(_ index: Int) {
        guard isActive, IntroSlide.all.indices.contains(index) else { return }
        loadSlide(at: index, autoplay: true)
    }

    private func loadSlide(at index: Int, autoplay: Bool) {
        guard isActive else { return }

        tearDownObservers()
        fallbackTask?.cancel()
        fallbackTask = nil
        isAdvancing = false
        loadGeneration += 1
        let generation = loadGeneration

        slideIndex = index
        progress = 0

        let slide = IntroSlide.all[index]
        guard let url = Bundle.main.url(forResource: slide.videoResource, withExtension: "mp4") else {
            // Missing asset — still advance so the carousel doesn't stall.
            scheduleFallbackAdvance(generation: generation)
            return
        }

        player.pause()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isActive, self.loadGeneration == generation else { return }
                self.advanceToNext()
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isActive, self.loadGeneration == generation else { return }
                if item.status == .readyToPlay, autoplay {
                    self.attachTimeObserver(for: item, generation: generation)
                    self.player.play()
                } else if item.status == .failed {
                    self.scheduleFallbackAdvance(generation: generation)
                }
            }
        }

        if item.status == .readyToPlay, autoplay {
            attachTimeObserver(for: item, generation: generation)
            player.play()
        }
    }

    private func attachTimeObserver(for item: AVPlayerItem, generation: Int) {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isActive, self.loadGeneration == generation else { return }
                let duration = item.duration.seconds
                guard duration.isFinite, duration > 0 else { return }
                self.progress = min(1, max(0, time.seconds / duration))
            }
        }
    }

    private func advanceToNext() {
        guard isActive, !isAdvancing else { return }
        isAdvancing = true
        progress = 1
        let next = (slideIndex + 1) % IntroSlide.all.count
        loadSlide(at: next, autoplay: true)
    }

    private func scheduleFallbackAdvance(generation: Int) {
        fallbackTask?.cancel()
        fallbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, isActive, loadGeneration == generation else { return }
            advanceToNext()
        }
    }

    private func tearDownObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
    }
}

// MARK: - Card

struct LibraryIntroView: View {
    var onContinue: () -> Void
    var onDismiss: () -> Void
    /// Soft cap when the host window is short; width still drives sizing.
    var maxPreviewHeight: CGFloat = .infinity
    /// Lets the host stop AVPlayer before removing the overlay (backdrop / Escape).
    var onRegisterStop: ((@escaping () -> Void) -> Void)? = nil

    @StateObject private var slideshow = IntroSlideshowController()
    @State private var hoveredSlideID: Int?

    private let cardRadius: CGFloat = 20
    /// Distance between neighboring badge centers (56pt diameter − 14pt overlap).
    private let iconCenterSpacing: CGFloat = 42

    var body: some View {
        VStack(spacing: 0) {
            header
            previewWell
                .padding(.top, DesignTokens.Spacing.lg)
        }
        .padding(.top, DesignTokens.Spacing.xxl)
        .padding(.bottom, DesignTokens.Spacing.lg)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .frame(maxWidth: 520)
        .background(DesignTokens.Color.surfaceElevated.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(DesignTokens.Color.border.swiftUI.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 28, x: 0, y: 12)
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        .overlay(alignment: .topTrailing) {
            Button(action: dismissAfterStopping) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .padding(DesignTokens.Spacing.md)
            .help("Close")
        }
        .onAppear {
            onRegisterStop?({ slideshow.stop() })
            slideshow.start()
        }
        .onDisappear { slideshow.stop() }
    }

    private func dismissAfterStopping() {
        slideshow.stop()
        onDismiss()
    }

    private func continueAfterStopping() {
        slideshow.stop()
        onContinue()
    }

    private var header: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            VStack(spacing: DesignTokens.Spacing.md) {
                iconCluster
                progressSegments
            }

            VStack(spacing: DesignTokens.Spacing.sm) {
                Text(slideshow.currentSlide.title)
                    .font(Font.custom(
                        DesignTokens.Typography.postScriptName(for: .semibold),
                        size: 26
                    ))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: slideshow.slideIndex)
                    .id("intro-title-\(slideshow.slideIndex)")

                Text(slideshow.currentSlide.subtitle)
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: slideshow.slideIndex)
                    .id("intro-subtitle-\(slideshow.slideIndex)")
            }

            Button(action: continueAfterStopping) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text("Get Started")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .font(Font.custom(
                    DesignTokens.Typography.postScriptName(for: .medium),
                    size: 14
                ))
                .foregroundStyle(DesignTokens.Color.textOnPrimary.swiftUI)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                        .fill(DesignTokens.Color.primary.swiftUI)
                )
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
    }

    /// Notion-style segment indicators — current slide fills as the video plays.
    private var progressSegments: some View {
        HStack(spacing: 6) {
            ForEach(IntroSlide.all) { slide in
                Button {
                    slideshow.selectSlide(slide.id)
                } label: {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(DesignTokens.Color.border.swiftUI.opacity(0.85))

                            Capsule()
                                .fill(DesignTokens.Color.textPrimary.swiftUI)
                                .frame(width: geo.size.width * fillAmount(for: slide.id))
                        }
                    }
                    .frame(width: 28, height: 3)
                    .contentShape(Rectangle().size(width: 28, height: 16))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(slide.title)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Intro slides")
        .accessibilityValue("Slide \(slideshow.slideIndex + 1) of \(IntroSlide.all.count)")
    }

    private func fillAmount(for index: Int) -> CGFloat {
        if index < slideshow.slideIndex { return 1 }
        if index > slideshow.slideIndex { return 0 }
        return CGFloat(slideshow.progress)
    }

    /// -1 previous, 0 active, +1 next — keeps every badge mounted so glyphs never drop out.
    private func iconSlot(for slideID: Int) -> Int {
        let count = IntroSlide.all.count
        guard count > 0 else { return 0 }
        let active = slideshow.slideIndex
        if slideID == active { return 0 }
        if slideID == (active - 1 + count) % count { return -1 }
        return 1
    }

    private var iconCluster: some View {
        ZStack {
            ForEach(IntroSlide.all) { slide in
                let slot = iconSlot(for: slide.id)
                let isActive = slot == 0
                let isHovered = hoveredSlideID == slide.id

                Button {
                    slideshow.selectSlide(slide.id)
                } label: {
                    featureBadge(for: slide)
                        .scaleEffect(isActive ? 1.12 : 1)
                        .offset(
                            x: CGFloat(slot) * iconCenterSpacing,
                            y: isHovered ? -6 : 0
                        )
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(slide.title)
                .zIndex(isActive ? 3 : (isHovered ? 2 : 1))
                .onHover { hovering in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        hoveredSlideID = hovering ? slide.id : nil
                    }
                }
                .accessibilityLabel(slide.title)
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .frame(width: iconCenterSpacing * 2 + 56, height: 72)
        .padding(.top, DesignTokens.Spacing.xs)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: slideshow.slideIndex)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: hoveredSlideID)
    }

    private func featureBadge(for slide: IntroSlide) -> some View {
        ZStack {
            Circle()
                .fill(DesignTokens.Color.surfaceElevated.swiftUI)
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)

            Circle()
                .strokeBorder(DesignTokens.Color.border.swiftUI, lineWidth: 1)
                .frame(width: 56, height: 56)

            Circle()
                .fill(slide.fill)
                .frame(width: 44, height: 44)

            Image(systemName: slide.systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(slide.tint)
        }
        .contentShape(Circle())
    }

    /// Fill card width; height comes from the fixed video aspect ratio.
    private var previewWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .fill(DesignTokens.Color.listSelectionFill.swiftUI)

            IntroVideoPlayerView(player: slideshow.player)

            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .strokeBorder(DesignTokens.Color.border.swiftUI, lineWidth: 1)
        }
        .aspectRatio(IntroMedia.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: maxPreviewHeight.isFinite ? maxPreviewHeight : nil)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
    }
}

// MARK: - Media constants

private enum IntroMedia {
    /// Canonical frame from clip 1 (2046×1392). Fixed so layout doesn’t jump between clips.
    static let aspectRatio: CGFloat = 2046.0 / 1392.0
}

// MARK: - Video surface

private struct IntroVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> IntroPlayerNSView {
        IntroPlayerNSView(player: player)
    }

    func updateNSView(_ nsView: IntroPlayerNSView, context: Context) {
        nsView.player = player
    }

    static func dismantleNSView(_ nsView: IntroPlayerNSView, coordinator: ()) {
        nsView.detachPlayer()
    }
}

private final class IntroPlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var heldPlayer: AVPlayer?

    var player: AVPlayer? {
        get { heldPlayer }
        set {
            heldPlayer = newValue
            // Only attach while in a window — attaching during teardown races FigFilePlayer.
            playerLayer.player = window == nil ? nil : newValue
        }
    }

    init(player: AVPlayer) {
        self.heldPlayer = player
        super.init(frame: .zero)
        wantsLayer = true
        // Clip on the AppKit layer — SwiftUI clipShape does not reliably mask AVPlayerLayer.
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = DesignTokens.Radius.lg
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        playerLayer.player = window == nil ? nil : heldPlayer
    }

    func detachPlayer() {
        playerLayer.player = nil
    }

    deinit {
        playerLayer.player = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - In-window modal

/// Dimmed overlay that centers `LibraryIntroView` inside the host window.
struct LibraryIntroModal: View {
    /// When true, dismissing marks `AppSettings.hasSeenLibraryIntro`.
    var markSeenOnDismiss: Bool = true
    var onDismiss: () -> Void

    @State private var stopPlayback: (() -> Void)?

    var body: some View {
        GeometryReader { geo in
            // Soft cap only — preview still fills width and keeps video aspect.
            let maxPreviewHeight = max(120, geo.size.height - 360)

            ZStack {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)

                LibraryIntroView(
                    onContinue: dismiss,
                    onDismiss: dismiss,
                    maxPreviewHeight: maxPreviewHeight,
                    onRegisterStop: { stop in
                        stopPlayback = stop
                    }
                )
                .padding(DesignTokens.Spacing.xl)
                .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
            }
        }
        .transition(.opacity)
        .onExitCommand(perform: dismiss)
    }

    private func dismiss() {
        // Stop AVPlayer while the layer is still in the hierarchy, then tear down.
        stopPlayback?()
        stopPlayback = nil
        if markSeenOnDismiss {
            AppSettings.hasSeenLibraryIntro = true
        }
        onDismiss()
    }
}

extension View {
    /// Presents the Grabbit intro as a modal overlay inside this view’s window.
    func libraryIntroModal(
        isPresented: Binding<Bool>,
        markSeenOnDismiss: Bool = true
    ) -> some View {
        overlay {
            if isPresented.wrappedValue {
                LibraryIntroModal(markSeenOnDismiss: markSeenOnDismiss) {
                    isPresented.wrappedValue = false
                }
            }
        }
    }
}
