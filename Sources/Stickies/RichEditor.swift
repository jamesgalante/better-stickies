import SwiftUI
import AppKit

// MARK: - Custom attributes

extension NSAttributedString.Key {
    /// Marks a range as one of our links and remembers what kind it is.
    static let stickyLinkKind = NSAttributedString.Key("stickies.linkKind")
    /// Inline styling. These custom keys are the source of truth — restyle()
    /// translates them into rendering attributes, so they survive theme and
    /// font changes and serialize cleanly back into spans.
    static let stickyBold = NSAttributedString.Key("stickies.bold")
    static let stickyItalic = NSAttributedString.Key("stickies.italic")
    static let stickyUnderline = NSAttributedString.Key("stickies.underline")
    static let stickyStrike = NSAttributedString.Key("stickies.strike")
    static let stickyColor = NSAttributedString.Key("stickies.color")
    static let stickyHighlight = NSAttributedString.Key("stickies.highlight")
}

/// The four toggleable inline styles.
enum InlineStyle {
    case bold, italic, underline, strike

    var key: NSAttributedString.Key {
        switch self {
        case .bold: .stickyBold
        case .italic: .stickyItalic
        case .underline: .stickyUnderline
        case .strike: .stickyStrike
        }
    }
}

/// The checkbox at the head of a checklist line. It's a character in the
/// text, so backspace deletes it like any other character.
final class CheckboxAttachment: NSTextAttachment {
    var done = false
}

// MARK: - Controller: the surface the rest of the app talks to

final class EditorController: ObservableObject {
    weak var textView: StickyTextView?

    var isEmpty: Bool {
        (textView?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func toggleChecklistLine() { textView?.toggleChecklistOnCurrentLine() }
    func applyWebLink(_ raw: String) -> Bool { textView?.applyWebLink(raw) ?? false }
    func applyFolderLink(_ url: URL) { textView?.applyPathLink(url) }
    func insertDroppedURL(_ url: URL) { textView?.insertPathLinkAtEnd(url) }
    func insertDroppedWebURL(_ url: URL) { textView?.insertWebLinkAtEnd(url) }
    func insertDroppedText(_ text: String) { textView?.insertPlainTextAtEnd(text) }
    func toggleInline(_ style: InlineStyle) { textView?.toggleInline(style) }
    func applyTextColor(_ hex: String?) { textView?.applyRunValue(hex, for: .stickyColor) }
    func applyHighlight(_ hex: String?) { textView?.applyRunValue(hex, for: .stickyHighlight) }
    var hasSelection: Bool { (textView?.selectedRange().length ?? 0) > 0 }
}

// MARK: - Text view

final class StickyTextView: NSTextView {
    var style = Appearance(tintHex: "FFFFFF", strength: 0.35, edgeHex: nil)
    var onContentChange: (() -> Void)?

    private var linkBlue: NSColor {
        NSColor(style.linkBlue)
    }

    private var baseFont: NSFont { style.baseNSFont }

    /// baseFont with bold/italic traits. Some designs lack an italic face
    /// (SF Rounded); fall back to a synthetic slant via obliqueness there.
    private func styledFont(bold: Bool, italic: Bool) -> (font: NSFont, syntheticItalic: Bool) {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        if let font = NSFont(descriptor: descriptor, size: style.textSize),
           !italic || NSFontManager.shared.traits(of: font).contains(.italicFontMask) {
            return (font, false)
        }
        // No italic face: use the bold-or-base face and slant it.
        let fallbackDescriptor = baseFont.fontDescriptor
            .withSymbolicTraits(bold ? [.bold] : [])
        let fallback = NSFont(descriptor: fallbackDescriptor, size: style.textSize) ?? baseFont
        return (fallback, italic)
    }

    // MARK: Checkbox glyphs

    private func checkboxImage(done: Bool) -> NSImage {
        let color = done ? NSColor(style.accent)
                         : NSColor(style.text).withAlphaComponent(0.4)
        let config = NSImage.SymbolConfiguration(pointSize: style.textSize, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let name = done ? "checkmark.circle.fill" : "circle"
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
    }

    private func checkboxString(done: Bool) -> NSAttributedString {
        let attachment = CheckboxAttachment()
        attachment.done = done
        attachment.image = checkboxImage(done: done)
        let edge = style.textSize + 2
        attachment.bounds = CGRect(x: 0, y: -3, width: edge, height: edge)
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: " "))
        result.addAttributes([.font: baseFont], range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: Building content from the model

    func load(lines: [Line]) {
        let content = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if line.todo {
                content.append(checkboxString(done: line.done))
            }
            for span in line.spans {
                var attrs: [NSAttributedString.Key: Any] = [:]
                if let link = span.link, let kind = span.kind {
                    attrs[.link] = linkURL(target: link, kind: kind)
                    attrs[.stickyLinkKind] = kind.rawValue
                }
                if span.bold { attrs[.stickyBold] = true }
                if span.italic { attrs[.stickyItalic] = true }
                if span.underline { attrs[.stickyUnderline] = true }
                if span.strike { attrs[.stickyStrike] = true }
                if let hex = span.colorHex { attrs[.stickyColor] = hex }
                if let hex = span.highlightHex { attrs[.stickyHighlight] = hex }
                content.append(NSAttributedString(string: span.text, attributes: attrs))
            }
            if index < lines.count - 1 {
                content.append(NSAttributedString(string: "\n"))
            }
        }
        textStorage?.setAttributedString(content)
        restyle()
    }

    private func linkURL(target: String, kind: LinkKind) -> URL {
        kind == .web ? (URL(string: target) ?? URL(fileURLWithPath: target))
                     : URL(fileURLWithPath: target)
    }

    // MARK: Serializing content back to the model

    func serialize() -> [Line] {
        guard let storage = textStorage else { return [Line()] }
        var lines: [Line] = []
        let text = storage.string as NSString

        var location = 0
        while location <= text.length {
            let paragraphRange = text.paragraphRange(for: NSRange(location: location, length: 0))
            var contentRange = paragraphRange
            // Trim the trailing newline out of the content range.
            if contentRange.length > 0,
               text.character(at: contentRange.upperBound - 1) == 10 {
                contentRange.length -= 1
            }

            var line = Line(spans: [])
            var spanStart = contentRange.location

            if contentRange.length > 0,
               let attachment = storage.attribute(.attachment, at: contentRange.location,
                                                  effectiveRange: nil) as? CheckboxAttachment {
                line.todo = true
                line.done = attachment.done
                spanStart += 1
                // Skip the space that follows the checkbox.
                if spanStart < contentRange.upperBound,
                   text.character(at: spanStart) == 32 {
                    spanStart += 1
                }
            }

            let spanRange = NSRange(location: spanStart,
                                    length: max(0, contentRange.upperBound - spanStart))
            storage.enumerateAttributes(in: spanRange) { attrs, range, _ in
                var span = Span(text: text.substring(with: range))
                if let kindRaw = attrs[.stickyLinkKind] as? String,
                   let kind = LinkKind(rawValue: kindRaw),
                   let url = attrs[.link] {
                    if let u = url as? URL {
                        span.link = kind == .web ? u.absoluteString : u.path
                    } else {
                        span.link = String(describing: url)
                    }
                    span.kind = kind
                }
                span.bold = attrs[.stickyBold] != nil
                span.italic = attrs[.stickyItalic] != nil
                span.underline = attrs[.stickyUnderline] != nil
                span.strike = attrs[.stickyStrike] != nil
                span.colorHex = attrs[.stickyColor] as? String
                span.highlightHex = attrs[.stickyHighlight] as? String
                line.spans.append(span)
            }
            if line.spans.isEmpty { line.spans = [Span(text: "")] }
            lines.append(line)

            if paragraphRange.upperBound == location { break }
            location = paragraphRange.upperBound
            if location == text.length,
               text.length > 0,
               text.character(at: text.length - 1) != 10 { break }
            if location >= text.length {
                // Trailing newline means one final empty paragraph.
                if text.length > 0 && text.character(at: text.length - 1) == 10 {
                    lines.append(Line())
                }
                break
            }
        }
        return lines.isEmpty ? [Line()] : lines
    }

    // MARK: Styling

    /// Re-applies all derived styling: base color/font, link colors,
    /// done-line dimming, checkbox tints. Called on load, theme change,
    /// and after structural edits.
    func restyle() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()

        storage.addAttributes([
            .font: baseFont,
            .foregroundColor: NSColor(style.text),
        ], range: full)
        storage.removeAttribute(.strikethroughStyle, range: full)
        storage.removeAttribute(.underlineStyle, range: full)
        storage.removeAttribute(.backgroundColor, range: full)
        storage.removeAttribute(.obliqueness, range: full)

        // Inline styling: translate the custom span keys into rendering
        // attributes. Runs before links so link color wins on link ranges.
        storage.enumerateAttributes(in: full) { attrs, range, _ in
            let bold = attrs[.stickyBold] != nil
            let italic = attrs[.stickyItalic] != nil
            if bold || italic {
                let (font, synthetic) = styledFont(bold: bold, italic: italic)
                storage.addAttribute(.font, value: font, range: range)
                if synthetic {
                    storage.addAttribute(.obliqueness, value: 0.18, range: range)
                }
            }
            if attrs[.stickyUnderline] != nil {
                storage.addAttribute(.underlineStyle,
                                     value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if attrs[.stickyStrike] != nil {
                storage.addAttribute(.strikethroughStyle,
                                     value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if let hex = attrs[.stickyColor] as? String {
                storage.addAttribute(.foregroundColor, value: NSColor(Color(hex: hex)), range: range)
            }
            if let hex = attrs[.stickyHighlight] as? String {
                storage.addAttribute(.backgroundColor,
                                     value: NSColor(Color(hex: hex)).withAlphaComponent(0.4),
                                     range: range)
            }
        }

        // Links: blue; filesystem links also underlined.
        storage.enumerateAttribute(.stickyLinkKind, in: full) { value, range, _ in
            guard let kindRaw = value as? String, let kind = LinkKind(rawValue: kindRaw) else { return }
            storage.addAttribute(.foregroundColor, value: linkBlue, range: range)
            if kind != .web {
                storage.addAttribute(.underlineStyle,
                                     value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }

        // Checklist lines: retint checkboxes; dim + strike the done ones.
        let text = storage.string as NSString
        var location = 0
        while location < text.length {
            let paragraphRange = text.paragraphRange(for: NSRange(location: location, length: 0))
            if let attachment = storage.attribute(.attachment, at: paragraphRange.location,
                                                  effectiveRange: nil) as? CheckboxAttachment {
                attachment.image = checkboxImage(done: attachment.done)
                if attachment.done {
                    var rest = paragraphRange
                    rest.location += 1
                    rest.length -= 1
                    if rest.length > 0 {
                        storage.addAttributes([
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: NSColor(style.text).withAlphaComponent(0.4),
                        ], range: rest)
                    }
                }
            }
            if paragraphRange.upperBound <= location { break }
            location = paragraphRange.upperBound
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 2
        storage.addAttribute(.paragraphStyle, value: paragraph, range: full)

        storage.endEditing()

        insertionPointColor = NSColor(style.accent)
        typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor(style.text),
            .paragraphStyle: paragraph,
        ]
        linkTextAttributes = [:]   // we style links ourselves
        layoutManager?.invalidateDisplay(forCharacterRange: full)
    }

    // MARK: Wrap vs horizontal scroll

    /// Wrap: lines break at the note's width (the default). No-wrap: lines
    /// run right and the note scrolls horizontally.
    func setWraps(_ wraps: Bool) {
        guard let container = textContainer, let scroll = enclosingScrollView else { return }
        let huge = CGFloat.greatestFiniteMagnitude
        if wraps {
            container.widthTracksTextView = true
            isHorizontallyResizable = false
            autoresizingMask = [.width]
            let width = scroll.contentSize.width
            container.size = NSSize(width: width, height: huge)
            setFrameSize(NSSize(width: width, height: frame.height))
        } else {
            container.widthTracksTextView = false
            isHorizontallyResizable = true
            autoresizingMask = []
            maxSize = NSSize(width: huge, height: huge)
            container.size = NSSize(width: huge, height: huge)
        }
        layoutManager?.ensureLayout(for: container)
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Inline styling

    /// ⌘B / ⌘I / ⌘U / ⇧⌘X — a bare AppKit app has no Font menu to route
    /// these, so handle them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            switch chars {
            case "b": toggleInline(.bold); return true
            case "i": toggleInline(.italic); return true
            case "u": toggleInline(.underline); return true
            default: break
            }
        }
        if flags == [.command, .shift], chars == "x" {
            toggleInline(.strike)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func toggleInline(_ inline: InlineStyle) {
        let key = inline.key
        let selection = selectedRange()

        if selection.length == 0 {
            // No selection: flip the style for text typed next.
            if typingAttributes[key] != nil {
                typingAttributes.removeValue(forKey: key)
            } else {
                typingAttributes[key] = true
            }
            return
        }

        guard let storage = textStorage else { return }
        // Standard toggle semantics: if the whole selection already has the
        // style, remove it; otherwise apply it everywhere.
        var allStyled = true
        storage.enumerateAttribute(key, in: selection) { value, _, stop in
            if value == nil { allStyled = false; stop.pointee = true }
        }
        guard shouldChangeText(in: selection, replacementString: nil) else { return }
        if allStyled {
            storage.removeAttribute(key, range: selection)
        } else {
            storage.addAttribute(key, value: true, range: selection)
        }
        didChangeText()
        restyle()
        onContentChange?()
    }

    /// Sets or clears (nil) a run-value style — text color or highlight —
    /// on the selection, or on upcoming typing when there's no selection.
    func applyRunValue(_ hex: String?, for key: NSAttributedString.Key) {
        let selection = selectedRange()

        if selection.length == 0 {
            if let hex {
                typingAttributes[key] = hex
            } else {
                typingAttributes.removeValue(forKey: key)
            }
            return
        }

        guard let storage = textStorage,
              shouldChangeText(in: selection, replacementString: nil) else { return }
        if let hex {
            storage.addAttribute(key, value: hex, range: selection)
        } else {
            storage.removeAttribute(key, range: selection)
        }
        didChangeText()
        restyle()
        onContentChange?()
    }

    // MARK: Markdown-ish autoformat

    private var autoformatting = false

    /// Small as-you-type conveniences, run after every user edit:
    ///   "- " / "* "  at line start → "• "
    ///   "[] " / "- [ ] " at line start → checkbox line
    ///   "**text**" → bold text   ·   "*text*" → italic text
    func autoformatAfterEdit() {
        guard !autoformatting,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true,
              let storage = textStorage else { return }
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0 else { return }
        let text = string as NSString
        guard selection.location <= text.length else { return }

        autoformatting = true
        defer { autoformatting = false }

        let caret = selection.location
        let lastChar = text.character(at: caret - 1)
        let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))

        if lastChar == 32 { // space: list shorthands, only at line start
            guard !paragraphHasCheckbox(paragraph) else { return }
            let prefixRange = NSRange(location: paragraph.location,
                                      length: caret - paragraph.location)
            let prefix = text.substring(with: prefixRange)

            if prefix == "[] " || prefix == "- [ ] " {
                let box = checkboxString(done: false)
                guard shouldChangeText(in: prefixRange, replacementString: box.string) else { return }
                storage.replaceCharacters(in: prefixRange, with: box)
                didChangeText()
                setSelectedRange(NSRange(location: paragraph.location + box.length, length: 0))
                restyle()
                onContentChange?()
            } else if prefix == "- " || prefix == "* " {
                guard shouldChangeText(in: prefixRange, replacementString: "• ") else { return }
                storage.replaceCharacters(in: prefixRange, with: "• ")
                didChangeText()
                setSelectedRange(NSRange(location: paragraph.location + 2, length: 0))
                restyle()
                onContentChange?()
            }
            return
        }

        if lastChar == 42 { // '*': emphasis shorthands ending at the caret
            let lineUpToCaret = text.substring(
                with: NSRange(location: paragraph.location, length: caret - paragraph.location))
            if let match = Self.firstMatch(of: "\\*\\*([^*\\n]+)\\*\\*$", in: lineUpToCaret) {
                unwrapEmphasis(match: match, markerLength: 2, key: .stickyBold,
                               paragraphStart: paragraph.location)
            } else if let match = Self.firstMatch(of: "(?<!\\*)\\*([^*\\n]+)\\*$", in: lineUpToCaret) {
                unwrapEmphasis(match: match, markerLength: 1, key: .stickyItalic,
                               paragraphStart: paragraph.location)
            }
        }
    }

    private static func firstMatch(of pattern: String, in text: String)
        -> (full: NSRange, inner: NSRange)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (match.range, match.range(at: 1))
    }

    /// Replaces "**text**" (relative ranges within the paragraph) with a
    /// styled "text" in one undoable edit.
    private func unwrapEmphasis(match: (full: NSRange, inner: NSRange), markerLength: Int,
                                key: NSAttributedString.Key, paragraphStart: Int) {
        guard let storage = textStorage else { return }
        let fullRange = NSRange(location: paragraphStart + match.full.location,
                                length: match.full.length)
        let innerText = (string as NSString).substring(
            with: NSRange(location: paragraphStart + match.inner.location,
                          length: match.inner.length))
        guard shouldChangeText(in: fullRange, replacementString: innerText) else { return }
        storage.replaceCharacters(in: fullRange,
                                  with: NSAttributedString(string: innerText, attributes: [key: true]))
        didChangeText()
        setSelectedRange(NSRange(location: fullRange.location + (innerText as NSString).length,
                                 length: 0))
        // Don't let the emphasis bleed into whatever is typed next.
        typingAttributes.removeValue(forKey: key)
        restyle()
        onContentChange?()
    }

    // MARK: Checkbox interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = attachmentIndex(at: point),
           let storage = textStorage,
           let attachment = storage.attribute(.attachment, at: index,
                                              effectiveRange: nil) as? CheckboxAttachment {
            attachment.done.toggle()
            restyle()
            onContentChange?()
            return
        }
        super.mouseDown(with: event)
    }

    private func attachmentIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let adjusted = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyphIndex = layoutManager.glyphIndex(for: adjusted, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length,
              storage.attribute(.attachment, at: charIndex, effectiveRange: nil) is CheckboxAttachment
        else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                                   in: textContainer)
        return glyphRect.insetBy(dx: -2, dy: -2).contains(adjusted) ? charIndex : nil
    }

    // MARK: Checklist editing

    private func paragraphRangeAtSelection() -> NSRange {
        let text = string as NSString
        let sel = selectedRange()
        return text.paragraphRange(for: NSRange(location: min(sel.location, text.length), length: 0))
    }

    private func paragraphHasCheckbox(_ range: NSRange) -> Bool {
        guard let storage = textStorage, range.location < storage.length else { return false }
        return storage.attribute(.attachment, at: range.location, effectiveRange: nil)
            is CheckboxAttachment
    }

    func toggleChecklistOnCurrentLine() {
        guard let storage = textStorage else { return }
        let paragraph = paragraphRangeAtSelection()

        if paragraphHasCheckbox(paragraph) {
            var removeRange = NSRange(location: paragraph.location, length: 1)
            let text = string as NSString
            if removeRange.upperBound < text.length,
               text.character(at: removeRange.upperBound) == 32 {
                removeRange.length += 1
            }
            if shouldChangeText(in: removeRange, replacementString: "") {
                storage.replaceCharacters(in: removeRange, with: "")
                didChangeText()
            }
        } else {
            let insert = checkboxString(done: false)
            if shouldChangeText(in: NSRange(location: paragraph.location, length: 0),
                                replacementString: insert.string) {
                storage.insert(insert, at: paragraph.location)
                didChangeText()
            }
        }
        restyle()
        onContentChange?()
    }

    // MARK: Links

    @discardableResult
    func applyWebLink(_ raw: String) -> Bool {
        guard let url = LinkOpener.normalizeWeb(raw) else { return false }
        applyLink(url: url, kind: .web, fallbackText: url.host ?? url.absoluteString)
        return true
    }

    func applyPathLink(_ fileURL: URL) {
        let kind = LinkOpener.kind(forPath: fileURL)
        applyLink(url: fileURL, kind: kind, fallbackText: fileURL.lastPathComponent)
    }

    /// Selected text becomes the link; with no selection the fallback text
    /// is inserted at the caret as the link.
    private func applyLink(url: URL, kind: LinkKind, fallbackText: String) {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        let attrs: [NSAttributedString.Key: Any] = [
            .link: url,
            .stickyLinkKind: kind.rawValue,
        ]

        if selection.length > 0 {
            if shouldChangeText(in: selection, replacementString: nil) {
                storage.addAttributes(attrs, range: selection)
                didChangeText()
            }
        } else {
            let insertion = NSAttributedString(string: fallbackText, attributes: attrs)
            insertText(insertion, replacementRange: selection)
        }
        restyle()
        onContentChange?()
    }

    // MARK: Dropped content

    func insertPathLinkAtEnd(_ url: URL) {
        moveCaretToEnd(newLineIfNeeded: true)
        applyPathLink(url)
    }

    func insertWebLinkAtEnd(_ url: URL) {
        moveCaretToEnd(newLineIfNeeded: true)
        applyLink(url: url, kind: .web, fallbackText: url.host ?? url.absoluteString)
    }

    func insertPlainTextAtEnd(_ text: String) {
        moveCaretToEnd(newLineIfNeeded: true)
        insertText(text, replacementRange: selectedRange())
        restyle()
        onContentChange?()
    }

    private func moveCaretToEnd(newLineIfNeeded: Bool) {
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: length, length: 0))
        if newLineIfNeeded && length > 0 {
            let text = string as NSString
            if text.character(at: length - 1) != 10 {
                insertText("\n", replacementRange: selectedRange())
            }
        }
    }
}

// MARK: - SwiftUI wrapper

struct RichEditor: NSViewRepresentable {
    let controller: EditorController
    let initialLines: [Line]
    let style: Appearance
    /// Bumped when notes.json changed on disk; tells the editor to reload
    /// its content from the model instead of trusting its own text.
    var reloadToken: Int = 0
    let onChange: ([Line]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.alphaValue = 0
        scroll.hasHorizontalScroller = true
        scroll.horizontalScroller?.alphaValue = 0
        scroll.autohidesScrollers = true
        // macOS 26 draws a prominent square focus ring around the scroll
        // view when the text view is first responder — ugly against the
        // sticky's rounded corners.
        scroll.focusRingType = .none

        let textView = StickyTextView()
        textView.focusRingType = .none
        textView.autoresizingMask = [.width]
        textView.isRichText = true
        // Keep the text view OUT of the shared Fonts/Colors panels: with
        // this on, every typing-attribute change pushes the text color into
        // NSColorPanel — whose action then rewrites the note's tint,
        // restyling the text, pushing to the panel again… an infinite
        // main-thread loop whenever the Custom… color panel is open.
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator

        textView.style = style
        textView.onContentChange = { [weak textView] in
            guard let textView else { return }
            context.coordinator.onChange(textView.serialize())
        }
        textView.load(lines: initialLines)

        scroll.documentView = textView
        controller.textView = textView
        context.coordinator.textView = textView
        context.coordinator.reloadToken = reloadToken
        context.coordinator.wraps = style.wrap
        if !style.wrap {
            textView.setWraps(false)
        }

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? StickyTextView else { return }
        if textView.style.textStyleDiffers(from: style) {
            textView.style = style
            textView.restyle()
        }
        if context.coordinator.wraps != style.wrap {
            context.coordinator.wraps = style.wrap
            textView.setWraps(style.wrap)
        }
        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            // Skip if this note wasn't the one that changed (or local edits
            // won the merge) — reloading resets the undo stack.
            if textView.serialize() != initialLines {
                let selection = textView.selectedRange()
                textView.load(lines: initialLines)
                let length = (textView.string as NSString).length
                textView.setSelectedRange(
                    NSRange(location: min(selection.location, length), length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: ([Line]) -> Void
        weak var textView: StickyTextView?
        var reloadToken = 0
        var wraps = true

        init(onChange: @escaping ([Line]) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            textView.autoformatAfterEdit()
            onChange(textView.serialize())
        }

        func textView(_ view: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            if url.isFileURL {
                let kindRaw = view.textStorage?.attribute(.stickyLinkKind, at: charIndex,
                                                          effectiveRange: nil) as? String
                let kind = LinkKind(rawValue: kindRaw ?? "") ?? LinkOpener.kind(forPath: url)
                LinkOpener.open(target: url.path, kind: kind)
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}
