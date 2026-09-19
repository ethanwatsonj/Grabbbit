//
//  DesignTokens.swift
//  Grabbit
//
//  Single source of truth for color, spacing, radius, type, and elevation.
//  Colors: `Color` = semantics (roles); `Palette` = primitives (10-tint scales).
//  Neutral replaces gray. Prefer `Color.*` in UI; reach into `Palette` only
//  when defining a new semantic or a one-off tint that isn’t named yet.
//  Floating panels (Capture Bar, toast, annotation chrome) lean Figma: small
//  radii, soft directional shadows, primary blue used sparingly.
//  Content surfaces (Settings, Capture Library) lean Notion: neutral fills,
//  generous whitespace, restrained type, primary only on the main action.
//

import AppKit
import CoreImage
import CoreText
import SwiftUI

// MARK: - Dual-platform tokens

/// A color available as both `NSColor` (AppKit) and `Color` (SwiftUI).
struct TokenColor {
    let ns: NSColor

    var swiftUI: Color { Color(nsColor: ns) }
    var cg: CGColor { ns.cgColor }

    /// Calibrated sRGB from a 24-bit hex (e.g. `0xE8328C`).
    init(hex: UInt32, alpha: CGFloat = 1) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(ns: NSColor(calibratedRed: r, green: g, blue: b, alpha: alpha))
    }

    init(ns: NSColor) {
        self.ns = ns
    }
}

/// Step on a 10-tint scale (Vercel / Linear style: 100 lightest → 1000 darkest).
enum ColorTint: Int, CaseIterable, Comparable, Hashable {
    case t100 = 100
    case t200 = 200
    case t300 = 300
    case t400 = 400
    case t500 = 500
    case t600 = 600
    case t700 = 700
    case t800 = 800
    case t900 = 900
    case t1000 = 1000

    /// Zero-based index into a `TokenColorScale`.
    var index: Int { (rawValue / 100) - 1 }

    var label: String { "\(rawValue)" }

    static func < (lhs: ColorTint, rhs: ColorTint) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Fixed 10-step tint ramp for one hue family.
///
/// Intended roles (same convention as Vercel / Linear):
/// - **100–200** — tinted backgrounds, subtle fills
/// - **300–400** — hover / active soft fills, muted borders
/// - **500** — stronger borders, focus rings
/// - **600** — solid / brand (`solid`)
/// - **700–800** — hovered / pressed solids
/// - **900–1000** — high-contrast text and icons on light surfaces
struct TokenColorScale {
    let name: String
    private let colors: [TokenColor]

    init(name: String, _ hexes: [UInt32]) {
        precondition(hexes.count == ColorTint.allCases.count, "Color scales require exactly 10 tints")
        self.name = name
        self.colors = hexes.map { TokenColor(hex: $0) }
    }

    subscript(_ tint: ColorTint) -> TokenColor {
        colors[tint.index]
    }

    /// Brand / solid stop — always tint 600.
    var solid: TokenColor { self[.t600] }

    var all: [(tint: ColorTint, color: TokenColor)] {
        ColorTint.allCases.map { ($0, self[$0]) }
    }

    var swiftUI: [SwiftUI.Color] { colors.map(\.swiftUI) }
    var ns: [NSColor] { colors.map(\.ns) }
}

/// A multi-stop gradient available as `NSColor`, SwiftUI `Color`, and `CIColor`.
struct TokenGradient {
    let ns: [NSColor]

    var swiftUI: [Color] { ns.map { Color(nsColor: $0) } }
    var ci: [CIColor] { ns.map { CIColor(color: $0)! } }
}

/// A type-scale step available as both `NSFont` and SwiftUI `Font`.
/// Sizes are in Apple points (pt) — AppKit/SwiftUI’s logical unit, not CSS px.
struct TokenFont {
    let size: CGFloat
    let weight: NSFont.Weight

    var ns: NSFont { DesignTokens.Typography.font(size: size, weight: weight) }

    var swiftUI: Font {
        Font.custom(DesignTokens.Typography.postScriptName(for: weight), size: size)
    }

    /// Display name for kitchen sink / debugging (e.g. "Geist Medium").
    var typefaceLabel: String {
        "Geist \(DesignTokens.Typography.weightName(weight))"
    }
}

// MARK: - DesignTokens

enum DesignTokens {

    // MARK: Radius

    /// Three radii only — map every `cornerRadius` to one of these.
    enum Radius {
        /// Small chips, handles, swatches (replaces scattered 4 / 5 / 6).
        static let sm: CGFloat = 4
        /// Buttons, hover states, inline controls.
        static let md: CGFloat = 8
        /// Floating panel containers (toast, Capture Bar, Ship It, annotation panels).
        static let lg: CGFloat = 12
    }

    // MARK: Spacing

    /// 4pt grid.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Color (semantics)

    /// Role-based colors. Each maps to a `Palette` tint (or alpha over one).
    enum Color {
        // MARK: Surfaces

        /// Content window fill (View All, Settings).
        static let background = dynamicNeutral(.t200, .t1000)
        /// Nested / control surface.
        static let surface = dynamicNeutral(.t100, .t900)
        /// Raised content surface (cards, fields, dropdown panels).
        static let surfaceElevated = dynamicNeutral(.t100, .t1000)
        /// Floating / elevated panel surface (toast, annotation chrome).
        static let panelSurface = dynamicNeutral(.t100, .t900)
        /// Solid dark toast chrome (Capture Bar hover labels).
        static let toastDarkFill = TokenColor(ns: Palette.neutral[.t900].ns)
        /// Selected list / nav / chip fill.
        static let listSelectionFill = dynamicNeutral(.t300, .t900)
        /// Soft bordered control fill (Group by, Auto Organize, project dropdowns).
        static let softControlFill = dynamicNeutral(.t100, .t1000)
        /// Hover / pressed variant of `softControlFill`.
        static let softControlFillHovered = dynamicNeutral(.t300, .t900)
        /// Hover fill on dark HUD chrome (Capture Bar mode buttons).
        static let panelHoverFill = TokenColor(ns: Palette.neutral[.t100].ns.withAlphaComponent(0.14))
        /// Active fill on dark HUD chrome.
        static let panelActiveFill = TokenColor(ns: Palette.neutral[.t100].ns.withAlphaComponent(0.18))
        /// Sidebar footer status chip (Auto Organize activity banner) — solid neutral on `background`.
        static let sidebarBannerFill = dynamicNeutral(.t100, .t900)
        /// Quiet light-mode elevation for small footer chips; clear in dark (avoids muddy lift).
        static let subtleElevationShadow = dynamicNeutralAlpha(
            light: NSColor.black.withAlphaComponent(0.06),
            dark: NSColor.black.withAlphaComponent(0)
        )

        // MARK: Borders

        static let border = dynamicNeutral(.t300, .t700)
        /// Soft control outline (Group by, Auto Organize, project dropdowns) — one step darker than `border`.
        static let softControlBorder = dynamicNeutral(.t400, .t900)
        /// Dividers on `panelSurface`.
        static let borderOnPanel = dynamicNeutralAlpha(
            light: Palette.neutral[.t1000].ns.withAlphaComponent(0.12),
            dark: Palette.neutral[.t100].ns.withAlphaComponent(0.12)
        )
        /// Dividers on `primary` surfaces.
        static let borderOnPrimary = TokenColor(ns: Palette.neutral[.t100].ns.withAlphaComponent(0.18))
        /// Overlay scrollbar thumb (Capture Library sidebar) — soft, low-contrast knob.
        static let scrollbarThumb = dynamicNeutralAlpha(
            light: Palette.neutral[.t1000].ns.withAlphaComponent(0.18),
            dark: Palette.neutral[.t100].ns.withAlphaComponent(0.22)
        )

        // MARK: Text

        static let textPrimary = dynamicNeutral(.t1000, .t200)
        static let textSecondary = dynamicNeutral(.t600, .t500)
        static let textTertiary = dynamicNeutral(.t500, .t600)
        /// Capture Library sidebar labels / icons — one step darker than body text in dark mode.
        static let sidebarTextPrimary = dynamicNeutral(.t1000, .t300)
        static let sidebarTextSecondary = dynamicNeutral(.t600, .t600)
        /// Icons and labels on `primary` surfaces.
        static let textOnPrimary = TokenColor(ns: Palette.neutral[.t100].ns.withAlphaComponent(0.92))

        // MARK: Brand / accents

        /// Brand primary — blue 700. Buttons, focus, interactive emphasis.
        static let primary = Palette.blue[.t700]
        /// Region capture overlay border and handles.
        static let regionSelectionAccent = TokenColor(
            ns: Palette.neutral[.t500].ns.withAlphaComponent(0.55)
        )

        // MARK: Recording gradients

        /// Preset recording-background gradients. Single source for Ship It + renderer.
        enum RecordingGradient {
            static let warm = TokenGradient(ns: [
                Palette.tangerine[.t400].ns,
                Palette.flamingo[.t600].ns,
            ])
            static let cool = TokenGradient(ns: [
                Palette.peacock[.t400].ns,
                Palette.blue[.t700].ns,
            ])
            static let midnight = TokenGradient(ns: [
                Palette.blue[.t900].ns,
                Palette.neutral[.t1000].ns,
            ])

            static func colors(for style: RecordingBackgroundStyle) -> TokenGradient? {
                switch style {
                case .warm:     return warm
                case .cool:     return cool
                case .midnight: return midnight
                case .none, .custom: return nil
                }
            }
        }

        /// Annotation stroke / fill palette — each color’s solid (600) stop.
        static let annotationPalette: [TokenColor] = Palette.annotation.map(\.solid)

        static var annotationPaletteNS: [NSColor] { annotationPalette.map(\.ns) }
        static var annotationPaletteSwiftUI: [SwiftUI.Color] { annotationPalette.map(\.swiftUI) }

        // MARK: Palette helpers

        /// Appearance-aware pick from the neutral scale.
        static func dynamicNeutral(_ light: ColorTint, _ dark: ColorTint) -> TokenColor {
            TokenColor(ns: NSColor(name: nil, dynamicProvider: { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return Palette.neutral[isDark ? dark : light].ns
            }))
        }

        private static func dynamicNeutralAlpha(light: NSColor, dark: NSColor) -> TokenColor {
            TokenColor(ns: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }))
        }
    }

    // MARK: Palette (primitives)

    /// Primitive color ramps — 100 (lightest) → 1000 (darkest).
    /// Prefer defining a semantic in `Color` over using these directly in UI.
    enum Palette {
        static let neutral = TokenColorScale(name: "Neutral", [
            0xFAFAFA, 0xF5F5F5, 0xEBEBEB, 0xE0E0E0, 0xA1A1A1,
            0x737373, 0x525252, 0x424242, 0x2A2A2A, 0x171717,
        ])

        /// Brand primary / blueberry blue — solid `#5080FF`; interactive primary uses tint 700.
        static let blue = TokenColorScale(name: "Blue", [
            0xEEF3FF, 0xD9E4FF, 0xB8CCFF, 0x8FABFF, 0x6E95FF,
            0x5080FF, 0x3B66E0, 0x2C4FB5, 0x1E3785, 0x122152,
        ])

        static let tomato = TokenColorScale(name: "Tomato", [
            0xFFF1F0, 0xFFD9D7, 0xFFB3AF, 0xFF8A84, 0xFF655E,
            0xFF4A45, 0xE02F2A, 0xB52420, 0x851A17, 0x54110F,
        ])

        static let tangerine = TokenColorScale(name: "Tangerine", [
            0xFFF4EB, 0xFFE4CC, 0xFFC999, 0xFFAF66, 0xFF9A4D,
            0xFF8A38, 0xE06E1F, 0xB55616, 0x853E10, 0x54280A,
        ])

        static let gold = TokenColorScale(name: "Gold", [
            0xFFF8E6, 0xFFECB8, 0xFFDC7A, 0xFFCB3D, 0xFABA14,
            0xF0A800, 0xCC8F00, 0xA37200, 0x755200, 0x473200,
        ])

        static let sage = TokenColorScale(name: "Sage", [
            0xEAFBF2, 0xC9F5DE, 0x93E8BD, 0x5CD99A, 0x3DD188,
            0x2EC87A, 0x24A664, 0x1B824E, 0x135C38, 0x0C3A23,
        ])

        static let peacock = TokenColorScale(name: "Peacock", [
            0xE6F9FC, 0xB8F0F8, 0x70E0EF, 0x33CEED, 0x12C2E0,
            0x00B4D4, 0x0096B0, 0x00778C, 0x005566, 0x003540,
        ])

        static let grape = TokenColorScale(name: "Grape", [
            0xF5F0FE, 0xE6DAFC, 0xCDB4F9, 0xB48FF5, 0xA878F2,
            0x9D66F0, 0x824ED4, 0x663AAE, 0x4A2880, 0x2E1852,
        ])

        static let flamingo = TokenColorScale(name: "Flamingo", [
            0xFFF0F5, 0xFFD6E4, 0xFFADD0, 0xFF7AB0, 0xF8629A,
            0xF04E88, 0xD1366E, 0xA82856, 0x7A1D3E, 0x4C1226,
        ])

        /// Annotation picker order (solid stops feed `Color.annotationPalette`).
        static let annotation: [TokenColorScale] = [
            tomato, tangerine, gold, sage, peacock, blue, grape, flamingo,
        ]

        /// All named ramps for kitchen sink / tooling.
        static let all: [TokenColorScale] = [
            neutral, blue, tomato, tangerine, gold, sage, peacock, grape, flamingo,
        ]
    }

    // MARK: Typography
    // Named `Typography` rather than `Type` — `DesignTokens.Type` is the metatype in Swift.
    //
    // Units: sizes and spacing use Apple points (pt). On a 1× display 1 pt = 1 px;
    // on Retina 1 pt = 2 device pixels. There is no separate px scale in AppKit —
    // pass these numbers straight through (14 pt body ≈ 14 CSS px at 100% / 1×).

    enum Typography {
        static let familyName = "Geist"
        static let monoFamilyName = "Geist Mono"

        static let caption = TokenFont(size: 13, weight: .regular)
        static let label = TokenFont(size: 14, weight: .medium)
        static let body = TokenFont(size: 14, weight: .medium)
        static let bodyEmphasized = TokenFont(size: 14, weight: .semibold)
        static let title = TokenFont(size: 14, weight: .semibold)
        /// Window / heading-bar app name (View All, etc.).
        static let windowTitle = TokenFont(size: 12, weight: .semibold)
        static let panelTitle = TokenFont(size: 18, weight: .semibold)

        enum Style {
            case caption, label, body, bodyEmphasized, title, windowTitle, panelTitle

            var token: TokenFont {
                switch self {
                case .caption:         return Typography.caption
                case .label:           return Typography.label
                case .body:            return Typography.body
                case .bodyEmphasized:  return Typography.bodyEmphasized
                case .title:           return Typography.title
                case .windowTitle:     return Typography.windowTitle
                case .panelTitle:      return Typography.panelTitle
                }
            }
        }

        static func registerBundledFonts() {
            let fileNames = [
                "Geist-Regular", "Geist-Medium", "Geist-SemiBold", "Geist-Bold",
                "GeistMono-Regular", "GeistMono-Medium",
            ]
            for name in fileNames {
                guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }

        static func postScriptName(for weight: NSFont.Weight) -> String {
            switch weight {
            case .ultraLight, .thin, .light, .regular:
                return "Geist-Regular"
            case .medium:
                return "Geist-Medium"
            case .semibold:
                return "Geist-SemiBold"
            case .bold, .heavy, .black:
                return "Geist-Bold"
            default:
                return weight.rawValue < NSFont.Weight.medium.rawValue
                    ? "Geist-Regular"
                    : weight.rawValue < NSFont.Weight.semibold.rawValue
                        ? "Geist-Medium"
                        : weight.rawValue < NSFont.Weight.bold.rawValue
                            ? "Geist-SemiBold"
                            : "Geist-Bold"
            }
        }

        static func monoPostScriptName(for weight: NSFont.Weight) -> String {
            weight.rawValue >= NSFont.Weight.medium.rawValue
                ? "GeistMono-Medium"
                : "GeistMono-Regular"
        }

        static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
            NSFont(name: postScriptName(for: weight), size: size)
                ?? NSFont.systemFont(ofSize: size, weight: weight)
        }

        static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            NSFont(name: monoPostScriptName(for: weight), size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }

        static func monoSwiftUI(size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
            Font.custom(monoPostScriptName(for: weight), size: size)
        }

        static func weightName(_ weight: NSFont.Weight) -> String {
            switch weight {
            case .ultraLight: return "Ultralight"
            case .thin:       return "Thin"
            case .light:      return "Light"
            case .regular:    return "Regular"
            case .medium:     return "Medium"
            case .semibold:   return "Semibold"
            case .bold:       return "Bold"
            case .heavy:      return "Heavy"
            case .black:      return "Black"
            default:          return "Regular"
            }
        }
    }

    // MARK: Elevation

    /// Soft directional shadows for floating panels (Figma-style lift).
    enum Elevation {
        /// Resting floating chrome (annotation toolbar, compact panels).
        case panel
        /// Stronger lift while dragging or for preview cards.
        case panelRaised
        /// Quiet light-mode chip lift (sidebar AO banner). Pair with `Color.subtleElevationShadow` in SwiftUI.
        case subtle

        var color: NSColor { .black }

        var opacity: Float {
            switch self {
            case .panel:       return 0.18
            case .panelRaised: return 0.45
            case .subtle:      return 0.06
            }
        }

        var radius: CGFloat {
            switch self {
            case .panel:       return 6
            case .panelRaised: return 10
            case .subtle:      return 2
            }
        }

        /// AppKit layer coords: negative Y casts shadow downward.
        var offset: CGSize {
            switch self {
            case .panel:       return CGSize(width: 0, height: -1)
            case .panelRaised: return CGSize(width: 0, height: -2)
            case .subtle:      return CGSize(width: 0, height: -1)
            }
        }

        /// SwiftUI `.shadow` Y offset (positive casts downward).
        var swiftUIYOffset: CGFloat {
            -offset.height
        }

        func apply(to layer: CALayer, roundedPathIn bounds: CGRect? = nil, cornerRadius: CGFloat = 0) {
            layer.shadowColor = color.cgColor
            layer.shadowOpacity = opacity
            layer.shadowRadius = radius
            layer.shadowOffset = offset
            if let bounds {
                layer.shadowPath = CGPath(
                    roundedRect: bounds,
                    cornerWidth: cornerRadius,
                    cornerHeight: cornerRadius,
                    transform: nil
                )
            } else {
                layer.shadowPath = nil
            }
        }
    }
}

// MARK: - Font helpers

extension Font {
    /// SwiftUI type scale — e.g. `.font(.grabbit(.body))`.
    static func grabbit(_ style: DesignTokens.Typography.Style) -> Font {
        style.token.swiftUI
    }
}

extension NSFont {
    /// AppKit type scale — e.g. `NSFont.grabbit(.body)`.
    static func grabbit(_ style: DesignTokens.Typography.Style) -> NSFont {
        style.token.ns
    }
}

// MARK: - Buttons

/// Custom content-window button — Geist type, token colors, no AppKit chrome.
/// Compact Vercel-like sizing: 14 pt, tight padding. Secondary matches soft
/// dropdown captions (regular); prominent stays medium.
struct GrabbitButtonStyle: ButtonStyle {
    enum Kind {
        /// Filled primary action (Confirm, default).
        case prominent
        /// Outlined / soft secondary action (Cancel, Reject, Auto Organize).
        case secondary
    }

    enum Size {
        case regular
        case compact
    }

    var kind: Kind = .secondary
    var size: Size = .regular

    @Environment(\.isEnabled) private var isEnabled

    private var labelFont: Font {
        Font.custom(
            DesignTokens.Typography.postScriptName(
                for: kind == .prominent ? .medium : .regular
            ),
            size: 14
        )
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(labelFont)
            .foregroundStyle(foreground)
            // Match 14pt Geist text glyph height so icon-only labels
            // (e.g. Auto Organize accept/reject) share the same control height.
            .frame(minHeight: 17)
            .padding(.horizontal, size == .compact ? 8 : 10)
            .padding(.vertical, size == .compact ? 2 : 4)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(backgroundFill(isPressed: configuration.isPressed))
            }
            .overlay { borderOverlay }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
            .pointerStyle(.link)
    }

    private var foreground: Color {
        switch kind {
        case .prominent: return DesignTokens.Color.textOnPrimary.swiftUI
        case .secondary: return DesignTokens.Color.textPrimary.swiftUI
        }
    }

    private func backgroundFill(isPressed: Bool) -> Color {
        switch kind {
        case .prominent:
            DesignTokens.Color.primary.swiftUI.opacity(isPressed ? 0.82 : 1.0)
        case .secondary:
            isPressed
                ? DesignTokens.Color.softControlFillHovered.swiftUI
                : DesignTokens.Color.softControlFill.swiftUI
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if kind == .secondary {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Color.softControlBorder.swiftUI, lineWidth: 1)
        }
    }
}

extension ButtonStyle where Self == GrabbitButtonStyle {
    static var grabbit: GrabbitButtonStyle { GrabbitButtonStyle() }
    static var grabbitProminent: GrabbitButtonStyle { GrabbitButtonStyle(kind: .prominent) }
    static var grabbitCompact: GrabbitButtonStyle { GrabbitButtonStyle(size: .compact) }
}

// MARK: - Checkbox

/// Bordered checkbox — primary fill when on; soft control border when off.
struct GrabbitCheckboxToggleStyle: ToggleStyle {
    private let boxSize: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                checkbox(isOn: configuration.isOn)
                configuration.label
            }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    private func checkbox(isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
            .fill(isOn ? DesignTokens.Color.primary.swiftUI : DesignTokens.Color.softControlFill.swiftUI)
            .frame(width: boxSize, height: boxSize)
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .strokeBorder(
                        isOn
                            ? DesignTokens.Color.primary.swiftUI
                            : DesignTokens.Color.softControlBorder.swiftUI,
                        lineWidth: 1
                    )
            }
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DesignTokens.Color.textOnPrimary.swiftUI)
                }
            }
    }
}

extension ToggleStyle where Self == GrabbitCheckboxToggleStyle {
    static var grabbitCheckbox: GrabbitCheckboxToggleStyle { GrabbitCheckboxToggleStyle() }
}
