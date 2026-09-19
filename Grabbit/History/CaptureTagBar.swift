//
//  CaptureTagBar.swift
//  Grabbit
//
//  Shared tag chips + add-tag control for Capture Library preview.
//

import AppKit
import SwiftUI

struct CaptureTagBar: View {
    let tags: [CaptureTag]
    let onRemoveTag: (CaptureTag) -> Void
    let onAddTag: (CaptureTagKind, String) -> Void
    /// Replaces an existing project tag with a new name (move/upsert).
    var onReplaceTag: ((CaptureTag, String) -> Void)? = nil

    @State private var isAdding = false
    @State private var draftKind: CaptureTagKind = .custom
    @State private var draftName = ""
    @FocusState private var addFieldFocused: Bool

    /// Project is singular (the folder). Omit it from the add picker when one already exists.
    private var availableKinds: [CaptureTagKind] {
        if tags.contains(where: { $0.kind == .project }) {
            return CaptureTagKind.allCases.filter { $0 != .project }
        }
        return Array(CaptureTagKind.allCases)
    }

    private var projectOptions: [String] {
        CaptureLibraryOrganizer.existingProjectNames()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if !tags.isEmpty || isAdding {
                FlowLayout(spacing: DesignTokens.Spacing.sm) {
                    ForEach(CaptureTag.sorted(tags)) { tag in
                        tagView(tag)
                    }

                    if isAdding {
                        addTagField
                    } else {
                        addButton
                    }
                }
            } else {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text("No tags")
                        .font(.grabbit(.caption))
                        .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                    addButton
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func tagView(_ tag: CaptureTag) -> some View {
        switch tag.kind {
        case .project:
            TagKindDropdown(
                kind: .project,
                selected: tag.name,
                options: projectOptions,
                onRemove: { onRemoveTag(tag) },
                onSelect: { name in
                    if name.caseInsensitiveCompare(tag.name) == .orderedSame { return }
                    if let onReplaceTag {
                        onReplaceTag(tag, name)
                    } else {
                        onRemoveTag(tag)
                        onAddTag(.project, name)
                    }
                },
                onCreateNew: { beginCustom(kind: .project) }
            )
        case .custom:
            tagChip(tag)
        }
    }

    private func tagChip(_ tag: CaptureTag) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(tag.kind.displayName)
                    .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                Text(tag.name)
                    .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
            }
            .padding(.leading, DesignTokens.Spacing.sm)
            .padding(.trailing, 6)
            .padding(.vertical, 3)

            Rectangle()
                .fill(DesignTokens.Color.border.swiftUI)
                .frame(width: 1)
                .padding(.vertical, 1)

            Button {
                onRemoveTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Remove \(tag.kind.displayName.lowercased()) tag")
        }
        .font(.grabbit(.caption))
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .fill(DesignTokens.Color.listSelectionFill.swiftUI)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .strokeBorder(DesignTokens.Color.border.swiftUI, lineWidth: 1)
        }
        .fixedSize()
    }

    private var addButton: some View {
        Button {
            isAdding = true
            draftKind = availableKinds.contains(.custom) ? .custom : (availableKinds.first ?? .custom)
            draftName = ""
            DispatchQueue.main.async {
                addFieldFocused = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Color.textSecondary.swiftUI)
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                        .fill(DesignTokens.Color.listSelectionFill.swiftUI)
                )
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Add tag")
    }

    private var addTagField: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Picker("Kind", selection: $draftKind) {
                ForEach(kindsForAddField) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            TextField(draftKind == .project ? "Project folder" : "Tag name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.grabbit(.caption))
                .frame(minWidth: 100, maxWidth: 180)
                .focused($addFieldFocused)
                .onSubmit(commitAdd)

            Button(draftKind == .project ? "Move" : "Add") {
                commitAdd()
            }
            .buttonStyle(.grabbitCompact)
            .disabled(CaptureTag.normalizeName(draftName).isEmpty)
            .help(
                draftKind == .project
                    ? "Set project and move this capture into that folder"
                    : "Add tag"
            )

            Button {
                cancelAdd()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .foregroundStyle(DesignTokens.Color.textTertiary.swiftUI)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .fill(DesignTokens.Color.listSelectionFill.swiftUI)
        )
        .onExitCommand {
            cancelAdd()
        }
        .onChange(of: availableKinds.map(\.rawValue).joined(separator: ",")) { _, _ in
            if !kindsForAddField.contains(draftKind) {
                draftKind = kindsForAddField.first ?? .custom
            }
        }
    }

    /// When Custom… opens from an existing project dropdown, keep project in the picker.
    private var kindsForAddField: [CaptureTagKind] {
        if draftKind == .project || !tags.contains(where: { $0.kind == .project }) {
            return Array(CaptureTagKind.allCases)
        }
        return availableKinds
    }

    private func beginCustom(kind: CaptureTagKind) {
        isAdding = true
        draftKind = kind
        draftName = ""
        DispatchQueue.main.async {
            addFieldFocused = true
        }
    }

    private func commitAdd() {
        let name = CaptureTag.normalizeName(draftName)
        guard !name.isEmpty else { return }
        if draftKind == .project,
           let existing = tags.first(where: { $0.kind == draftKind }) {
            if let onReplaceTag {
                onReplaceTag(existing, name)
            } else {
                onRemoveTag(existing)
                onAddTag(draftKind, name)
            }
        } else {
            onAddTag(draftKind, name)
        }
        cancelAdd()
    }

    private func cancelAdd() {
        isAdding = false
        draftName = ""
        addFieldFocused = false
    }
}

/// Select-only soft dropdown — one unified control (label + value + chevron),
/// not the split field + icon-button chrome used by `TagKindDropdown`.
struct SoftControlDropdown<MenuContent: View>: View {
    var leadingLabel: String? = nil
    let title: String
    var help: String? = nil
    var primaryForeground: Color = DesignTokens.Color.textPrimary.swiftUI
    var secondaryForeground: Color = DesignTokens.Color.textSecondary.swiftUI
    /// How the floating menu attaches horizontally to this control.
    var menuAlignment: SoftDropdownHorizontalAlignment = .trailing
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var isHovered = false
    @State private var isPresented = false

    var body: some View {
        SoftDropdownAnchor(isPresented: $isPresented, horizontalAlignment: menuAlignment) {
            HStack(spacing: 6) {
                if let leadingLabel {
                    Text(leadingLabel)
                        .foregroundStyle(secondaryForeground)
                }
                Text(title)
                    .foregroundStyle(primaryForeground)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(secondaryForeground)
            }
            .font(.grabbit(.caption))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(
                        isHovered || isPresented
                            ? DesignTokens.Color.softControlFillHovered.swiftUI
                            : DesignTokens.Color.softControlFill.swiftUI
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .strokeBorder(DesignTokens.Color.softControlBorder.swiftUI, lineWidth: 1)
            }
        } menuContent: {
            menuContent()
        }
        .fixedSize()
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isPresented)
        .pointerStyle(.link)
        .modifier(OptionalHelpModifier(help: help))
    }
}

/// Icon-only soft control that opens the same floating dropdown panel.
/// At rest it's just the glyph; a subtle fill appears on hover / while open.
struct SoftControlIconDropdown<MenuContent: View>: View {
    let systemImage: String
    var isActive: Bool = false
    var help: String? = nil
    var foreground: Color = DesignTokens.Color.textPrimary.swiftUI
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var isHovered = false
    @State private var isPresented = false

    private var showsHoverFill: Bool {
        isHovered || isPresented
    }

    var body: some View {
        SoftDropdownAnchor(isPresented: $isPresented) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? DesignTokens.Color.primary.swiftUI : foreground)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                        .fill(
                            showsHoverFill
                                ? DesignTokens.Color.softControlFillHovered.swiftUI
                                : Color.clear
                        )
                }
        } menuContent: {
            menuContent()
        }
        .fixedSize()
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isPresented)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .pointerStyle(.link)
        .modifier(OptionalHelpModifier(help: help))
    }
}

private struct OptionalHelpModifier: ViewModifier {
    let help: String?

    func body(content: Content) -> some View {
        if let help, !help.isEmpty {
            content.help(help)
        } else {
            content
        }
    }
}

/// Applies `.fixedSize` when horizontal and/or vertical hugging is desired.
/// Bulk cards turn off horizontal hug (`fillsAvailableWidth`) but still need
/// vertical hug so soft controls stay single-line next to filename chrome.
private struct OptionalHorizontalFixedSize: ViewModifier {
    let enabled: Bool
    var vertical: Bool = false

    init(_ enabled: Bool, vertical: Bool = false) {
        self.enabled = enabled
        self.vertical = vertical
    }

    func body(content: Content) -> some View {
        if enabled || vertical {
            content.fixedSize(horizontal: enabled, vertical: vertical)
        } else {
            content
        }
    }
}

enum SoftControlDropdownChrome {
    @ViewBuilder
    static func divider(color: Color = DesignTokens.Color.softControlBorder.swiftUI) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 1)
            .padding(.vertical, 1)
    }

    static func chevron(
        height: CGFloat,
        color: Color = DesignTokens.Color.textSecondary.swiftUI
    ) -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: height)
            .contentShape(Rectangle())
    }
}

/// Plain AppKit field for soft controls — same insets while idle and editing,
/// so clicking doesn't nudge the text sideways.
private struct SoftControlPlainTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var textColor: NSColor
    var isEditable: Bool
    @Binding var isFocused: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void
    /// Auto Organize sheen — in-cell so Project text never swaps to SwiftUI.
    var isShimmering: Bool = false
    var shimmerHighlightColor: NSColor = DesignTokens.Color.textPrimary.ns

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SoftControlNSTextField {
        let field = SoftControlNSTextField(string: text)
        field.installStableEditingCell()
        field.font = NSFont.grabbit(.caption)
        field.textColor = textColor
        field.placeholderString = placeholder
        field.isEditable = isEditable
        field.isSelectable = isEditable
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.cancel(from: field)
        }
        // Stable intrinsic width: avoid focus thrash from field-editor metrics.
        field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.updateStableTextShimmer(
            isActive: isShimmering,
            highlightColor: isShimmering ? shimmerHighlightColor : nil
        )
        return field
    }

    func updateNSView(_ nsView: SoftControlNSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.placeholderString = placeholder
        nsView.textColor = textColor
        nsView.isEditable = isEditable
        nsView.isSelectable = isEditable
        if let cell = nsView.cell as? StableTextFieldCell {
            cell.placeholderString = placeholder
            cell.textColor = textColor
            cell.isEditable = isEditable
            cell.isSelectable = isEditable
        }

        if nsView.stringValue != text, nsView.currentEditor() == nil {
            nsView.stringValue = text
        }

        nsView.updateStableTextShimmer(
            isActive: isShimmering,
            highlightColor: isShimmering ? shimmerHighlightColor : nil
        )

        let editorIsFirstResponder = nsView.currentEditor() != nil
            && nsView.window?.firstResponder === nsView.currentEditor()
        let wasFocused = context.coordinator.wasFocused
        context.coordinator.wasFocused = isFocused

        if isFocused, isEditable, !editorIsFirstResponder {
            // SwiftUI wants focus — ask AppKit on the next turn.
            DispatchQueue.main.async {
                guard context.coordinator.parent.isFocused else { return }
                nsView.window?.makeFirstResponder(nsView)
                // Select all keeps truncated strings from scrolling to the end
                // (which reads as a leftward jump).
                nsView.stabilizeFocusedEditor(selectAll: true)
            }
        } else if !isFocused, wasFocused, editorIsFirstResponder {
            // SwiftUI explicitly dropped focus (escape / read-only) — resign.
            context.coordinator.isCancelling = true
            nsView.window?.makeFirstResponder(nil)
            context.coordinator.isCancelling = false
        } else if !isFocused, editorIsFirstResponder, !context.coordinator.isCancelling {
            // AppKit is editing but SwiftUI lagged (e.g. hover re-render).
            // Keep the field active — sync state up instead of killing focus.
            DispatchQueue.main.async {
                guard nsView.currentEditor() != nil else { return }
                context.coordinator.parent.isFocused = true
                context.coordinator.wasFocused = true
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SoftControlPlainTextField
        var isCancelling = false
        /// Last SwiftUI-facing focus value applied in `updateNSView`.
        var wasFocused = false
        private var skipNextEndEditingCommit = false

        init(parent: SoftControlPlainTextField) {
            self.parent = parent
        }

        @objc func submit(_ sender: NSTextField) {
            parent.text = sender.stringValue
            parent.onSubmit()
            skipNextEndEditingCommit = true
            sender.window?.makeFirstResponder(nil)
            parent.isFocused = false
            wasFocused = false
        }

        func cancel(from field: NSTextField) {
            isCancelling = true
            parent.onCancel()
            field.stringValue = parent.text
            field.window?.makeFirstResponder(nil)
            isCancelling = false
            parent.isFocused = false
            wasFocused = false
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isFocused = true
            wasFocused = true
            (obj.object as? NSTextField)?.stabilizeFocusedEditor(selectAll: false)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            defer { skipNextEndEditingCommit = false }
            guard let field = obj.object as? NSTextField else { return }
            if isCancelling || skipNextEndEditingCommit {
                parent.isFocused = false
                wasFocused = false
                return
            }
            parent.text = field.stringValue
            parent.isFocused = false
            wasFocused = false
            parent.onSubmit()
        }
    }
}

private final class SoftControlNSTextField: StableFlippedTextField {
    var onEscape: (() -> Void)?

    override class var cellClass: AnyClass? {
        get { StableTextFieldCell.self }
        set {}
    }

    /// Prefer string-measured size so focus doesn't change intrinsic width.
    override var intrinsicContentSize: NSSize {
        let font = self.font ?? NSFont.grabbit(.caption)
        let probe = stringValue.isEmpty ? (placeholderString ?? " ") : stringValue
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var size = (probe as NSString).size(withAttributes: attributes)
        // Caret slack + locked lineFragmentPadding — same idle and editing.
        size.width = ceil(size.width) + StableTextFieldMetrics.lineFragmentPadding + 1
        size.height = ceil(NSLayoutManager().defaultLineHeight(for: font))
        return size
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            // Re-lock insets after AppKit installs the shared field editor
            // (it resets lineFragmentPadding to 5 by default).
            stabilizeFocusedEditor(selectAll: false)
        }
        return ok
    }

    override func layout() {
        super.layout()
        guard let editor = currentEditor() as? NSTextView else { return }
        // Keep editor glued — AppKit may re-pad or reflow on bounds changes.
        (cell as? StableTextFieldCell)?.applyStableInsets(to: editor)
        (cell as? StableTextFieldCell)?.positionFieldEditor(editor, in: self, cellBounds: bounds)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Auto Organize rename suggestion: neutral soft-control name field (path segment after `/`).
struct SuggestedNameField: View {
    let name: String
    let onCommit: (String) -> Void
    /// When true, hug is disabled so the field stays within a parent column (bulk cards).
    var fillsAvailableWidth: Bool = false

    @State private var draft = ""
    @State private var isHovered = false
    @State private var isFocused = false

    var body: some View {
        SoftControlPlainTextField(
            text: $draft,
            placeholder: "Name",
            textColor: DesignTokens.Color.textPrimary.ns,
            isEditable: true,
            isFocused: $isFocused,
            onSubmit: commitDraft,
            onCancel: {
                syncDraft()
                isFocused = false
            }
        )
        .frame(
            minWidth: fillsAvailableWidth ? 0 : 128,
            maxWidth: fillsAvailableWidth ? .infinity : 440,
            alignment: .leading
        )
        .modifier(OptionalHorizontalFixedSize(!fillsAvailableWidth))
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(
                    isHovered || isFocused
                        ? DesignTokens.Color.softControlFillHovered.swiftUI
                        : DesignTokens.Color.softControlFill.swiftUI
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Color.softControlBorder.swiftUI, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
        .onHover { isHovered = $0 }
        .help("Edit suggested name")
        .focusEffectDisabled()
        .modifier(OptionalHorizontalFixedSize(!fillsAvailableWidth, vertical: true))
        .frame(
            maxWidth: fillsAvailableWidth ? .infinity : nil,
            alignment: .leading
        )
        .onAppear(perform: syncDraft)
        .onChange(of: name) { _, _ in
            guard !isFocused else { return }
            syncDraft()
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                draft = name
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    private func syncDraft() {
        draft = name
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            syncDraft()
            return
        }
        if trimmed.caseInsensitiveCompare(name) == .orderedSame {
            syncDraft()
            return
        }
        draft = trimmed
        onCommit(trimmed)
    }
}

struct TagKindDropdown: View {
    let kind: CaptureTagKind
    let selected: String
    let options: [String]
    var emphasized: Bool = false
    /// When true, keeps the same chrome but disables editing and the menu.
    var isReadOnly: Bool = false
    /// Auto Organize in flight — shimmer the name/placeholder like other AO loading UI.
    var isLoading: Bool = false
    /// When true (and not editing), `selected` changes slide-up replace instead of snapping.
    var slidesSelectionChanges: Bool = false
    /// When true, hug is disabled so the control stays within a parent column (bulk cards).
    var fillsAvailableWidth: Bool = false
    var onRemove: (() -> Void)? = nil
    let onSelect: (String) -> Void
    let onCreateNew: () -> Void

    @State private var draft = ""
    @State private var isHovered = false
    @State private var isMenuPresented = false
    @State private var isFocused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Read-only chrome, or AO loading (field shimmers; no edit / menu).
    private var blocksEditing: Bool {
        isReadOnly || isLoading
    }

    private var borderColor: Color {
        emphasized
            ? DesignTokens.Color.primary.swiftUI.opacity(0.35)
            : DesignTokens.Color.softControlBorder.swiftUI
    }

    private var labelForeground: Color {
        blocksEditing
            ? DesignTokens.Color.textSecondary.swiftUI
            : DesignTokens.Color.textPrimary.swiftUI
    }

    private var labelForegroundNS: NSColor {
        blocksEditing
            ? DesignTokens.Color.textSecondary.ns
            : DesignTokens.Color.textPrimary.ns
    }

    private var isEmptySelection: Bool {
        selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selected.caseInsensitiveCompare("None") == .orderedSame
    }

    private var placeholder: String {
        // Empty project shows "None" (matches SoftDropdown clear row), not the kind label.
        kind == .project ? "None" : kind.displayName
    }

    private var kindSymbol: String {
        kind == .project ? "folder" : "arrow.triangle.branch"
    }

    private var menuChevron: some View {
        SoftControlDropdownChrome.chevron(height: emphasized ? 24 : 22)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Focus stroke wraps the text field only — not the chevron/menu control.
            fieldContent
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                            .strokeBorder(DesignTokens.Color.softControlBorder.swiftUI, lineWidth: 1)
                    }
                }

            SoftControlDropdownChrome.divider(color: borderColor)

            if blocksEditing {
                menuChevron
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else {
                SoftDropdownAnchor(isPresented: $isMenuPresented) {
                    menuChevron
                } menuContent: {
                    ForEach(options, id: \.self) { name in
                        SoftDropdownRow(
                            title: name,
                            systemImage: kindSymbol,
                            isSelected: name.caseInsensitiveCompare(selected) == .orderedSame
                        ) {
                            applySelection(name)
                        }
                    }

                    if !options.isEmpty {
                        SoftDropdownDivider()
                    }

                    if onRemove != nil, !isEmptySelection {
                        SoftDropdownRow(title: "None", systemImage: "circle.slash") {
                            onRemove?()
                        }
                    }

                    SoftDropdownRow(title: "Custom…", systemImage: "plus") {
                        onCreateNew()
                    }
                }
                .pointerStyle(.link)
                .help(
                    kind == .project
                        ? "Choose project folder"
                        : "Choose \(kind.displayName.lowercased())"
                )
            }
        }
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(
                    !blocksEditing && isActive
                        ? DesignTokens.Color.softControlFillHovered.swiftUI
                        : DesignTokens.Color.softControlFill.swiftUI
                )
        }
        .overlay {
            // Unified soft outline while idle/hover/menu-open; suppressed while the
            // text field is focused so only the field-side stroke remains.
            if !isFocused {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
        }
        // Hug height always (match SuggestedNameField / pre-bulk-card `.fixedSize()`).
        // Without vertical hug the divider Rectangle expands and blows the header row.
        .modifier(OptionalHorizontalFixedSize(!fillsAvailableWidth, vertical: true))
        .frame(
            maxWidth: fillsAvailableWidth ? .infinity : nil,
            alignment: .leading
        )
        .focusEffectDisabled()
        .onAppear(perform: syncDraftFromSelected)
        .onChange(of: selected) { _, _ in
            guard !isFocused else { return }
            syncDraftFromSelected()
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                draft = isEmptySelection ? "" : selected
            }
        }
        .onChange(of: isReadOnly) { _, readOnly in
            if readOnly {
                isFocused = false
                syncDraftFromSelected()
            }
        }
        .onChange(of: isLoading) { _, loading in
            if loading {
                isFocused = false
                isMenuPresented = false
                syncDraftFromSelected()
            }
        }
        .onHover { hovering in
            guard !blocksEditing else { return }
            isHovered = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .animation(.easeOut(duration: 0.12), value: isMenuPresented)
        .accessibilityAddTraits(blocksEditing ? .isStaticText : [])
        .modifier(OptionalHelpModifier(help: isLoading ? "Auto-organizing…" : nil))
    }

    /// Hover, keyboard focus, or open menu — stays lit when the pointer leaves.
    private var isActive: Bool {
        isHovered || isFocused || isMenuPresented
    }

    /// Name when set; otherwise the placeholder (`None` for project) — what AO shimmers.
    private var displayFieldText: String {
        isEmptySelection ? placeholder : selected
    }

    private var fieldTextColorNS: NSColor {
        if isLoading {
            return DesignTokens.Color.textSecondary.ns
        }
        return labelForegroundNS
    }

    /// Slide-up path for accept handoff — AppKit field can’t participate in SwiftUI transitions.
    private var usesSlideSelectionLabel: Bool {
        slidesSelectionChanges && blocksEditing && !isLoading && !isFocused
    }

    @ViewBuilder
    private var fieldContent: some View {
        HStack(spacing: 6) {
            Image(systemName: kind == .project ? "folder.fill" : "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(labelForeground)

            if usesSlideSelectionLabel {
                SlideUpReplaceSlot(value: displayFieldText) {
                    Text(displayFieldText)
                        .font(.grabbit(.caption))
                        .foregroundStyle(labelForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(
                    minWidth: fillsAvailableWidth ? 0 : 88,
                    maxWidth: fillsAvailableWidth ? .infinity : 200,
                    alignment: .leading
                )
                .fixedSize(horizontal: false, vertical: true)
                .modifier(OptionalHorizontalFixedSize(!fillsAvailableWidth))
                .accessibilityLabel(displayFieldText)
            } else {
                // SoftControlPlainTextField — in-cell shimmer keeps StableTextFieldCell metrics.
                SoftControlPlainTextField(
                    text: $draft,
                    placeholder: placeholder,
                    textColor: fieldTextColorNS,
                    isEditable: !blocksEditing,
                    isFocused: $isFocused,
                    onSubmit: commitDraft,
                    onCancel: {
                        syncDraftFromSelected()
                        isFocused = false
                    },
                    isShimmering: isLoading,
                    shimmerHighlightColor: DesignTokens.Color.textPrimary.ns
                )
                .frame(
                    minWidth: fillsAvailableWidth ? 0 : 88,
                    maxWidth: fillsAvailableWidth ? .infinity : 200,
                    alignment: .leading
                )
                .fixedSize(horizontal: false, vertical: true)
                .modifier(OptionalHorizontalFixedSize(!fillsAvailableWidth))
                .accessibilityLabel(
                    isLoading ? "\(displayFieldText), auto-organizing" : displayFieldText
                )
                .transaction { $0.animation = nil }
            }
        }
        .font(.grabbit(.caption))
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, emphasized ? 5 : 4)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                guard !blocksEditing else { return }
                isFocused = true
            }
        )
        .allowsHitTesting(!blocksEditing)
        .animation(
            usesSlideSelectionLabel
                ? DesignMotion.suggestionAccept(reduceMotion: reduceMotion)
                : nil,
            value: displayFieldText
        )
    }

    private func syncDraftFromSelected() {
        draft = isEmptySelection ? "" : selected
    }

    private func commitDraft() {
        guard !blocksEditing else {
            syncDraftFromSelected()
            return
        }

        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("None") == .orderedSame {
            if let onRemove, !isEmptySelection {
                onRemove()
            } else {
                syncDraftFromSelected()
            }
            return
        }

        if !isEmptySelection, trimmed.caseInsensitiveCompare(selected) == .orderedSame {
            syncDraftFromSelected()
            return
        }

        applySelection(trimmed)
    }

    private func applySelection(_ name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        draft = normalized
        onSelect(normalized)
    }
}

/// Simple wrapping layout for tag chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }

        return (CGSize(width: totalWidth, height: y + rowHeight), frames)
    }
}
