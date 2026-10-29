import SwiftUI
import UIKit

extension DocumentEditorView {
    var commandMoreAccessibilityHint: String {
        guard KeyboardAccessoryView.geometryDiagnosticsEnabled else { return L10n.a11yEditorMenuHint }
        return L10n.a11yEditorMenuHint + "\n[EditorCommandGeometry]\n" + commandGeometryDiagnosticSamples.joined(separator: "\n")
    }

    func recordCommandGeometryDiagnostic(event: String, geometry: EditorCommandGeometry?) {
        guard KeyboardAccessoryView.geometryDiagnosticsEnabled else { return }
        let rect = SlideshowUsableRegion.describe
        let route = commandPanel.map { String(describing: $0) } ?? "closed"
        let sample: String
        if let geometry {
            let minimum = commandPanelMinimumSize(commandPanel, width: geometry.region.width)
            let insets = geometry.safeInsets
            sample = "event=\(event) route=\(route) local=\(rect(geometry.localBounds)) global=\(rect(geometry.bounds)) "
                + "safeInsets=[\(insets.top),\(insets.leading),\(insets.bottom),\(insets.trailing)] "
                + "expanded=[\(geometry.expandedRegions.map(rect).joined(separator: ";"))] "
                + "selected=\(rect(geometry.region)) min=[\(minimum.width),\(minimum.height)] "
                + "canPresent=\(geometry.canPresent(minimumSize: minimum)) "
                + "keyboard=\(commandKeyboardDiagnosticPhase) keyboardEndScreen=\(rect(commandKeyboardDiagnosticFrame))"
        } else {
            sample = "event=\(event) route=\(route) geometry=pending keyboard=\(commandKeyboardDiagnosticPhase) keyboardEndScreen=\(rect(commandKeyboardDiagnosticFrame))"
        }
        commandGeometryDiagnosticSamples = EditorCommandDiagnosticRing.appending(sample, to: commandGeometryDiagnosticSamples)
    }

    func recordCommandKeyboardDiagnostic(_ notification: Notification, phase: String) {
        guard KeyboardAccessoryView.geometryDiagnosticsEnabled else { return }
        commandKeyboardDiagnosticPhase = phase
        commandKeyboardDiagnosticFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        recordCommandGeometryDiagnostic(event: phase, geometry: commandGeometry)
    }

    func captureCommandAnchor() -> EditorCommandAnchor {
        EditorCommandAnchor(projectID: document.stableProjectIDRawValue, fileName: currentFileName,
                            loadToken: fileLoadToken,
                            selection: commandTarget.selection ?? currentInsertionRange(),
                            restoreFocus: focusCoordinator.isEditorFocused)
    }

    func commandAnchorIsCurrent(_ anchor: EditorCommandAnchor) -> Bool {
        anchor.matches(projectID: document.stableProjectIDRawValue, fileName: currentFileName,
                       loadToken: fileLoadToken, writable: projectWritableLease != nil)
    }

    func openCommandPanel(_ panel: EditorCommandPanel) {
        guard let geometry = commandGeometry,
              geometry.canPresent(minimumSize: commandPanelPresentationMinimumSize(panel, geometry: geometry)) else {
            recordCommandGeometryDiagnostic(event: "open-unusable", geometry: commandGeometry)
            if commandPanel == nil, commandPendingOpen == nil { commandAnchor = nil }
            return
        }
        if commandAnchor == nil { commandAnchor = captureCommandAnchor() }
        commandPanel = panel
        recordCommandGeometryDiagnostic(event: "open", geometry: commandGeometry)
    }

    // The confined panel lives in editorPane, not in the preview. Reveal its
    // existing safe host rather than expanding the panel into preview geometry.
    func openMoreCommandPanel() {
        if commandSessionSafety.awaitingExplicitResume {
            guard let geometry = commandGeometry,
                  geometry.canPresent(minimumSize: commandPanelPresentationMinimumSize(commandPanel, geometry: geometry)),
                  commandSessionSafety.resumeExplicitly(region: geometry.region.size) else {
                AccessibilitySupport.announce(L10n.tr("editor.command.resume.insufficient_space"))
                return
            }
            // The editor was available during the pause. Never reuse the old
            // file/token/caret even if its query and mounted browser survived.
            commandAnchor = captureCommandAnchor()
            return
        }
        if commandPendingOpen != nil {
            resumePendingCommandOpen()
            return
        }
        if commandPanel == nil { commandAnchor = captureCommandAnchor() }
        let shareAction = shareButtonAction
        let shareLabel = shareButtonLabel
        if selectedTab == previewTab {
            shouldRestoreEditorFocusAfterPreview = false
            selectedTab = editorTab
        }
        if let anchor = commandAnchor, focusCoordinator.isEditorFocused,
           commandGeometry.map({ !$0.canPresent(minimumSize: commandPanelMinimumSize(.commands, width: $0.region.width)) }) ?? true {
            commandMoreShareAction = shareAction
            commandMoreShareLabel = shareLabel
            commandPendingOpen = EditorCommandPendingOpen(anchor: anchor, source: editorText)
            recordCommandGeometryDiagnostic(event: "pending-keyboard-hide", geometry: commandGeometry)
            focusCoordinator.dismissKeyboard()
            resumePendingCommandOpen()
            return
        }
        openCommandPanel(.commands)
        if commandPanel == .commands {
            // Capture BEFORE switching modes: Preview's Share must remain PDF.
            commandMoreShareAction = shareAction
            commandMoreShareLabel = shareLabel
            assert(selectedTab == editorTab, "More fallback requires the visible editor host")
        }
    }

    func resumePendingCommandOpen() {
        guard let pending = commandPendingOpen else { return }
        let current = captureCommandAnchor()
        guard commandAnchorIsCurrent(pending.anchor),
              pending.isCurrent(current: current, source: editorText) else {
            closeCommandPanel(restoreFocus: false)
            return
        }
        guard let geometry = commandGeometry,
              pending.canOpen(current: current, source: editorText,
                              keyboardTransitionInFlight: commandKeyboardTransitionInFlight, geometry: geometry,
                              minimum: commandPanelPresentationMinimumSize(.commands, geometry: geometry)) else { return }
        commandPendingOpen = nil
        commandPanel = .commands
        recordCommandGeometryDiagnostic(event: "pending-open", geometry: commandGeometry)
    }

    @ViewBuilder
    var commandHeaderTitle: some View {
        Text(commandPanelTitle(commandPanel))
            .accessibilityIdentifier("editor.commands-panel")
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var commandHeaderDone: some View {
        Button { closeCommandPanel() } label: {
            Text(L10n.tr("Done"))
                .font(.body)
                .fixedSize(horizontal: true, vertical: true)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("Done"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("editor.commands-done")
    }

    func invalidateCommandContextAfterFileChange() {
        if commandSessionSafety.awaitingExplicitResume {
            commandAnchor = nil
            commandPendingOpen = nil
        } else {
            closeCommandPanel(restoreFocus: false)
        }
    }

    func observeCommandSessionGeometry(_ geometry: EditorCommandGeometry?) {
        guard commandPanel != nil, let geometry else { return }
        commandSessionSafety.observe(region: geometry.region.size)
        if commandSessionSafety.awaitingExplicitResume {
            commandAnchor = nil
            commandPendingOpen = nil
        }
    }

    var commandPanelOwnsInteraction: Bool {
        guard commandPanel != nil, !commandSessionSafety.awaitingExplicitResume,
              let geometry = commandGeometry else { return false }
        return geometry.canPresent(minimumSize: EditorCommandRecovery.minimumSize)
    }

    func closeCommandPanel(restoreFocus: Bool = true) {
        let anchor = commandAnchor
        recordCommandGeometryDiagnostic(event: "close", geometry: commandGeometry)
        commandPanel = nil
        commandSessionSafety = EditorCommandSessionSafety()
        commandPendingOpen = nil
        commandMoreShareAction = nil
        commandMoreShareLabel = nil
        commandAnchor = nil
        if restoreFocus, let anchor, anchor.restoreFocus, commandAnchorIsCurrent(anchor) {
            focusCoordinator.activateKeyboard()
        }
    }

    func presentCommandSymbols() {
        guard projectWritableLease != nil else { return }
        openCommandPanel(.symbols)
    }

    func presentCommandSnippets() {
        recordCommandGeometryDiagnostic(event: projectWritableLease != nil ? "request-snippets-writable" : "request-snippets-readonly", geometry: commandGeometry)
        guard projectWritableLease != nil else { return }
        openCommandPanel(.snippets)
    }

    func presentCommandPhoto() {
        guard projectWritableLease != nil else { return }
        photoCommandAnchor = commandAnchor ?? captureCommandAnchor()
        closeCommandPanel(restoreFocus: false)
        showingPhotoPicker = true
    }

    func insertCommandText(_ text: String, cursorOffset: Int? = nil) {
        guard !commandSessionSafety.awaitingExplicitResume else { return }
        guard let anchor = commandAnchor, commandAnchorIsCurrent(anchor) else {
            closeCommandPanel()
            return
        }
        enqueueInsertion(text, at: anchor.selection, for: anchor.fileName,
                         loadToken: anchor.loadToken, cursorOffset: cursorOffset)
        closeCommandPanel()
    }

    func insertCommandSnippet(_ snippet: Snippet) {
        let (text, cursorOffset) = snippet.bodyWithCursorOffset()
        insertCommandText(text, cursorOffset: cursorOffset)
    }

    @ViewBuilder
    var editingCommandMenuGroups: some View {
        Section {
            Button(action: presentCommandSymbols) {
                Label(L10n.tr("editor.command.insert_symbol"), systemImage: "number")
            }
            .disabled(projectWritableLease == nil)
            .accessibilityIdentifier("editor.insert-symbol")
            Button(action: presentCommandSnippets) {
                Label(L10n.tr("editor.command.insert_snippet"), systemImage: "curlybraces")
            }
            .disabled(projectWritableLease == nil)
            .accessibilityIdentifier("editor.insert-snippet")
            Button(action: presentCommandPhoto) {
                Label(L10n.tr("editor.command.insert_image"), systemImage: "photo")
            }
            .disabled(projectWritableLease == nil)
            .accessibilityIdentifier("editor.insert-photo")
        }
        Section {
            Button { if commandAnchor == nil { commandAnchor = captureCommandAnchor() }; commandTarget.undo(); closeCommandPanel() } label: {
                Label(L10n.a11yKeyboardUndoLabel, systemImage: "arrow.uturn.backward")
            }
            .disabled(projectWritableLease == nil || !commandTarget.canUndo)
            .accessibilityIdentifier("editor.undo")
            Button { if commandAnchor == nil { commandAnchor = captureCommandAnchor() }; commandTarget.redo(); closeCommandPanel() } label: {
                Label(L10n.a11yKeyboardRedoLabel, systemImage: "arrow.uturn.forward")
            }
            .disabled(projectWritableLease == nil || !commandTarget.canRedo)
            .accessibilityIdentifier("editor.redo")
        }
    }

    @ViewBuilder
    func editorMoreControl(includeSlideshow: Bool = false) -> some View {
        if commandGeometry?.needsPanel == true {
            Button { openMoreCommandPanel() } label: {
                Label(L10n.a11yEditorMenuLabel, systemImage: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(L10n.a11yEditorMenuLabel)
            .accessibilityHint(commandMoreAccessibilityHint)
            .accessibilityIdentifier("editor.more-menu")
        } else {
            Menu {
                if commandSessionSafety.awaitingExplicitResume, commandPanel != nil {
                    Section {
                        Button { openMoreCommandPanel() } label: {
                            Text(L10n.tr(commandPanel == .snippets
                                ? "editor.command.resume.snippets" : commandPanel == .symbols
                                ? "editor.command.resume.symbols" : "editor.command.resume.commands"))
                        }
                        .accessibilityIdentifier("editor.commands-resume")
                    }
                }
                editorToolbarMenuContent
                if includeSlideshow {
                    Button { showingSlideshow = true } label: {
                        Label(L10n.tr("Slideshow"), systemImage: "play.rectangle")
                    }.disabled(!canPresentSlideshow)
                }
            } label: {
                Label(L10n.a11yEditorMenuLabel, systemImage: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(L10n.a11yEditorMenuLabel)
            .accessibilityHint(commandMoreAccessibilityHint)
            .accessibilityIdentifier("editor.more-menu")
        }
    }

    func commandPanelTitle(_ panel: EditorCommandPanel?) -> String {
        panel == .symbols ? L10n.tr("editor.command.insert_symbol") :
            panel == .snippets ? L10n.tr("editor.command.insert_snippet") : L10n.a11yEditorMenuLabel
    }

    func commandPanelMinimumSize(_ panel: EditorCommandPanel?, width: CGFloat) -> CGSize {
        EditorCommandHeader.minimumSize(title: commandPanelTitle(panel), done: L10n.tr("Done"),
                                        width: width, category: dynamicTypeSize.commandContentSizeCategory)
    }

    func commandPanelPresentationMinimumSize(_ panel: EditorCommandPanel?, geometry: EditorCommandGeometry) -> CGSize {
        let full = commandPanelMinimumSize(panel, width: geometry.region.width)
        return EditorCommandRecovery.isNeeded(region: geometry.region.size, fullHeaderMinimum: full,
            category: dynamicTypeSize.commandContentSizeCategory)
            ? EditorCommandRecovery.minimumSize : full
    }

    var commandPanelNeedsRecovery: Bool {
        guard let geometry = commandGeometry else { return false }
        return EditorCommandRecovery.isNeeded(region: geometry.region.size,
            fullHeaderMinimum: commandPanelMinimumSize(commandPanel, width: geometry.region.width),
            category: dynamicTypeSize.commandContentSizeCategory)
    }

    var commandSearchDismissControl: some View {
        Button { commandSearchDismissRequest = UUID() } label: {
            Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 20))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("Dismiss Keyboard"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("editor.commands-dismiss-keyboard")
    }

    var commandRecoveryControls: some View {
        HStack(spacing: 8) {
            Button { closeCommandPanel() } label: {
                Image(systemName: "xmark").font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.tr("Done"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("editor.commands-done")
            Spacer(minLength: 0)
            commandSearchDismissControl
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    var commandPanelCanPresent: Bool {
        guard commandPanel != nil, let geometry = commandGeometry else { return false }
        return geometry.canPresent(minimumSize: commandPanelPresentationMinimumSize(commandPanel, geometry: geometry))
    }

    var safeEditorCommandPanel: some View {
        VStack(spacing: 0) {
            if commandPanelNeedsRecovery {
                commandRecoveryControls
            } else {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 0) {
                            commandHeaderTitle
                            HStack(spacing: 8) {
                                commandHeaderDone
                                if commandSearchFocused { commandSearchDismissControl }
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            commandHeaderTitle
                            commandHeaderDone
                            if commandSearchFocused { commandSearchDismissControl }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            Divider()
            if commandPanel == .snippets {
                SnippetBrowserSheet(confinedInsertionOnly: true,
                                    confinedHeaderTitle: commandPanelNeedsRecovery ? commandPanelTitle(commandPanel) : nil,
                                    searchDismissRequest: commandSearchDismissRequest,
                                    onSearchFocusChanged: { commandSearchFocused = $0 },
                                    onInsert: insertCommandSnippet)
            } else {
                List {
                    if commandPanelNeedsRecovery {
                        commandHeaderTitle
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                    if commandPanel == .symbols {
                        ForEach(EditorCommandSymbol.all) { symbol in
                            Button { insertCommandText(symbol.insertion) } label: {
                                Text(symbol.title)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                                .disabled(projectWritableLease == nil)
                                .accessibilityIdentifier("editor.symbol.\(symbol.id)")
                                .listRowBackground(Color(uiColor: themeManager.currentTheme.background))
                        }
                    } else {
                        editorToolbarMenuContent
                            .listRowBackground(Color(uiColor: themeManager.currentTheme.background))
                        if sizeClass != .compact {
                            Section {
                                Button { closeCommandPanel(); showingSlideshow = true } label: {
                                    Label(L10n.tr("Slideshow"), systemImage: "play.rectangle")
                                }.disabled(!canPresentSlideshow)
                            }
                        }
                    }
                }
                .labelStyle(EditorCommandLabelStyle())
                .buttonStyle(EditorCommandRowStyle())
                .listStyle(.grouped)
                .listSectionSpacing(8)
                .listRowInsets(EdgeInsets())
                .environment(\.defaultMinListRowHeight, 44)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("editor.commands-scroll")
            }
        }
        .foregroundStyle(Color(uiColor: themeManager.currentTheme.text))
        .tint(Color(uiColor: themeManager.currentTheme.functionColor))
        .background(Color(uiColor: themeManager.currentTheme.background))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.15)))
    }
}

/// Opt-in geometry-only endpoint; does not inspect editor or search contents.
struct EditorCommandDiagnosticValue: UIViewRepresentable {
    var value: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "editor.command-diagnostics"
        view.accessibilityLabel = "Command geometry diagnostics"
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityValue = value
    }
}
