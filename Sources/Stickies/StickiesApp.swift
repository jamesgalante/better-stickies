import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    /// Posted by the ⌘W menu item; the key sticky runs its close flow.
    static let stickyCloseRequested = Notification.Name("BetterStickies.closeRequested")
    /// Menu-bar commands; the key sticky applies them (userInfo["command"]).
    static let stickyEditorCommand = Notification.Name("BetterStickies.editorCommand")
}

/// Everything the menu bar can ask the key sticky to do.
enum StickyCommand {
    case inline(InlineStyle)
    case setFont(String)
    case bumpSize(Int)
    case ink(String?)
    case mark(String?)
    case tint(String)
    case edge(String?)
    case glass(Double)
    case corner(Double)
    case togglePin
    case saveCopy
}

// Plain AppKit lifecycle instead of SwiftUI's WindowGroup: SwiftUI insists on
// drawing its own opaque window background, which kills the glass effect, and
// it fights custom sizing. Owning the NSWindow gives us full control.
@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let store = NotesStore()
    private var windows: [UUID: NSWindow] = [:]
    private var cascadePoint = NSPoint.zero
    /// The Note-menu items hosting the Glass and Corners sliders. Their
    /// views are rebuilt on every menu open — NSMenu re-hosts custom item
    /// views across open/close cycles and stale layouts render garbled.
    private weak var glassSliderItem: NSMenuItem?
    private weak var cornerSliderItem: NSMenuItem?
    private var libraryWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = makeMenu()

        for note in store.notes where !note.stashed {
            openWindow(for: note, cascade: false)
        }
        // Everything stashed? Come up showing the library instead.
        if windows.isEmpty {
            showLibrary()
        }

        // External edits to notes.json can add, delete, stash, or unstash
        // notes — keep the set of windows in step.
        store.$externalReloadCount
            .dropFirst()
            .sink { [weak self] _ in self?.syncWindowsWithStore() }
            .store(in: &cancellables)

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reconcile open windows with the store after an external reload.
    private func syncWindowsWithStore() {
        for (id, window) in windows {
            let note = store.notes.first { $0.id == id }
            if note == nil || note?.stashed == true {
                windows[id] = nil
                window.close()
            }
        }
        for note in store.notes where !note.stashed && windows[note.id] == nil {
            openWindow(for: note, cascade: true)
        }
    }

    // Closing the last sticky stashes it — the app stays alive so the
    // library (and ⌘N) remain reachable from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Windows

    @objc func newSticky() {
        let note = store.addNote()
        openWindow(for: note, cascade: true)
    }

    @objc func requestCloseKeySticky() {
        if let libraryWindow, NSApp.keyWindow == libraryWindow {
            libraryWindow.close()
            return
        }
        NotificationCenter.default.post(name: .stickyCloseRequested, object: nil)
    }

    @objc func toggleChecklist() {
        NotificationCenter.default.post(name: .stickyToggleChecklist, object: nil)
    }

    @objc func addLink() {
        NotificationCenter.default.post(name: .stickyAddLink, object: nil)
    }

    @objc func linkFolder() {
        NotificationCenter.default.post(name: .stickyLinkFolder, object: nil)
    }

    // MARK: Menu actions

    private func post(_ command: StickyCommand) {
        NotificationCenter.default.post(name: .stickyEditorCommand, object: nil,
                                        userInfo: ["command": command])
    }

    @objc func saveCopy() { post(.saveCopy) }

    // MARK: Library

    @objc func showLibrary() {
        if let libraryWindow {
            libraryWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = LibraryView(
            isOpen: { [weak self] id in self?.windows[id] != nil },
            openNote: { [weak self] id in self?.openFromLibrary(id) },
            deleteNote: { [weak self] id in self?.deleteNote(id) }
        ).environmentObject(store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Library"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.setFrameAutosaveName("library")
        libraryWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func openFromLibrary(_ id: UUID) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let index = store.notes.firstIndex(where: { $0.id == id }) else { return }
        store.notes[index].stashed = false
        openWindow(for: store.notes[index], cascade: true)
    }

    private func deleteNote(_ id: UUID) {
        windows[id]?.close()
        windows[id] = nil
        store.remove(id: id)
    }

    @objc func toggleBold() { post(.inline(.bold)) }
    @objc func toggleItalic() { post(.inline(.italic)) }
    @objc func toggleUnderline() { post(.inline(.underline)) }
    @objc func toggleStrike() { post(.inline(.strike)) }
    @objc func biggerText() { post(.bumpSize(1)) }
    @objc func smallerText() { post(.bumpSize(-1)) }
    @objc func toggleFloat() { post(.togglePin) }

    @objc func setFont(_ sender: NSMenuItem) {
        post(.setFont(sender.representedObject as? String ?? "rounded"))
    }

    @objc func setInk(_ sender: NSMenuItem) {
        post(.ink(sender.representedObject as? String))
    }

    @objc func setMark(_ sender: NSMenuItem) {
        post(.mark(sender.representedObject as? String))
    }

    @objc func setTint(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        post(.tint(hex))
    }

    @objc func setEdge(_ sender: NSMenuItem) {
        post(.edge(sender.representedObject as? String))
    }

    @objc private func glassChanged(_ sender: NSSlider) {
        post(.glass(sender.doubleValue))
    }

    @objc private func cornerChanged(_ sender: NSSlider) {
        post(.corner(sender.doubleValue))
    }

    // MARK: Custom colors via the system color panel
    //
    // The color panel steals key status from the sticky, so notification
    // routing ("apply to the key sticky") breaks while it's open. Instead,
    // remember which note was key when the panel opened and write to the
    // store directly.

    private enum ColorPanelTarget { case tint, edge }
    private var colorPanelTarget = ColorPanelTarget.tint
    private var colorPanelNoteID: UUID?

    @objc func customTint() { openColorPanel(.tint, current: keyNote()?.tintHex ?? "FFFFFF") }
    @objc func customEdge() { openColorPanel(.edge, current: keyNote()?.edgeHex ?? "FFFFFF") }

    private func openColorPanel(_ target: ColorPanelTarget, current: String) {
        guard let note = keyNote() else { return }
        colorPanelTarget = target
        colorPanelNoteID = note.id
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelDidPick(_:)))
        panel.isContinuous = true
        panel.showsAlpha = false
        panel.color = NSColor(Color(hex: current))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelDidPick(_ sender: NSColorPanel) {
        // Belt and suspenders against feedback: only visible-panel picks
        // count, and echoes of the current value are ignored (anything in
        // AppKit that programmatically nudges the shared panel would
        // otherwise bounce straight back into the note).
        guard sender.isVisible,
              let id = colorPanelNoteID,
              let index = store.notes.firstIndex(where: { $0.id == id }) else { return }
        let hex = Color(nsColor: sender.color).hexString
        switch colorPanelTarget {
        case .tint:
            guard store.notes[index].tintHex != hex else { return }
            store.notes[index].tintHex = hex
        case .edge:
            guard store.notes[index].edgeHex != hex else { return }
            store.notes[index].edgeHex = hex
        }
    }

    // MARK: Menu state

    /// The note belonging to the key window, for menu checkmarks.
    private func keyNote() -> Note? {
        guard let keyWindow = NSApp.keyWindow,
              let id = windows.first(where: { $0.value == keyWindow })?.key else { return nil }
        return store.notes.first { $0.id == id }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let current = keyNote()
        switch menuItem.action {
        case #selector(setFont(_:)):
            menuItem.state = (menuItem.representedObject as? String) == (current?.fontKey ?? "rounded")
                ? .on : .off
        case #selector(setTint(_:)):
            menuItem.state = (menuItem.representedObject as? String) == current?.tintHex ? .on : .off
        case #selector(setEdge(_:)):
            menuItem.state = (menuItem.representedObject as? String) == current?.edgeHex ? .on : .off
        case #selector(toggleFloat):
            menuItem.state = current?.pinned == true ? .on : .off
        default:
            break
        }
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu.title == "Note" else { return }
        let note = keyNote()
        glassSliderItem?.view = makeSliderView(
            label: "Glass", min: 0, max: 1,
            value: note?.tintStrength ?? 0.35, enabled: note != nil,
            action: #selector(glassChanged(_:)))
        cornerSliderItem?.view = makeSliderView(
            label: "Corners", min: 4, max: 28,
            value: note?.cornerRadius ?? 16, enabled: note != nil,
            action: #selector(cornerChanged(_:)))
    }

    private func openWindow(for note: Note, cascade: Bool) {
        let noteID = note.id
        let context = WindowContext()
        let content = StickyView(noteID: noteID)
            .environmentObject(store)
            .environmentObject(context)

        let window = WindowFactory.makeSticky(
            content: content,
            autosaveName: "sticky-\(noteID.uuidString)",
            context: context
        )
        context.window = window
        context.onClose = { [weak self, weak window] in
            self?.store.remove(id: noteID)
            self?.windows[noteID] = nil
            window?.close()
        }
        context.onStash = { [weak self, weak window] in
            guard let self else { return }
            if let index = store.notes.firstIndex(where: { $0.id == noteID }) {
                store.notes[index].stashed = true
            }
            windows[noteID] = nil
            window?.close()
        }

        if note.pinned { window.level = .floating }
        if cascade {
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }

        windows[noteID] = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu

    /// Minimal main menu so standard shortcuts (⌘N/W, ⌘C/V/X/A/Z, ⌘Q) keep
    /// working — without a menu, a bare AppKit app has no key equivalents.
    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Stickies",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Stickies",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let newItem = NSMenuItem(title: "New Sticky",
                                 action: #selector(newSticky), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        let closeItem = NSMenuItem(title: "Close Sticky",
                                   action: #selector(requestCloseKeySticky), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)
        fileMenu.addItem(.separator())
        let saveCopyItem = NSMenuItem(title: "Save a Copy…",
                                      action: #selector(saveCopy), keyEquivalent: "s")
        saveCopyItem.target = self
        fileMenu.addItem(saveCopyItem)
        let libraryItem = NSMenuItem(title: "Library",
                                     action: #selector(showLibrary), keyEquivalent: "l")
        libraryItem.keyEquivalentModifierMask = [.command, .shift]
        libraryItem.target = self
        fileMenu.addItem(libraryItem)
        fileItem.submenu = fileMenu

        // Note menu: the sticky's appearance, so the sticky itself stays bare.
        let noteItem = NSMenuItem()
        main.addItem(noteItem)
        let noteMenu = NSMenu(title: "Note")
        noteMenu.delegate = self

        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu(title: "Color")
        for (name, hex) in [("White", "FFFFFF"), ("Charcoal", "1C1C22"), ("Yellow", "FFE066"),
                            ("Mint", "8CE99A"), ("Sky", "74C0FC"), ("Rose", "FFA8A8"),
                            ("Lavender", "B197FC")] {
            let item = NSMenuItem(title: name, action: #selector(setTint(_:)), keyEquivalent: "")
            item.representedObject = hex
            item.image = Self.swatch(hex)
            item.target = self
            colorMenu.addItem(item)
        }
        colorMenu.addItem(.separator())
        let customTintItem = NSMenuItem(title: "Custom…", action: #selector(customTint),
                                        keyEquivalent: "")
        customTintItem.target = self
        colorMenu.addItem(customTintItem)
        colorItem.submenu = colorMenu
        noteMenu.addItem(colorItem)

        let edgeItem = NSMenuItem(title: "Edge", action: nil, keyEquivalent: "")
        let edgeMenu = NSMenu(title: "Edge")
        let edgeOff = NSMenuItem(title: "None", action: #selector(setEdge(_:)), keyEquivalent: "")
        edgeOff.target = self
        edgeMenu.addItem(edgeOff)
        edgeMenu.addItem(.separator())
        for (name, hex) in [("White", "FFFFFF"), ("Gold", "FFD60A"), ("Cyan", "00E5FF"),
                            ("Magenta", "FF2D95"), ("Lime", "B4FF39")] {
            let item = NSMenuItem(title: name, action: #selector(setEdge(_:)), keyEquivalent: "")
            item.representedObject = hex
            item.image = Self.swatch(hex)
            item.target = self
            edgeMenu.addItem(item)
        }
        edgeMenu.addItem(.separator())
        let customEdgeItem = NSMenuItem(title: "Custom…", action: #selector(customEdge),
                                        keyEquivalent: "")
        customEdgeItem.target = self
        edgeMenu.addItem(customEdgeItem)
        edgeItem.submenu = edgeMenu
        noteMenu.addItem(edgeItem)

        noteMenu.addItem(.separator())
        let glassItem = NSMenuItem()
        glassItem.view = makeSliderView(label: "Glass", min: 0, max: 1, value: 0.35,
                                        enabled: true, action: #selector(glassChanged(_:)))
        glassSliderItem = glassItem
        noteMenu.addItem(glassItem)
        let cornerItem = NSMenuItem()
        cornerItem.view = makeSliderView(label: "Corners", min: 4, max: 28, value: 16,
                                         enabled: true, action: #selector(cornerChanged(_:)))
        cornerSliderItem = cornerItem
        noteMenu.addItem(cornerItem)
        noteMenu.addItem(.separator())

        let floatItem = NSMenuItem(title: "Float on Top", action: #selector(toggleFloat),
                                   keyEquivalent: "f")
        floatItem.keyEquivalentModifierMask = [.command, .shift]
        floatItem.target = self
        noteMenu.addItem(floatItem)
        noteItem.submenu = noteMenu

        let formatItem = NSMenuItem()
        main.addItem(formatItem)
        let formatMenu = NSMenu(title: "Format")

        func command(_ title: String, _ action: Selector, _ key: String,
                     _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            return item
        }

        formatMenu.addItem(command("Bold", #selector(toggleBold), "b"))
        formatMenu.addItem(command("Italic", #selector(toggleItalic), "i"))
        formatMenu.addItem(command("Underline", #selector(toggleUnderline), "u"))
        formatMenu.addItem(command("Strikethrough", #selector(toggleStrike), "x",
                                   [.command, .shift]))
        formatMenu.addItem(.separator())

        let fontItem = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        let fontMenu = NSMenu(title: "Font")
        for (name, key) in [("Round", "rounded"), ("Serif", "serif"),
                            ("Mono", "mono"), ("Hand", "hand")] {
            let item = NSMenuItem(title: name, action: #selector(setFont(_:)), keyEquivalent: "")
            item.representedObject = key
            item.target = self
            fontMenu.addItem(item)
        }
        fontItem.submenu = fontMenu
        formatMenu.addItem(fontItem)
        formatMenu.addItem(command("Bigger Text", #selector(biggerText), "+"))
        formatMenu.addItem(command("Smaller Text", #selector(smallerText), "-"))
        formatMenu.addItem(.separator())

        let inkItem = NSMenuItem(title: "Text Color", action: nil, keyEquivalent: "")
        let inkMenu = NSMenu(title: "Text Color")
        let autoInk = NSMenuItem(title: "Automatic", action: #selector(setInk(_:)), keyEquivalent: "")
        autoInk.target = self
        inkMenu.addItem(autoInk)
        inkMenu.addItem(.separator())
        for (name, hex) in [("Red", "E5484D"), ("Orange", "E88C30"), ("Green", "2F9E44"),
                            ("Blue", "0A84FF"), ("Purple", "9B5DE5")] {
            let item = NSMenuItem(title: name, action: #selector(setInk(_:)), keyEquivalent: "")
            item.representedObject = hex
            item.image = Self.swatch(hex)
            item.target = self
            inkMenu.addItem(item)
        }
        inkItem.submenu = inkMenu
        formatMenu.addItem(inkItem)

        let markItem = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
        let markMenu = NSMenu(title: "Highlight")
        let noMark = NSMenuItem(title: "None", action: #selector(setMark(_:)), keyEquivalent: "")
        noMark.target = self
        markMenu.addItem(noMark)
        markMenu.addItem(.separator())
        for (name, hex) in [("Yellow", "FFE066"), ("Green", "8CE99A"),
                            ("Blue", "74C0FC"), ("Pink", "FFA8A8")] {
            let item = NSMenuItem(title: name, action: #selector(setMark(_:)), keyEquivalent: "")
            item.representedObject = hex
            item.image = Self.swatch(hex)
            item.target = self
            markMenu.addItem(item)
        }
        markItem.submenu = markMenu
        formatMenu.addItem(markItem)

        formatMenu.addItem(.separator())
        formatMenu.addItem(command("Checklist Line", #selector(toggleChecklist), "l"))
        formatMenu.addItem(command("Add Link…", #selector(addLink), "k"))
        formatMenu.addItem(command("Link Folder…", #selector(linkFolder), ""))
        formatItem.submenu = formatMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        return main
    }

    /// Small color circle for color-picking menu items.
    private static func swatch(_ hex: String) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(Color(hex: hex)).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// A live slider row for the Note menu, like the volume slider in the
    /// sound menu. Built fresh per menu open; the label sizes to fit.
    private func makeSliderView(label: String, min: Double, max: Double, value: Double,
                                enabled: Bool, action: Selector) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .menuFont(ofSize: 13)
        labelField.sizeToFit()
        labelField.setFrameOrigin(NSPoint(x: 21, y: (26 - labelField.frame.height) / 2))
        container.addSubview(labelField)

        let slider = NSSlider(value: value, minValue: min, maxValue: max,
                              target: self, action: action)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.isEnabled = enabled
        slider.frame = NSRect(x: 82, y: 4, width: 140, height: 18)
        container.addSubview(slider)
        return container
    }
}
