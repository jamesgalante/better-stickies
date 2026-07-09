import SwiftUI

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Hex for persistence (sRGB, no alpha). Used by the pickers.
    var hexString: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "FFFFFF" }
        return String(format: "%02X%02X%02X",
                      Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }

    static func luminance(hex: String) -> Double {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

// MARK: - Appearance: everything visual derives from the note's color + slider

struct Appearance: Equatable {
    var tintHex: String
    var strength: Double        // the slider: 0 = clear glass, 1 = opaque
    var edgeHex: String?
    var fontKey: String = "rounded"   // rounded | serif | mono | hand
    var textSize: Double = 13
    var cornerRadius: Double = 16
    /// false = long lines don't wrap; the note scrolls horizontally.
    var wrap: Bool = true
    /// Whole-note text alignment: left | center | right.
    var alignment: String = "left"
    /// Line spacing preset: tight | normal | roomy.
    var spacing: String = "normal"

    var nsTextAlignment: NSTextAlignment {
        switch alignment {
        case "center": .center
        case "right": .right
        default: .left
        }
    }

    /// (line spacing, paragraph spacing) for the preset.
    var spacingValues: (line: Double, paragraph: Double) {
        switch spacing {
        case "tight": (1, 0)
        case "roomy": (7, 5)
        default: (3, 2)
        }
    }

    var tint: Color { Color(hex: tintHex) }
    var isDark: Bool { Color.luminance(hex: tintHex) < 0.5 }
    var text: Color { isDark ? Color(hex: "F2F2F7") : Color(hex: "1E1E24") }
    var accent: Color { isDark ? Color(hex: "6FB6FF") : Color(hex: "0A84FF") }
    var linkBlue: Color { isDark ? Color(hex: "85C6FF") : Color(hex: "0A6DE0") }

    /// 0…0.3 on the slider fades the blur itself in, so the bottom of the
    /// range is nearly naked desktop. (Pre-macOS 26 pane only.)
    var blurAlpha: Double { min(1, max(0.1, strength / 0.3)) }

    /// macOS 26: how much the frost backdrop blurs (0…1, scaled to a blur
    /// radius). Ramps across the whole slider — bottom is sharp saturated
    /// glass, building to a fully frosted pane as the tint approaches
    /// opaque. The backdrop's saturation boost is constant.
    var frostAlpha: Double { strength }

    /// Above 0.3 the tint color builds from 0 to fully opaque.
    var tintOpacity: Double {
        strength <= 0.3 ? 0 : pow((strength - 0.3) / 0.7, 1.15)
    }

    var sheenStrength: Double {
        ((isDark ? 0.04 : 0.07) + 0.07 * (1 - tintOpacity)) * blurAlpha
    }

    /// True when properties that affect text rendering differ — slider
    /// moves shouldn't trigger a full editor restyle.
    func textStyleDiffers(from other: Appearance) -> Bool {
        isDark != other.isDark || fontKey != other.fontKey
            || textSize != other.textSize || alignment != other.alignment
            || spacing != other.spacing
    }

    /// The note's base font: a curated set that stays readable on glass.
    var baseNSFont: NSFont {
        let size = textSize
        switch fontKey {
        case "serif":
            let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) }
                ?? .systemFont(ofSize: size)
        case "mono":
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case "hand":
            return NSFont(name: "Bradley Hand", size: size)
                ?? NSFont(name: "Noteworthy", size: size)
                ?? NSFont(name: "Marker Felt", size: size)
                ?? .systemFont(ofSize: size)
        default:
            let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) }
                ?? .systemFont(ofSize: size)
        }
    }
}

// MARK: - Content model: lines of spans

enum LinkKind: String, Codable {
    case web, folder, file
}

/// A run of text within a line, optionally carrying a link and inline
/// styling. Flags encode only when set, so old notes decode cleanly and
/// the JSON stays lean.
struct Span: Codable, Equatable {
    var text: String
    var link: String? = nil
    var kind: LinkKind? = nil
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var strike: Bool = false
    /// Text color override (hex); nil follows the note's automatic color.
    var colorHex: String? = nil
    /// Highlighter behind the text (hex); nil means none.
    var highlightHex: String? = nil

    init(text: String, link: String? = nil, kind: LinkKind? = nil,
         bold: Bool = false, italic: Bool = false, underline: Bool = false,
         strike: Bool = false, colorHex: String? = nil, highlightHex: String? = nil) {
        self.text = text
        self.link = link
        self.kind = kind
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.colorHex = colorHex
        self.highlightHex = highlightHex
    }

    private enum CodingKeys: String, CodingKey {
        case text, link, kind, bold, italic, underline, strike, colorHex, highlightHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        link = try c.decodeIfPresent(String.self, forKey: .link)
        kind = try c.decodeIfPresent(LinkKind.self, forKey: .kind)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        strike = try c.decodeIfPresent(Bool.self, forKey: .strike) ?? false
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        highlightHex = try c.decodeIfPresent(String.self, forKey: .highlightHex)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(link, forKey: .link)
        try c.encodeIfPresent(kind, forKey: .kind)
        if bold { try c.encode(true, forKey: .bold) }
        if italic { try c.encode(true, forKey: .italic) }
        if underline { try c.encode(true, forKey: .underline) }
        if strike { try c.encode(true, forKey: .strike) }
        try c.encodeIfPresent(colorHex, forKey: .colorHex)
        try c.encodeIfPresent(highlightHex, forKey: .highlightHex)
    }
}

/// One paragraph. `todo` lines render with a leading checkbox.
struct Line: Codable, Equatable {
    var todo: Bool = false
    var done: Bool = false
    var spans: [Span] = [Span(text: "")]

    var plainText: String { spans.map(\.text).joined() }

    init(todo: Bool = false, done: Bool = false, spans: [Span] = [Span(text: "")]) {
        self.todo = todo
        self.done = done
        self.spans = spans
    }
}

extension Line {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todo = try c.decodeIfPresent(Bool.self, forKey: .todo) ?? false
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        spans = try c.decodeIfPresent([Span].self, forKey: .spans) ?? [Span(text: "")]
        if spans.isEmpty { spans = [Span(text: "")] }
    }
}

/// Helper for URL normalization and opening — shared by editor and drops.
enum LinkOpener {
    /// Accepts "github.com/foo" as well as full URLs.
    static func normalizeWeb(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    static func kind(forPath url: URL) -> LinkKind {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue ? .folder : .file
    }

    static func open(target: String, kind: LinkKind) {
        switch kind {
        case .web:
            if let url = URL(string: target) { NSWorkspace.shared.open(url) }
        case .folder:
            NSWorkspace.shared.open(URL(fileURLWithPath: target, isDirectory: true))
        case .file:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
        }
    }
}

// MARK: - Note

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Pane color — drives text color and light/dark automatically.
    var tintHex: String = "FFFFFF"
    /// The transparency slider: 0 = clear glass, 1 = opaque.
    var tintStrength: Double = 0.35
    /// Edge (border) color; nil means the default hairline.
    var edgeHex: String? = nil
    var pinned: Bool = false
    /// Base typeface and size for the whole note.
    var fontKey: String = "rounded"
    var textSize: Double = 13
    /// Pane corner rounding, in points.
    var cornerRadius: Double = 16
    /// Wrap long lines (true) or scroll horizontally (false).
    var wrapText: Bool = true
    /// Whole-note text alignment: left | center | right.
    var textAlignment: String = "left"
    /// Line spacing preset: tight | normal | roomy.
    var lineSpacing: String = "normal"
    /// Window height hugs the content (width stays user-controlled).
    var fitToText: Bool = false
    /// Stashed notes live in the library instead of on the desktop.
    var stashed: Bool = false
    /// Rolled up to just the title line; expandedHeight restores the window.
    var collapsed: Bool = false
    var expandedHeight: Double? = nil
    var lines: [Line] = [Line()]

    var appearance: Appearance {
        Appearance(tintHex: tintHex, strength: tintStrength, edgeHex: edgeHex,
                   fontKey: fontKey, textSize: textSize, cornerRadius: cornerRadius,
                   wrap: wrapText, alignment: textAlignment, spacing: lineSpacing)
    }

    /// The first non-empty line stands in for a title (save filename, etc.).
    var displayTitle: String {
        let first = lines.first { !$0.plainText.trimmingCharacters(in: .whitespaces).isEmpty }
        return String((first?.plainText ?? "").trimmingCharacters(in: .whitespaces).prefix(40))
    }

    var isEmpty: Bool {
        lines.allSatisfy { $0.plainText.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var markdown: String {
        var out: [String] = []
        for line in lines {
            var text = ""
            for span in line.spans {
                var t = span.text
                if span.bold && span.italic { t = "***\(t)***" }
                else if span.bold { t = "**\(t)**" }
                else if span.italic { t = "*\(t)*" }
                if span.strike { t = "~~\(t)~~" }
                if let link = span.link {
                    text += "[\(t)](\(link))"
                } else {
                    text += t
                }
            }
            // The editor renders bullets as "• "; markdown wants "- ".
            if !line.todo, text.hasPrefix("• ") {
                text = "- " + text.dropFirst(2)
            }
            out.append(line.todo ? "- [\(line.done ? "x" : " ")] \(text)" : text)
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// First folder link anywhere in the note, if any (used as save location).
    var firstFolderTarget: String? {
        for line in lines {
            for span in line.spans where span.kind == .folder {
                return span.link
            }
        }
        return nil
    }
}

extension Note {
    private enum CodingKeys: String, CodingKey {
        case id, version, tintHex, tintStrength, edgeHex, pinned, lines
        case fontKey, textSize, cornerRadius, wrapText, textAlignment, lineSpacing
        case fitToText, stashed, collapsed, expandedHeight
        case legacyTheme = "themeName"
        case legacyCustomTint = "customTintHex"
        case legacyTitle = "title"
        case legacyBlocks = "blocks"
        case legacyLinks = "links"
    }

    /// Tint colors of the retired theme presets, for migrating old notes.
    private static let legacyThemeTints: [String: String] = [
        "Glass": "FFFFFF", "Smoke": "1C1C22", "Tron": "041018",
        "Dracula": "2D2F3D", "Nord": "2E3440", "Tokyo": "1A1B26",
        "Mocha": "1E1E2E", "One Dark": "282C34", "Solarized": "FDF6E3",
    ]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        edgeHex = try c.decodeIfPresent(String.self, forKey: .edgeHex)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        fontKey = try c.decodeIfPresent(String.self, forKey: .fontKey) ?? "rounded"
        textSize = try c.decodeIfPresent(Double.self, forKey: .textSize) ?? 13
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 16
        wrapText = try c.decodeIfPresent(Bool.self, forKey: .wrapText) ?? true
        textAlignment = try c.decodeIfPresent(String.self, forKey: .textAlignment) ?? "left"
        lineSpacing = try c.decodeIfPresent(String.self, forKey: .lineSpacing) ?? "normal"
        fitToText = try c.decodeIfPresent(Bool.self, forKey: .fitToText) ?? false
        stashed = try c.decodeIfPresent(Bool.self, forKey: .stashed) ?? false
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        expandedHeight = try c.decodeIfPresent(Double.self, forKey: .expandedHeight)

        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let storedStrength = try c.decodeIfPresent(Double.self, forKey: .tintStrength) ?? 0.35

        if version >= 2 {
            tintHex = try c.decodeIfPresent(String.self, forKey: .tintHex) ?? "FFFFFF"
            tintStrength = storedStrength
        } else {
            // v1: themeName + optional custom tint; strength had different
            // semantics (multiplier on a small per-theme opacity), so land
            // migrated notes in the pleasant glassy middle of the new range.
            let themeName = try c.decodeIfPresent(String.self, forKey: .legacyTheme) ?? "Glass"
            let custom = try c.decodeIfPresent(String.self, forKey: .legacyCustomTint)
            tintHex = custom ?? Self.legacyThemeTints[themeName] ?? "FFFFFF"
            tintStrength = 0.3 + storedStrength * 0.25
        }

        if let lines = try c.decodeIfPresent([Line].self, forKey: .lines), !lines.isEmpty {
            self.lines = lines
        } else {
            // Migrate the old block/links shape.
            var built: [Line] = []
            if let blocks = try c.decodeIfPresent([OldBlock].self, forKey: .legacyBlocks) {
                built += blocks.map {
                    Line(todo: $0.kind == "todo", done: $0.done ?? false,
                         spans: [Span(text: $0.text ?? "")])
                }
            }
            if let links = try c.decodeIfPresent([OldLink].self, forKey: .legacyLinks),
               !links.isEmpty {
                var spans: [Span] = []
                for (i, link) in links.enumerated() {
                    let kind = LinkKind(rawValue: link.kind ?? "web") ?? .web
                    spans.append(Span(text: link.name ?? link.target ?? "link",
                                      link: link.target, kind: kind))
                    if i < links.count - 1 { spans.append(Span(text: "   ")) }
                }
                built.append(Line(spans: spans))
            }
            if let title = try c.decodeIfPresent(String.self, forKey: .legacyTitle),
               !title.isEmpty {
                built.insert(Line(spans: [Span(text: title)]), at: 0)
            }
            lines = built.isEmpty ? [Line()] : built
        }
    }

    private struct OldBlock: Decodable {
        var kind: String?
        var text: String?
        var done: Bool?
    }
    private struct OldLink: Decodable {
        var kind: String?
        var name: String?
        var target: String?
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(tintHex, forKey: .tintHex)
        try c.encode(tintStrength, forKey: .tintStrength)
        try c.encodeIfPresent(edgeHex, forKey: .edgeHex)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(fontKey, forKey: .fontKey)
        try c.encode(textSize, forKey: .textSize)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(wrapText, forKey: .wrapText)
        try c.encode(textAlignment, forKey: .textAlignment)
        try c.encode(lineSpacing, forKey: .lineSpacing)
        try c.encode(fitToText, forKey: .fitToText)
        try c.encode(stashed, forKey: .stashed)
        try c.encode(collapsed, forKey: .collapsed)
        try c.encodeIfPresent(expandedHeight, forKey: .expandedHeight)
        try c.encode(lines, forKey: .lines)
    }
}

// MARK: - Store

final class NotesStore: ObservableObject {
    @Published var notes: [Note] {
        didSet { scheduleSave() }
    }

    /// Bumped whenever notes are replaced because the file changed on disk
    /// (an external editor/agent wrote it). Views use this to reload open
    /// editors; the app delegate uses it to diff windows.
    @Published private(set) var externalReloadCount = 0

    private let fileURL: URL
    private var pendingSave: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    /// The bytes of our own last write (or initial read) — external events
    /// whose content matches are our own echoes and are ignored.
    private var lastWrittenData: Data?
    /// Per-note snapshot of what disk last agreed with. A note whose
    /// in-memory copy differs has unsaved local edits and wins merges.
    private var lastSyncedNotes: [UUID: Note] = [:]

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterStickies", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("notes.json")

        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Note].self, from: data),
           !saved.isEmpty {
            notes = saved
            lastWrittenData = data
        } else {
            notes = [Note()]
        }
        lastSyncedNotes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        startWatching()
    }

    deinit {
        watcher?.cancel()
    }

    @discardableResult
    func addNote() -> Note {
        let note = Note()
        notes.append(note)
        return note
    }

    func remove(id: UUID) {
        notes.removeAll { $0.id == id }
    }

    /// Writes are debounced so typing doesn't hit the disk on every keystroke.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeToDisk() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func flush() {
        pendingSave?.cancel()
        writeToDisk()
    }

    private func writeToDisk() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        lastWrittenData = data
        try? data.write(to: fileURL, options: .atomic)
        lastSyncedNotes = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
    }

    // MARK: External edits — other tools may rewrite notes.json

    /// Watch the DIRECTORY, not the file: atomic saves replace the file's
    /// inode, which kills a file-level watcher after one event. The
    /// directory descriptor survives any number of replacements.
    private func startWatching() {
        let fd = open(fileURL.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.diskMayHaveChanged() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func diskMayHaveChanged() {
        // Unreadable/partial states resolve themselves: the completed write
        // fires another directory event and we re-read then.
        guard let data = try? Data(contentsOf: fileURL),
              data != lastWrittenData,
              let incoming = try? JSONDecoder().decode([Note].self, from: data) else { return }
        lastWrittenData = data
        applyExternal(incoming)
    }

    /// Merge per note: notes without unsaved local edits take the external
    /// version; a note the user is mid-edit on keeps the local copy (the
    /// next debounced save re-asserts it). New external notes appear,
    /// externally-deleted notes vanish unless locally edited.
    private func applyExternal(_ incoming: [Note]) {
        var localByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        var merged: [Note] = []

        for external in incoming {
            if let local = localByID.removeValue(forKey: external.id) {
                let hasLocalEdits = lastSyncedNotes[external.id] != local
                merged.append(hasLocalEdits ? local : external)
            } else {
                merged.append(external)
            }
        }
        // Left over locally but gone from disk: keep only if locally edited.
        for (id, local) in localByID where lastSyncedNotes[id] != local {
            merged.append(local)
        }

        lastSyncedNotes = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        guard merged != notes else { return }
        notes = merged
        externalReloadCount += 1
    }
}
