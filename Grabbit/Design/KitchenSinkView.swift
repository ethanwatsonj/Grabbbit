//
//  KitchenSinkView.swift
//  Grabbit
//
//  Design-system + component gallery. Opened from Settings → DEBUG.
//

import AppKit
import SwiftUI

#if DEBUG
struct KitchenSinkView: View {
    private enum AppearanceOverride: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    @State private var appearanceOverride: AppearanceOverride = .system
    @State private var selectedSwatch: RecordingBackgroundStyle = .warm
    @State private var selectedPaletteIndex = 0
    @State private var sampleTags: [CaptureTag] = [
        CaptureTag(kind: .project, name: "Grabbit"),
        CaptureTag(kind: .flow, name: "Annotate"),
        CaptureTag(kind: .custom, name: "WIP"),
    ]
    @State private var demoToggle = true
    @State private var demoPicker = "Region"
    @State private var demoAutoTagLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxl) {
                header
                colorsSection
                typographySection
                radiusSection
                spacingSection
                elevationSection
                keyBadgesSection
                chipsSection
                tagBarSection
                backgroundSwatchesSection
                annotationColorsSection
                annotationChromeSection
                controlsSection
                toastSection
                autoTagDemoSection
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.Color.background.swiftUI)
        .preferredColorScheme(appearanceOverride.colorScheme)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Kitchen Sink")
                    .font(.grabbit(.panelTitle))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                Text("Design tokens and reusable UI building blocks.")
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            Picker("Appearance", selection: $appearanceOverride) {
                ForEach(AppearanceOverride.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            .help("Preview light and dark appearance")
        }
    }

    // MARK: - Colors

    private var colorsSection: some View {
        KitchenSinkSection(title: "Colors") {
            Text("Semantics")
                .font(.grabbit(.label))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: DesignTokens.Spacing.sm)], spacing: DesignTokens.Spacing.sm) {
                colorSwatch("Background", DesignTokens.Color.background.swiftUI)
                colorSwatch("Surface", DesignTokens.Color.surface.swiftUI)
                colorSwatch("Elevated", DesignTokens.Color.surfaceElevated.swiftUI)
                colorSwatch("Border", DesignTokens.Color.border.swiftUI)
                colorSwatch("Primary", DesignTokens.Color.primary.swiftUI)
                colorSwatch("On Primary", DesignTokens.Color.textOnPrimary.swiftUI)
                colorSwatch("Panel", DesignTokens.Color.panelSurface.swiftUI)
                colorSwatch("Selection", DesignTokens.Color.listSelectionFill.swiftUI)
                colorSwatch("Region", DesignTokens.Color.regionSelectionAccent.swiftUI)
                colorSwatch("Text Primary", DesignTokens.Color.textPrimary.swiftUI)
                colorSwatch("Text Secondary", DesignTokens.Color.textSecondary.swiftUI)
                colorSwatch("Text Tertiary", DesignTokens.Color.textTertiary.swiftUI)
                colorSwatch("Soft Control", DesignTokens.Color.softControlFill.swiftUI)
                colorSwatch("Soft Hover", DesignTokens.Color.softControlFillHovered.swiftUI)
            }

            Text("Palette primitives · 100 → 1000")
                .font(.grabbit(.label))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .padding(.top, DesignTokens.Spacing.sm)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ForEach(Array(DesignTokens.Palette.all.enumerated()), id: \.offset) { _, scale in
                    paletteScaleRow(scale)
                }
            }

            Text("Annotation palette (solid 600)")
                .font(.grabbit(.label))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .padding(.top, DesignTokens.Spacing.sm)

            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(Array(DesignTokens.Color.annotationPaletteSwiftUI.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(DesignTokens.Color.border.swiftUI, lineWidth: 0.5))
                }
            }

            Text("Recording gradients")
                .font(.grabbit(.label))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .padding(.top, DesignTokens.Spacing.sm)

            HStack(spacing: DesignTokens.Spacing.sm) {
                gradientChip("Warm", DesignTokens.Color.RecordingGradient.warm.swiftUI)
                gradientChip("Cool", DesignTokens.Color.RecordingGradient.cool.swiftUI)
                gradientChip("Midnight", DesignTokens.Color.RecordingGradient.midnight.swiftUI)
            }
        }
    }

    // MARK: - Typography

    private var typographySection: some View {
        KitchenSinkSection(title: "Typography") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                typeRow("Caption", .caption)
                typeRow("Label", .label)
                typeRow("Body", .body)
                typeRow("Body Emphasized", .bodyEmphasized)
                typeRow("Title", .title)
                typeRow("Panel Title", .panelTitle)
            }
        }
    }

    // MARK: - Radius / Spacing / Elevation

    private var radiusSection: some View {
        KitchenSinkSection(title: "Radius") {
            HStack(spacing: DesignTokens.Spacing.lg) {
                radiusSample("sm", DesignTokens.Radius.sm)
                radiusSample("md", DesignTokens.Radius.md)
                radiusSample("lg", DesignTokens.Radius.lg)
            }
        }
    }

    private var spacingSection: some View {
        KitchenSinkSection(title: "Spacing") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                spacingRow("xs", DesignTokens.Spacing.xs)
                spacingRow("sm", DesignTokens.Spacing.sm)
                spacingRow("md", DesignTokens.Spacing.md)
                spacingRow("lg", DesignTokens.Spacing.lg)
                spacingRow("xl", DesignTokens.Spacing.xl)
                spacingRow("xxl", DesignTokens.Spacing.xxl)
            }
        }
    }

    private var elevationSection: some View {
        KitchenSinkSection(title: "Elevation") {
            HStack(spacing: DesignTokens.Spacing.xl) {
                elevationCard("Panel", .panel)
                elevationCard("Panel Raised", .panelRaised)
            }
        }
    }

    // MARK: - Key badges

    private var keyBadgesSection: some View {
        KitchenSinkSection(title: "Key Badges") {
            HStack(spacing: 3) {
                ForEach(["⌘", "⇧", "3"], id: \.self) { key in
                    KeyBadgeView(label: key)
                }
                Text("Grab Screen")
                    .font(.grabbit(.body))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                    .padding(.leading, DesignTokens.Spacing.sm)
            }
        }
    }

    // MARK: - Chips

    private var chipsSection: some View {
        KitchenSinkSection(title: "Meta Chips") {
            HStack(spacing: DesignTokens.Spacing.sm) {
                MetaChipView(label: "Project", value: "Grabbit")
                MetaChipView(label: "Flow", value: "Annotate")
                MetaChipView(label: "Tag", value: "Organized")
            }
        }
    }

    // MARK: - Tag bar

    private var tagBarSection: some View {
        KitchenSinkSection(title: "Capture Tag Bar") {
            CaptureTagBar(
                tags: sampleTags,
                onRemoveTag: { tag in
                    sampleTags.removeAll { $0.id == tag.id }
                },
                onAddTag: { kind, name in
                    sampleTags.append(CaptureTag(kind: kind, name: name))
                }
            )
        }
    }

    // MARK: - Background swatches

    private var backgroundSwatchesSection: some View {
        KitchenSinkSection(title: "Background Style Swatches") {
            BackgroundSwatchRow(
                selected: $selectedSwatch
            )
            .frame(height: 44)
        }
    }

    // MARK: - Annotation colors

    private var annotationColorsSection: some View {
        KitchenSinkSection(title: "Annotation Color Buttons") {
            CircleColorButtonRow(selectedIndex: $selectedPaletteIndex)
                .frame(height: 36)
        }
    }

    // MARK: - Annotation tools

    private var annotationChromeSection: some View {
        KitchenSinkSection(title: "Annotation Tools") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                Text("Action bar")
                    .font(.grabbit(.label))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                AnnotationActionBarReplica()

                Text("Toolbar pill (screenshot tools)")
                    .font(.grabbit(.label))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                ToolbarPillReplica()
            }
            .padding(DesignTokens.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                    .fill(DesignTokens.Color.panelSurface.swiftUI)
            )
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        KitchenSinkSection(title: "Controls") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Toggle("Demo toggle", isOn: $demoToggle)
                    .toggleStyle(.grabbitCheckbox)
                    .font(.grabbit(.body))

                Picker("Capture mode", selection: $demoPicker) {
                    Text("Region").tag("Region")
                    Text("Window").tag("Window")
                    Text("Display").tag("Display")
                }
                .pickerStyle(.segmented)
                .font(.grabbit(.body))

                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button("Secondary") {}
                        .buttonStyle(.grabbit)
                    Button("Prominent") {}
                        .buttonStyle(.grabbitProminent)
                    Button("Compact") {}
                        .buttonStyle(.grabbitCompact)
                    Button {
                    } label: {
                        HStack(spacing: 6) {
                            RabbitIcon(width: 18)
                            Text("Auto-Tag")
                        }
                    }
                    .buttonStyle(.grabbit)
                    Button {
                    } label: {
                        HStack(spacing: 6) {
                            RabbitIcon(width: 18)
                            Text("Auto-Tag")
                        }
                        .opacity(0)
                        .overlay {
                            RabbitHopLoader(size: .compact)
                        }
                    }
                    .buttonStyle(.grabbit)
                    .allowsHitTesting(false)
                    .help("Auto-tagging…")
                }
            }
        }
    }

    // MARK: - Toast

    private var toastSection: some View {
        KitchenSinkSection(title: "Toast") {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Show message toast") {
                    ToastWindow.show(message: "Kitchen sink toast")
                }
                .buttonStyle(.bordered)

                Button("Show action toast") {
                    ToastWindow.show(
                        message: "Capture saved",
                        associatedCaptureID: nil,
                        actionTitle: "Open",
                        anchorScreenRect: nil,
                        hostWindow: nil,
                        onAction: {},
                        onPresented: nil
                    )
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Auto-Tag demo

    private var autoTagDemoSection: some View {
        KitchenSinkSection(title: "Auto-Tag") {
            Button {
                guard !demoAutoTagLoading else { return }
                demoAutoTagLoading = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    demoAutoTagLoading = false
                }
            } label: {
                KitchenSinkAutoTagLabel(isLoading: demoAutoTagLoading)
            }
            .buttonStyle(KitchenSinkAutoTagButtonStyle())
            .help(demoAutoTagLoading ? "Auto-tagging…" : "Auto-Tag")
        }
    }

    // MARK: - Helpers

    private func colorSwatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .fill(color)
                .frame(height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                        .stroke(DesignTokens.Color.border.swiftUI, lineWidth: 0.5)
                )
            Text(name)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                .lineLimit(1)
        }
    }

    private func paletteScaleRow(_ scale: TokenColorScale) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(scale.name)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .frame(width: 72, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(ColorTint.allCases, id: \.self) { tint in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(scale[tint].swiftUI)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .overlay(alignment: .bottom) {
                            if tint == .t600 {
                                Text("600")
                                    .font(DesignTokens.Typography.monoSwiftUI(size: 8))
                                    .foregroundStyle(tint.rawValue >= 600
                                        ? Color.white.opacity(0.9)
                                        : DesignTokens.Color.textPrimary.swiftUI.opacity(0.7))
                                    .padding(.bottom, 2)
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                    .stroke(DesignTokens.Color.border.swiftUI, lineWidth: 0.5)
            )
        }
    }

    private func gradientChip(_ name: String, _ colors: [Color]) -> some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 72, height: 36)
            Text(name)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
        }
    }

    private func typeRow(_ name: String, _ style: DesignTokens.Typography.Style) -> some View {
        let token = style.token
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                Text("\(Self.formatTypeSize(token.size)) · \(token.typefaceLabel)")
                    .font(DesignTokens.Typography.monoSwiftUI(size: DesignTokens.Typography.caption.size))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                    .lineLimit(1)
            }
            .frame(width: 200, alignment: .leading)
            Text("The quick brown fox")
                .font(.grabbit(style))
                .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
        }
    }

    private static func formatTypeSize(_ size: CGFloat) -> String {
        size.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(size)) pt"
            : String(format: "%.1f pt", size)
    }

    private func radiusSample(_ name: String, _ radius: CGFloat) -> some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            RoundedRectangle(cornerRadius: radius)
                .fill(DesignTokens.Color.listSelectionFill.swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(DesignTokens.Color.border.swiftUI, lineWidth: 1)
                )
                .frame(width: 56, height: 40)
            Text("\(name) · \(Int(radius))")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
        }
    }

    private func spacingRow(_ name: String, _ value: CGFloat) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(name)
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                .frame(width: 36, alignment: .leading)
            RoundedRectangle(cornerRadius: 1)
                .fill(DesignTokens.Color.primary.swiftUI)
                .frame(width: value, height: 12)
            Text("\(Int(value)) pt")
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
        }
    }

    private func elevationCard(_ name: String, _ elevation: DesignTokens.Elevation) -> some View {
        ElevationDemoView(elevation: elevation)
            .frame(width: 120, height: 72)
            .overlay(alignment: .bottom) {
                Text(name)
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                    .padding(.bottom, DesignTokens.Spacing.sm)
            }
    }
}

// MARK: - Auto-Tag demo label

/// Bigger kitchen-sink Auto-Tag control: idle rabbit + label, hop loader while running.
private struct KitchenSinkAutoTagLabel: View {
    let isLoading: Bool

    private static let spacing: CGFloat = 10
    private static let idleSize = CGSize(width: 28, height: 28 * 12 / 25)
    private static let loadingSize = RabbitHopLoader.Size.button.pointSize

    var body: some View {
        HStack(spacing: Self.spacing) {
            Color.clear
                .frame(width: Self.idleSize.width, height: Self.idleSize.height)
            Text("Auto-Tag")
                .opacity(isLoading ? 0 : 1)
                .animation(nil, value: isLoading)
        }
        .overlay {
            GeometryReader { geo in
                let rabbitSize = isLoading ? Self.loadingSize : Self.idleSize
                let x = isLoading ? (geo.size.width - rabbitSize.width) / 2 : 0
                let y = (geo.size.height - rabbitSize.height) / 2

                RabbitHopLoader(
                    size: .button,
                    isAnimating: isLoading,
                    pointSizeOverride: rabbitSize
                )
                .offset(x: x, y: y)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: isLoading)
    }
}

/// Enlarged soft secondary chrome for the kitchen-sink Auto-Tag demo.
private struct KitchenSinkAutoTagButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.custom(
                DesignTokens.Typography.postScriptName(for: .regular),
                size: 18
            ))
            .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? DesignTokens.Color.softControlFillHovered.swiftUI
                            : DesignTokens.Color.softControlFill.swiftUI
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .strokeBorder(DesignTokens.Color.softControlBorder.swiftUI, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
            .pointerStyle(.link)
    }
}

// MARK: - Section chrome

private struct KitchenSinkSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text(title.uppercased())
                .font(.grabbit(.caption))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            Divider()
            content
        }
    }
}

// MARK: - SwiftUI chip / badge replicas

private struct KeyBadgeView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(DesignTokens.Typography.monoSwiftUI(size: DesignTokens.Typography.label.size))
            .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
            .frame(width: 24, height: 22)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                    .fill(DesignTokens.Color.surface.swiftUI)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                    .stroke(DesignTokens.Color.border.swiftUI, lineWidth: 0.5)
            )
    }
}

private struct MetaChipView: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
            Text(value)
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
        }
        .font(.grabbit(.caption))
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .fill(DesignTokens.Color.listSelectionFill.swiftUI)
        )
    }
}

// MARK: - AppKit bridges

private struct ElevationDemoView: NSViewRepresentable {
    let elevation: DesignTokens.Elevation
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = DesignTokens.Radius.lg
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let layer = nsView.layer else { return }
        // Resolve against the current scheme so CALayer fills track light/dark.
        _ = colorScheme
        layer.backgroundColor = DesignTokens.Color.panelSurface.ns.cgColor
        elevation.apply(
            to: layer,
            roundedPathIn: nsView.bounds,
            cornerRadius: DesignTokens.Radius.lg
        )
    }
}

private struct BackgroundSwatchRow: NSViewRepresentable {
    @Binding var selected: RecordingBackgroundStyle

    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = DesignTokens.Spacing.sm
        stack.alignment = .centerY

        let styles: [RecordingBackgroundStyle] = [.none, .warm, .cool, .midnight]
        for style in styles {
            let swatch = BackgroundStyleSwatch(kind: .preset(style))
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 44).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 32).isActive = true
            swatch.target = context.coordinator
            swatch.action = #selector(Coordinator.swatchTapped(_:))
            swatch.identifier = NSUserInterfaceItemIdentifier(styleLabel(style))
            stack.addArrangedSubview(swatch)
            context.coordinator.swatches[styleLabel(style)] = (swatch, style)
        }

        let custom = BackgroundStyleSwatch(kind: .custom)
        custom.translatesAutoresizingMaskIntoConstraints = false
        custom.widthAnchor.constraint(equalToConstant: 44).isActive = true
        custom.heightAnchor.constraint(equalToConstant: 32).isActive = true
        stack.addArrangedSubview(custom)

        context.coordinator.refreshSelection(selected)
        return stack
    }

    func updateNSView(_ nsView: NSStackView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refreshSelection(selected)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func styleLabel(_ style: RecordingBackgroundStyle) -> String {
        switch style {
        case .none: return "none"
        case .warm: return "warm"
        case .cool: return "cool"
        case .midnight: return "midnight"
        case .custom: return "custom"
        }
    }

    final class Coordinator: NSObject {
        var parent: BackgroundSwatchRow
        var swatches: [String: (BackgroundStyleSwatch, RecordingBackgroundStyle)] = [:]

        init(parent: BackgroundSwatchRow) {
            self.parent = parent
        }

        func refreshSelection(_ selected: RecordingBackgroundStyle) {
            for (_, pair) in swatches {
                pair.0.isStyleSelected = pair.1 == selected
            }
        }

        @objc func swatchTapped(_ sender: BackgroundStyleSwatch) {
            guard case .preset(let style) = sender.kind else { return }
            parent.selected = style
            refreshSelection(style)
        }
    }
}

private struct CircleColorButtonRow: NSViewRepresentable {
    @Binding var selectedIndex: Int

    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = DesignTokens.Spacing.sm
        stack.alignment = .centerY

        for (index, color) in DesignTokens.Color.annotationPaletteNS.enumerated() {
            let button = CircleColorButton(color: color, visualInset: 4)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.tag = index
            button.target = context.coordinator
            button.action = #selector(Coordinator.tapped(_:))
            button.isColorSelected = index == selectedIndex
            stack.addArrangedSubview(button)
            context.coordinator.buttons.append(button)
        }

        let custom = CircleColorButton(color: .white, isCustomSlot: true, visualInset: 4)
        custom.translatesAutoresizingMaskIntoConstraints = false
        custom.widthAnchor.constraint(equalToConstant: 28).isActive = true
        custom.heightAnchor.constraint(equalToConstant: 28).isActive = true
        stack.addArrangedSubview(custom)

        return stack
    }

    func updateNSView(_ nsView: NSStackView, context: Context) {
        context.coordinator.parent = self
        for button in context.coordinator.buttons {
            button.isColorSelected = button.tag == selectedIndex
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: CircleColorButtonRow
        var buttons: [CircleColorButton] = []

        init(parent: CircleColorButtonRow) {
            self.parent = parent
        }

        @objc func tapped(_ sender: CircleColorButton) {
            parent.selectedIndex = sender.tag
            for button in buttons {
                button.isColorSelected = button.tag == sender.tag
            }
        }
    }
}

/// Visual stand-in for `AnnotationActionBarView`.
/// The real AppKit bar mutates `frame.size` inside `layout()`, which fights
/// SwiftUI Auto Layout and aborts the window with an infinite layout loop.
private struct AnnotationActionBarReplica: View {
    private let symbols = ["square.and.arrow.down", "doc.on.doc", "ellipsis"]

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(symbols, id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                    .frame(width: 22, height: 22)
            }
        }
    }
}

/// Visual stand-in for `ToolbarPillView`.
/// The real pill calls `setFrameSize` during accessory layout and cannot be
/// hosted inside SwiftUI without triggering AppKit's layout-pass abort.
private struct ToolbarPillReplica: View {
    @State private var selected = AnnotationTool.select

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.screenshotTools, id: \.self) { tool in
                Button {
                    selected = tool
                } label: {
                    Image(systemName: tool.sfSymbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                                .fill(selected == tool
                                      ? DesignTokens.Color.listSelectionFill.swiftUI
                                      : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(tool.displayName)
            }

            Rectangle()
                .fill(DesignTokens.Color.borderOnPanel.swiftUI)
                .frame(width: 1, height: 20)
                .padding(.horizontal, 4)

            Circle()
                .fill(DesignTokens.Color.annotationPaletteSwiftUI[0])
                .frame(width: 20, height: 20)
                .padding(6)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .fill(DesignTokens.Color.panelSurface.swiftUI)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 1)
        )
    }
}
#endif
