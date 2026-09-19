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
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var isHovered = false
    @State private var isPresented = false

    var body: some View {
        SoftDropdownAnchor(isPresented: $isPresented) {
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
struct SoftControlIconDropdown<MenuContent: View>: View {
    let systemImage: String
    var isActive: Bool = false
    var help: String? = nil
    var foreground: Color = DesignTokens.Color.textPrimary.swiftUI
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var isHovered = false
    @State private var isPresented = false

    var body: some View {
        SoftDropdownAnchor(isPresented: $isPresented) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                        .fill(
                            isHovered || isPresented || isActive
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

private final class SoftControlNSTextField: NSTextField {
    var onEscape: (() -> Void)?

    /// Prefer string-measured size so focus doesn't change intrinsic width.
    override var intrinsicContentSize: NSSize {
        let font = self.font ?? NSFont.grabbit(.caption)
        let probe = stringValue.isEmpty ? (placeholderString ?? " ") : stringValue
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var size = (probe as NSString).size(withAttributes: attributes)
        // Constant caret slack — same idle and editing so layout doesn't jump.
        size.width = ceil(size.width) + 1
        size.height = ceil(max(size.height, font.ascender - font.descender))
        return size
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
        .frame(minWidth: 128, maxWidth: 440, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
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
                .strokeBorder(
                    isFocused
                        ? DesignTokens.Color.primary.swiftUI.opacity(0.45)
                        : DesignTokens.Color.softControlBorder.swiftUI,
                    lineWidth: 1
                )
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
        .onHover { isHovered = $0 }
        .help("Edit suggested name")
        .fixedSize(horizontal: true, vertical: true)
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
    var onRemove: (() -> Void)? = nil
    let onSelect: (String) -> Void
    let onCreateNew: () -> Void

    @State private var draft = ""
    @State private var isHovered = false
    @State private var isMenuPresented = false
    @State private var isFocused = false

    private var borderColor: Color {
        emphasized
            ? DesignTokens.Color.primary.swiftUI.opacity(0.35)
            : DesignTokens.Color.softControlBorder.swiftUI
    }

    private var labelForeground: Color {
        isReadOnly
            ? DesignTokens.Color.textSecondary.swiftUI
            : DesignTokens.Color.textPrimary.swiftUI
    }

    private var labelForegroundNS: NSColor {
        isReadOnly
            ? DesignTokens.Color.textSecondary.ns
            : DesignTokens.Color.textPrimary.ns
    }

    private var isEmptySelection: Bool {
        selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selected.caseInsensitiveCompare("None") == .orderedSame
    }

    private var placeholder: String {
        kind == .project ? "Project" : kind.displayName
    }

    private var kindSymbol: String {
        kind == .project ? "folder" : "arrow.triangle.branch"
    }

    private var menuChevron: some View {
        SoftControlDropdownChrome.chevron(height: emphasized ? 24 : 22)
    }

    var body: some View {
        HStack(spacing: 0) {
            fieldContent

            SoftControlDropdownChrome.divider(color: borderColor)

            if isReadOnly {
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
                    !isReadOnly && isActive
                        ? DesignTokens.Color.softControlFillHovered.swiftUI
                        : DesignTokens.Color.softControlFill.swiftUI
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(
                    isFocused
                        ? DesignTokens.Color.primary.swiftUI.opacity(0.45)
                        : borderColor,
                    lineWidth: 1
                )
        }
        .fixedSize()
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
        .onHover { hovering in
            guard !isReadOnly else { return }
            isHovered = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .animation(.easeOut(duration: 0.12), value: isMenuPresented)
        .accessibilityAddTraits(isReadOnly ? .isStaticText : [])
    }

    /// Hover, keyboard focus, or open menu — stays lit when the pointer leaves.
    private var isActive: Bool {
        isHovered || isFocused || isMenuPresented
    }

    @ViewBuilder
    private var fieldContent: some View {
        HStack(spacing: 6) {
            Image(systemName: kind == .project ? "folder.fill" : "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(labelForeground)

            SoftControlPlainTextField(
                text: $draft,
                placeholder: placeholder,
                textColor: labelForegroundNS,
                isEditable: !isReadOnly,
                isFocused: $isFocused,
                onSubmit: commitDraft,
                onCancel: {
                    syncDraftFromSelected()
                    isFocused = false
                }
            )
            .frame(minWidth: 88, maxWidth: 200, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(.grabbit(.caption))
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, emphasized ? 5 : 4)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                guard !isReadOnly else { return }
                isFocused = true
            }
        )
        .allowsHitTesting(!isReadOnly)
    }

    private func syncDraftFromSelected() {
        draft = isEmptySelection ? "" : selected
    }

    private func commitDraft() {
        guard !isReadOnly else {
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
