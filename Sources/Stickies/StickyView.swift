import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let stickyToggleChecklist = Notification.Name("BetterStickies.toggleChecklist")
    static let stickyAddLink = Notification.Name("BetterStickies.addLink")
    static let stickyLinkFolder = Notification.Name("BetterStickies.linkFolder")
}

/// Thin wrapper: resolves the note binding out of the store so the content
/// view can work with a plain Binding<Note>. If the note is gone (window
/// closing), renders nothing.
struct StickyView: View {
    @EnvironmentObject var store: NotesStore
    let noteID: UUID

    var body: some View {
        if let index = store.notes.firstIndex(where: { $0.id == noteID }) {
            StickyContent(note: $store.notes[index], reloadToken: store.externalReloadCount)
        } else {
            Color.clear
        }
    }
}

struct StickyContent: View {
    @Binding var note: Note
    /// Bumped when notes.json changed on disk (external edit).
    var reloadToken: Int = 0
    @EnvironmentObject var windowContext: WindowContext
    @StateObject private var editor = EditorController()
    @State private var showLinkInput = false
    @State private var linkText = ""
    @State private var dropTargeted = false
    @FocusState private var linkFieldFocused: Bool

    private var appearance: Appearance { note.appearance }

    var body: some View {
        ZStack {
            background

            RichEditor(controller: editor, initialLines: note.lines, style: appearance,
                       reloadToken: reloadToken) { lines in
                note.lines = lines
                applyFit()
            }
            .padding(.top, 30)
            .padding(.bottom, 6)

            controlsOverlay

            if showLinkInput { linkInput }
        }
        .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous))
        .overlay(edgeBorder)
        .environment(\.colorScheme, appearance.isDark ? .dark : .light)
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted, perform: handleDrop)
        .onAppear {
            if note.collapsed {
                windowContext.setCollapsed(true, height: collapsedHeight)
            } else {
                applyFit()
            }
        }
        .onChange(of: appearance) { applyFit() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard (notification.object as? NSWindow) === windowContext.window else { return }
            applyFit()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stickyCloseRequested)) { _ in
            if windowContext.isKey { requestClose() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stickyToggleChecklist)) { _ in
            if windowContext.isKey { editor.toggleChecklistLine() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stickyAddLink)) { _ in
            if windowContext.isKey { openLinkInput() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stickyLinkFolder)) { _ in
            if windowContext.isKey { pickFolder() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stickyEditorCommand)) { notification in
            guard windowContext.isKey,
                  let command = notification.userInfo?["command"] as? StickyCommand else { return }
            handleCommand(command)
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    // MARK: Background — fading glass, tint that reaches opaque, sheen

    private var background: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                // The Liquid Glass pane is the window's content view (see
                // WindowFactory) — nothing to draw here, just keep it in
                // step with the note's tint and transparency slider.
                Color.clear
                    .onAppear { pushGlassAppearance() }
                    .onChange(of: appearance) { pushGlassAppearance() }
            } else {
                GlassBackground(isDark: appearance.isDark, alpha: appearance.blurAlpha)
            }
            appearance.tint
                .opacity(appearance.tintOpacity)
            // The glass draws its own rim light on macOS 26 — a painted
            // sheen on top just flattens it back into a plastic pane.
            if #unavailable(macOS 26.0) {
                LinearGradient(colors: [.white.opacity(appearance.sheenStrength),
                                        .white.opacity(appearance.sheenStrength * 0.3),
                                        .clear],
                               startPoint: .topLeading, endPoint: .center)
                    .allowsHitTesting(false)
            }
        }
    }

    private func pushGlassAppearance() {
        windowContext.updateGlass(isDark: appearance.isDark, frost: appearance.frostAlpha,
                                  radius: appearance.cornerRadius,
                                  saturation: appearance.saturation)
    }

    private func handleCommand(_ command: StickyCommand) {
        switch command {
        case .inline(let style): editor.toggleInline(style)
        case .setFont(let key): note.fontKey = key
        case .bumpSize(let delta): note.textSize = min(24, max(10, note.textSize + Double(delta)))
        case .ink(let hex): editor.applyTextColor(hex)
        case .mark(let hex): editor.applyHighlight(hex)
        case .tint(let hex): note.tintHex = hex
        case .edge(let hex): note.edgeHex = hex
        case .glass(let value): note.tintStrength = value
        case .corner(let value): note.cornerRadius = value
        case .saturate(let value): note.saturation = value
        case .toggleWrap: note.wrapText.toggle()
        case .align(let value): note.textAlignment = value
        case .spacing(let value): note.lineSpacing = value
        case .padding(let value): note.textPadding = value
        case .toggleFit:
            note.fitToText.toggle()
            if note.fitToText {
                applyFit()
            } else {
                windowContext.clearFit()
            }
        case .togglePin:
            note.pinned.toggle()
            windowContext.setPinned(note.pinned)
        case .saveCopy:
            saveCopy()
        }
    }

    // MARK: Collapse — roll up to a bare bar (close dot + pin, no text;
    // the editor's 30pt top padding keeps the first line just out of view)

    private var collapsedHeight: CGFloat { 30 }

    /// Fit-to-text: window height hugs the content (36 = the editor's
    /// 30pt top + 6pt bottom padding).
    private func applyFit() {
        guard note.fitToText, !note.collapsed else { return }
        windowContext.setFitHeight(editor.contentHeight + 36)
    }

    private func toggleCollapse() {
        if note.collapsed {
            note.collapsed = false
            windowContext.setCollapsed(false, height: CGFloat(note.expandedHeight ?? 400))
            applyFit()
        } else {
            note.expandedHeight = Double(windowContext.window?.frame.height ?? 400)
            note.collapsed = true
            windowContext.setCollapsed(true, height: collapsedHeight)
        }
    }

    private var edgeBorder: some View {
        RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
            .strokeBorder(borderColor, lineWidth: borderWidth)
            .shadow(color: glowColor, radius: 9)
            .allowsHitTesting(false)
    }

    private var borderColor: Color {
        if dropTargeted { return appearance.accent.opacity(0.8) }
        if let edge = note.edgeHex { return Color(hex: edge).opacity(0.7) }
        return appearance.isDark ? .white.opacity(0.14) : .black.opacity(0.10)
    }

    private var borderWidth: CGFloat {
        if dropTargeted { return 2 }
        return note.edgeHex != nil ? 1.2 : 1
    }

    private var glowColor: Color {
        note.edgeHex.map { Color(hex: $0).opacity(0.45) } ?? .clear
    }

    // MARK: Floating controls (no header row — first line is the title)

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                DragStrip(onDoubleClick: toggleCollapse).frame(height: 26)
                HStack(spacing: 8) {
                    CloseButton(textColor: appearance.text, action: requestClose)
                    Spacer()
                }
                .padding(.horizontal, 11)
                .padding(.top, 9)
            }
            Spacer()
        }
    }

    // MARK: Link input (⌘K)

    private func openLinkInput() {
        linkText = ""
        withAnimation(.snappy) {
            showLinkInput = true
        }
        linkFieldFocused = true
    }

    private var linkInput: some View {
        VStack(spacing: 6) {
            TextField(editor.hasSelection ? "Link selection to URL" : "Paste or type a URL",
                      text: $linkText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .focused($linkFieldFocused)
                .frame(width: 200)
                .onSubmit {
                    if editor.applyWebLink(linkText) {
                        withAnimation(.snappy) { showLinkInput = false }
                    }
                }
                .onExitCommand { withAnimation(.snappy) { showLinkInput = false } }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 34)
        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link Folder"
        if panel.runModal() == .OK, let url = panel.url {
            editor.applyFolderLink(url)
        }
    }

    // MARK: Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let url = Self.url(from: item) else { return }
                    DispatchQueue.main.async { editor.insertDroppedURL(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    guard let url = Self.url(from: item) else { return }
                    DispatchQueue.main.async { editor.insertDroppedWebURL(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    let text: String? = switch item {
                    case let data as Data: String(data: data, encoding: .utf8)
                    case let string as String: string
                    default: nil
                    }
                    guard let text, !text.isEmpty else { return }
                    DispatchQueue.main.async { editor.insertDroppedText(text) }
                }
            }
        }
        return handled
    }

    private static func url(from item: NSSecureCoding?) -> URL? {
        switch item {
        case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
        case let url as URL: url
        case let string as String: URL(string: string)
        default: nil
        }
    }

    // MARK: Close flow — closing stashes; only empty notes are deleted

    private func requestClose() {
        if note.isEmpty {
            windowContext.close()
        } else {
            windowContext.stash()
        }
    }

    private func saveCopy() {
        let panel = NSSavePanel()
        let title = note.displayTitle
        panel.nameFieldStringValue = (title.isEmpty ? "Sticky" : title) + ".md"
        if let folder = note.firstFolderTarget {
            panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            try? note.markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Close button: a bare ×

struct CloseButton: View {
    let textColor: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(textColor.opacity(hovering ? 0.9 : 0.35))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close")
    }
}
