//
//  RabbitHopLoader.swift
//  Grabbit
//
//  Five filled-silhouette hop frames, traced from the cross-stitch sheet
//  right→left (furthest right = crouch, furthest left = land) into solid
//  template pixels in the same style as MenuBarIcon. Used wherever Auto Organize
//  is loading.
//

import SwiftUI

/// Static mid-leap rabbit (menu-bar glyph) for Auto Organize button labels.
struct RabbitIcon: View {
    var width: CGFloat = 18

    private static let aspect: CGFloat = 30.0 / 14.0

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .interpolation(.none)
            .resizable()
            .aspectRatio(Self.aspect, contentMode: .fit)
            .frame(width: width, height: width / Self.aspect)
    }
}

/// Loops hop frames in place, sheet order right→left: crouch → launch → mid → descend → land.
/// When `isAnimating` is false, the same view shows the static mid-leap glyph (no view swap/fade).
struct RabbitHopLoader: View {
    enum Size {
        /// Larger stand-alone / kitchen-sink demo size.
        case button
        /// Fits inside Auto Organize button chrome and row trailing indicators.
        case compact

        var pointSize: CGSize {
            // Source assets are 32×28 cells (1x). Keep aspect; scale to UI.
            switch self {
            case .button:
                return CGSize(width: 28, height: 24)
            case .compact:
                return CGSize(width: 22, height: 19)
            }
        }
    }

    var size: Size = .button
    /// When false, shows `MenuBarIcon` in the same image pipeline (idle Auto Organize label).
    var isAnimating: Bool = true
    /// Optional size override for animating between idle icon and loader bounds.
    var pointSizeOverride: CGSize? = nil

    /// Base tick for weighted hop timing (seconds).
    private static let tick: TimeInterval = 0.10

    /// Asset indices follow the sheet left→right; playback is right→left.
    private static let frameNames = [
        "RabbitHop4", // crouch / coil (furthest right on sheet)
        "RabbitHop3", // launch
        "RabbitHop2", // mid-air hang
        "RabbitHop1", // descend
        "RabbitHop0", // land / settle (furthest left on sheet)
    ]

    /// Light hang at apex; keep ground frames short so the loop doesn’t stall.
    private static let frameWeights: [Double] = [
        1.2, // crouch
        1.0, // launch
        1.4, // mid
        1.0, // descend
        1.2, // land
    ]

    private var resolvedSize: CGSize {
        pointSizeOverride ?? size.pointSize
    }

    var body: some View {
        let pointSize = resolvedSize
        TimelineView(.animation(minimumInterval: Self.tick, paused: !isAnimating)) { context in
            let name = isAnimating
                ? Self.frameNames[hopFrameIndex(at: context.date)]
                : "MenuBarIcon"
            Image(name)
                .renderingMode(.template)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: pointSize.width, height: pointSize.height)
                // Asset name changes must not crossfade when sliding idle → hop.
                .contentTransition(.identity)
        }
        .frame(width: pointSize.width, height: pointSize.height)
        .accessibilityLabel(isAnimating ? "Auto-organizing" : "Auto Organize")
    }

    private func hopFrameIndex(at date: Date) -> Int {
        let weights = Self.frameWeights
        let total = weights.reduce(0, +)
        let cycle = date.timeIntervalSinceReferenceDate / Self.tick
        var unit = cycle.truncatingRemainder(dividingBy: total)
        if unit < 0 { unit += total }
        var acc = 0.0
        for (i, w) in weights.enumerated() {
            acc += w
            if unit < acc { return i }
        }
        return 0
    }
}
