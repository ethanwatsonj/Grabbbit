//
//  SoftDropdownMenu.swift
//  Grabbit
//
//  Custom dropdown panel (rounded, bordered, soft shadow, inset hover rows)
//  used instead of the system Menu / NSMenu for soft controls.
//

import AppKit
import SwiftUI

// MARK: - Dismiss

private struct SoftDropdownDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var softDropdownDismiss: (() -> Void)? {
        get { self[SoftDropdownDismissKey.self] }
        set { self[SoftDropdownDismissKey.self] = newValue }
    }
}

// MARK: - Panel chrome

/// Transparent inset so layered SwiftUI shadows aren't clipped by the NSPanel.
/// Sized for the ambient layer (radius 28 + y 14). Kept outside `SoftDropdownPanel`
/// because generic types can't hold static stored properties.
enum SoftDropdownPanelMetrics {
    static let shadowBleed: CGFloat = 44
}

struct SoftDropdownPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 180, maxWidth: 280)
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .fill(DesignTokens.Color.surfaceElevated.swiftUI)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .strokeBorder(DesignTokens.Color.border.swiftUI, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 28, x: 0, y: 14)
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        .padding(SoftDropdownPanelMetrics.shadowBleed)
    }
}

struct SoftDropdownDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignTokens.Color.border.swiftUI)
            .frame(height: 1)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
    }
}

struct SoftDropdownRow: View {
    let title: String
    var systemImage: String? = nil
    var isSelected: Bool = false
    var showsChevron: Bool = false
    var shortcut: String? = nil
    /// When false, the floating menu stays open (multi-select toggles).
    var dismissesMenu: Bool = true
    let action: () -> Void

    @Environment(\.softDropdownDismiss) private var dismiss
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
            if dismissesMenu {
                dismiss?()
            }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if isSelected {
                        Image(systemName: "checkmark")
                    } else if let systemImage {
                        Image(systemName: systemImage)
                    } else {
                        Color.clear
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                .frame(width: 16, height: 16)

                Text(title)
                    .font(.grabbit(.caption))
                    .foregroundStyle(DesignTokens.Color.textPrimary.swiftUI)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let shortcut {
                    Text(shortcut)
                        .font(.grabbit(.caption))
                        .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                }

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(
                        isHovered
                            ? DesignTokens.Color.softControlFillHovered.swiftUI
                            : Color.clear
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            // Floating NSPanel menus don't always honor SwiftUI pointerStyle.
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            if isHovered {
                NSCursor.arrow.set()
            }
        }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .pointerStyle(.link)
    }
}

// MARK: - Anchor + floating panel

/// Horizontal attachment of the floating menu relative to its anchor control.
enum SoftDropdownHorizontalAlignment {
    /// Left edges align; menu opens down and grows to the right.
    case leading
    /// Right edges align; menu opens down and grows to the left.
    case trailing
}

/// Button that presents `menuContent` in a borderless floating panel styled like SoftDropdownPanel.
struct SoftDropdownAnchor<Label: View, MenuContent: View>: View {
    @Binding var isPresented: Bool
    var horizontalAlignment: SoftDropdownHorizontalAlignment = .trailing
    @ViewBuilder var label: () -> Label
    @ViewBuilder var menuContent: () -> MenuContent

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .background {
            SoftDropdownPanelBridge(
                isPresented: $isPresented,
                horizontalAlignment: horizontalAlignment
            ) {
                menuContent()
            }
        }
    }
}

// MARK: - AppKit bridge

private struct SoftDropdownPanelBridge<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var horizontalAlignment: SoftDropdownHorizontalAlignment
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, horizontalAlignment: horizontalAlignment)
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.presentedBinding = $isPresented
        context.coordinator.horizontalAlignment = horizontalAlignment
        context.coordinator.anchorView = nsView
        let dismiss: () -> Void = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            coordinator.setPresented(false)
        }
        context.coordinator.rootContent = AnyView(
            SoftDropdownPanel {
                content()
            }
            .environment(\.softDropdownDismiss, dismiss)
        )
        if isPresented {
            context.coordinator.showIfNeeded()
        } else {
            context.coordinator.dismiss()
        }
    }

    final class AnchorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                coordinator?.dismiss()
            }
        }
    }

    final class Coordinator {
        var presentedBinding: Binding<Bool>
        var horizontalAlignment: SoftDropdownHorizontalAlignment
        weak var anchorView: NSView?
        var rootContent: AnyView = AnyView(EmptyView())

        private var panel: NSPanel?
        private var hostingView: NSHostingView<AnyView>?
        private var localMonitor: Any?
        private var globalMonitor: Any?
        private var lastPresentedSize: NSSize = .zero
        /// Coalesces deferred measure/present work off the SwiftUI update/layout pass.
        private var pendingPresent = false

        init(
            isPresented: Binding<Bool>,
            horizontalAlignment: SoftDropdownHorizontalAlignment
        ) {
            presentedBinding = isPresented
            self.horizontalAlignment = horizontalAlignment
        }

        func setPresented(_ value: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.presentedBinding.wrappedValue != value else { return }
                self.presentedBinding.wrappedValue = value
            }
        }

        func showIfNeeded() {
            guard let anchorView, anchorView.window != nil else { return }

            if panel == nil {
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.level = .popUpMenu
                panel.isReleasedWhenClosed = false
                panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
                panel.hidesOnDeactivate = false
                self.panel = panel
            }

            if let hostingView {
                hostingView.rootView = rootContent
            } else {
                let created = NSHostingView(rootView: rootContent)
                created.sizingOptions = [.intrinsicContentSize]
                hostingView = created
                panel?.contentView = created
            }

            // Never call layoutSubtreeIfNeeded during updateNSView — AppKit may already
            // be mid-layout. Defer measure + orderFront to the next runloop turn.
            guard !pendingPresent else { return }
            pendingPresent = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingPresent = false
                self.measureAndPresent()
            }
        }

        private func measureAndPresent() {
            guard presentedBinding.wrappedValue else { return }
            guard let hosting = hostingView, let panel else { return }
            guard anchorView?.window != nil else { return }

            hosting.layoutSubtreeIfNeeded()
            var size = hosting.fittingSize
            size.width = max(size.width, 180)
            size.height = max(size.height, 40)

            let alreadyVisible = panel.isVisible
            let sizeUnchanged = size.equalTo(lastPresentedSize)
            if alreadyVisible && sizeUnchanged {
                positionPanel(size: size)
                installMonitorsIfNeeded()
                return
            }

            hosting.frame = NSRect(origin: .zero, size: size)
            panel.setContentSize(size)
            lastPresentedSize = size
            positionPanel(size: size)
            panel.orderFront(nil)
            installMonitorsIfNeeded()
        }

        func dismiss() {
            pendingPresent = false
            lastPresentedSize = .zero
            removeMonitors()
            panel?.orderOut(nil)
        }

        private func positionPanel(size: NSSize) {
            guard let panel, let anchorView, let window = anchorView.window else { return }

            let anchorInWindow = anchorView.convert(anchorView.bounds, to: nil)
            let anchorOnScreen = window.convertToScreen(anchorInWindow)
            let gap: CGFloat = 4
            // SoftDropdownPanel adds transparent padding for shadow bleed — align
            // the visible card (not the padded frame) to the anchor.
            let bleed = SoftDropdownPanelMetrics.shadowBleed

            let alignedX: CGFloat
            switch horizontalAlignment {
            case .leading:
                // Left-align: visible card's leading edge matches the control.
                alignedX = anchorOnScreen.minX - bleed
            case .trailing:
                // Right-align: wider menus grow leftward from the trailing edge.
                alignedX = anchorOnScreen.maxX - size.width + bleed
            }

            var origin = NSPoint(
                x: alignedX,
                y: anchorOnScreen.minY - size.height - gap + bleed
            )

            if let screen = window.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                if origin.y + bleed < visible.minY {
                    origin.y = anchorOnScreen.maxY + gap - bleed
                }
                if origin.x + bleed < visible.minX {
                    origin.x = visible.minX + 4 - bleed
                }
                if origin.x + size.width - bleed > visible.maxX {
                    origin.x = visible.maxX - size.width + bleed - 4
                }
            }

            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        private func installMonitorsIfNeeded() {
            guard localMonitor == nil else { return }

            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { // Escape
                        self.setPresented(false)
                        return nil
                    }
                    return event
                }
                if self.eventIsOutsideDropdown(event) {
                    self.setPresented(false)
                }
                return event
            }

            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                self?.setPresented(false)
            }
        }

        private func removeMonitors() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
        }

        private func eventIsOutsideDropdown(_ event: NSEvent) -> Bool {
            // Clicks inside the floating panel should keep it open.
            if event.window === panel {
                return false
            }

            if let anchorView, event.window === anchorView.window {
                let locationInAnchor = anchorView.convert(event.locationInWindow, from: nil)
                if anchorView.bounds.contains(locationInAnchor) {
                    // Click on the anchor toggles via the Button — don't force-close here.
                    return false
                }
            }

            return true
        }

        deinit {
            removeMonitors()
            panel?.orderOut(nil)
            panel = nil
            hostingView = nil
        }
    }
}
