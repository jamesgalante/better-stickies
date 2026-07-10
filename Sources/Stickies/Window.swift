import SwiftUI
import AppKit
import os

/// Pre-macOS 26 fallback pane: behind-window blur.
///
/// On macOS 26+ the sticky gets real Liquid Glass instead, but NOT via this
/// view: NSGlassEffectView only guarantees the effect (edge refraction, rim
/// highlight) for views placed inside its `contentView` — as a sibling layer
/// underneath SwiftUI content it renders as flat frost. So WindowFactory
/// makes the glass view the window's content view and nests the SwiftUI
/// hosting view inside it; this fallback is skipped entirely there.
struct GlassBackground: NSViewRepresentable {
    var isDark: Bool
    /// Fades the frost itself: at the bottom of the transparency slider the
    /// blur washes out and the naked desktop shows through.
    var alpha: Double = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        view.alphaValue = alpha
    }
}

/// The frost pane stripped down to its optics. NSVisualEffectView's material
/// is a recipe of [backdrop layer: blur + saturation filters] + [fill/tone
/// wash layers]. The washes are the fog that keeps the pane from ever being
/// truly clear — hide them, keep the backdrop, and drive its filters
/// directly: a constant saturation boost (the vivid look of the system
/// Display HUD) and a blur radius the transparency slider controls. AppKit
/// resets the filters whenever it rebuilds the material (e.g. appearance
/// flips), so re-apply after every updateLayer.
final class SaturatingFrostView: NSVisualEffectView {
    private static let log = Logger(subsystem: "com.jamesgalante.better-stickies",
                                    category: "frost-watchdog")

    var blurRadius: Double = 0 { didSet { applyOptics() } }
    var saturation: Double = 1.6 { didSet { applyOptics() } }
    /// Rounds the material via a regenerated maskImage (layer cornerRadius
    /// doesn't survive NSVisualEffectView's layer management).
    var cornerRadius: Double = 16 {
        didSet {
            guard cornerRadius != oldValue else { return }
            maskImage = .roundedCornerMask(radius: cornerRadius)
        }
    }

    private var watchdog: Timer?

    deinit {
        watchdog?.invalidate()
    }

    override func updateLayer() {
        super.updateLayer()
        applyOptics()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyOptics()

        // AppKit restores the stock material through paths we can't all
        // hook (some only fire for on-screen windows). Audit once a second:
        // log what deviated — so the real trigger can be identified from
        // `log show` — and re-apply the optics.
        watchdog?.invalidate()
        watchdog = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.auditAndHeal()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Resizes (e.g. the collapse animation) rebuild the material through
    /// layout, not updateLayer — without this the stock frosted recipe
    /// silently returns after the first window resize.
    override func layout() {
        super.layout()
        applyOptics()
    }

    private func auditAndHeal() {
        guard let root = layer else { return }
        var deviations: [String] = []
        func audit(_ layer: CALayer) {
            if String(describing: type(of: layer)).contains("Backdrop") {
                if let scale = layer.value(forKey: "scale") as? Double, scale != 1.0 {
                    deviations.append("scale=\(scale)")
                }
                for filter in layer.filters ?? [] {
                    let obj = filter as AnyObject
                    let name = (obj.value(forKey: "name") as? String)?.lowercased() ?? ""
                    if name.contains("blur"),
                       let radius = obj.value(forKey: "inputRadius") as? Double,
                       abs(radius - blurRadius) > 0.01 {
                        deviations.append("blur=\(radius) want=\(blurRadius)")
                    }
                }
            } else if layer.backgroundColor != nil, !layer.isHidden {
                deviations.append("wash=\(String(describing: type(of: layer)))(\(layer.name ?? "-"))")
            }
            layer.sublayers?.forEach(audit)
        }
        audit(root)

        // Sibling Liquid Glass state, for the log only.
        if #available(macOS 26.0, *),
           let glass = superview?.subviews.first(where: { $0 is NSGlassEffectView }) {
            let style = (glass.value(forKey: "style") as? Int) ?? -1
            let subdued = (glass.value(forKey: "_subduedState") as? Int) ?? -1
            let scrim = (glass.value(forKey: "_scrimState") as? Int) ?? -1
            if style != 1 { deviations.append("glassStyle=\(style)") }
            if subdued != 0 { deviations.append("glassSubdued=\(subdued)") }
            if scrim != 0 { deviations.append("glassScrim=\(scrim)") }
        }

        guard !deviations.isEmpty else { return }
        Self.log.log("healing: \(deviations.joined(separator: " "), privacy: .public)")
        applyOptics()
        if #available(macOS 26.0, *),
           let glass = superview?.subviews.first(where: { $0 is NSGlassEffectView })
               as? NSGlassEffectView,
           glass.style != .clear {
            glass.style = .clear
        }
    }

    private func applyOptics() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tune(root)
        CATransaction.commit()
    }

    private func tune(_ layer: CALayer) {
        if String(describing: type(of: layer)).contains("Backdrop") {
            // CRITICAL: never mutate attached filter objects. Core
            // Animation diffs by object identity — mutating in place and
            // reassigning the same array commits NO change, so the window
            // server keeps rendering the OLD values while the app-side
            // objects read back the new ones (an invisible client/server
            // desync: blur looked 0 here, rendered 30 on screen). Copy
            // each filter, set values on the copy, assign a fresh array.
            if let filters = layer.filters, !filters.isEmpty {
                layer.filters = filters.map { filter -> Any in
                    guard let copy = (filter as? NSObject)?.copy() as? NSObject else { return filter }
                    let name = (copy.value(forKey: "name") as? String)?.lowercased() ?? ""
                    if name.contains("blur") { copy.setValue(blurRadius, forKey: "inputRadius") }
                    if name.contains("saturate") { copy.setValue(saturation, forKey: "inputAmount") }
                    return copy
                }
            }
            // Materials sample the backdrop at 1/8 resolution — invisible
            // under heavy blur, but a soft translucent smear at blur 0.
            // Sticky-sized panes can afford full-resolution sampling.
            layer.setValue(1.0, forKey: "scale")
        } else if layer.backgroundColor != nil {
            // fill / tone / desktop-tint washes: the fog.
            layer.isHidden = true
        }
        layer.sublayers?.forEach(tune)
    }
}

extension NSImage {
    /// A stretchable rounded-rect mask for NSVisualEffectView.maskImage:
    /// the cap insets keep the corners crisp at any view size.
    static func roundedCornerMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius,
                                       bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Invisible strip at the top of the sticky: grab it to move the window,
/// double-click it to roll the note up to its title line.
/// (The text view underneath owns clicks everywhere else.)
struct DragStrip: NSViewRepresentable {
    var onDoubleClick: () -> Void = {}

    final class DragView: NSView {
        var onDoubleClick: () -> Void = {}

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick()
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DragView)?.onDoubleClick = onDoubleClick
    }
}

/// Borderless windows refuse key status by default, which would make the
/// text view dead. Override to accept it.
final class StickyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Liquid Glass (and other materials) may PULL the window's "key
    // appearance" when re-rendering rather than being told about changes.
    // These private queries have no public equivalents; answering yes
    // unconditionally keeps every sticky rendering its active look. Safe
    // shadowing: if a future macOS renames them, ours just never get called.
    @objc(hasKeyAppearance) private var alwaysKeyAppearance: Bool { true }
    @objc(_hasKeyAppearance) private var alwaysKeyAppearanceInternal: Bool { true }
    @objc(_hasActiveAppearance) private var alwaysActiveAppearance: Bool { true }
}

/// Per-window handle passed into the SwiftUI content so views can close
/// their own window or change its level without knowing about AppKit.
final class WindowContext: ObservableObject {
    weak var window: NSWindow?
    /// The window-level Liquid Glass pane (macOS 26+, nil before).
    weak var glassView: NSView?
    /// The frost pane under the glass (macOS 26+): a behind-window backdrop
    /// that saturates the desktop imagery and blurs it as the slider rises.
    weak var frostView: SaturatingFrostView?
    /// Deletes the note and closes the window (empty notes).
    var onClose: (() -> Void)?
    /// Moves the note to the library and closes the window.
    var onStash: (() -> Void)?

    var isKey: Bool { window?.isKeyWindow ?? false }

    func close() { onClose?() }
    func stash() { onStash?() }

    func setPinned(_ pinned: Bool) {
        window?.level = pinned ? .floating : .normal
    }

    /// Fit-to-text: pin the window height to the content's natural height
    /// (top edge fixed, growing downward). Width stays free — min/max
    /// clamp only the vertical axis, so edge-drags resize width and the
    /// reflowed height re-pins live.
    ///
    /// Reentrancy-gated AND never pinned while moving. Two hard-won rules:
    /// - setFrame posts didResizeNotification synchronously and the fit
    ///   logic listens to it — the gate stops self-recursion.
    /// - The glass view pins its contentView with Auto Layout, making the
    ///   window constraint-driven; holding contentMin==contentMax at the
    ///   target while calling setFrame makes the constraint engine and the
    ///   size limits fight *inside* the call and never return. So: unpin,
    ///   move, and re-pin at whatever height actually settled, a runloop
    ///   later.
    private var fitting = false

    func setFitHeight(_ height: CGFloat) {
        guard let window, !fitting else { return }
        fitting = true

        let cap = window.screen?.visibleFrame.height ?? 1000
        let clamped = min(max(height, 60), cap)
        let unbounded = CGFloat.greatestFiniteMagnitude
        window.contentMinSize = NSSize(width: 150, height: 60)
        window.contentMaxSize = NSSize(width: unbounded, height: unbounded)
        var frame = window.frame
        if abs(frame.height - clamped) > 0.5 {
            frame.origin.y += frame.height - clamped
            frame.size.height = clamped
            window.setFrame(frame, display: true)
        }
        DispatchQueue.main.async { [weak self] in
            defer { self?.fitting = false }
            guard let window = self?.window else { return }
            let settled = window.frame.height
            window.contentMinSize = NSSize(width: 150, height: settled)
            window.contentMaxSize = NSSize(width: unbounded, height: settled)
        }
    }

    /// Back to free-form sizing.
    func clearFit() {
        guard let window else { return }
        let unbounded = CGFloat.greatestFiniteMagnitude
        window.contentMinSize = NSSize(width: 150, height: 120)
        window.contentMaxSize = NSSize(width: unbounded, height: unbounded)
    }

    /// Rolls the window up to the title line (keeping the top edge fixed)
    /// or restores it to the given height. Min/max sizes pin the height
    /// while collapsed so edge-resizing only changes the width.
    func setCollapsed(_ collapsed: Bool, height: CGFloat) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        let unbounded = CGFloat.greatestFiniteMagnitude
        if collapsed {
            window.contentMinSize = NSSize(width: 150, height: height)
            window.contentMaxSize = NSSize(width: unbounded, height: height)
        } else {
            window.contentMinSize = NSSize(width: 150, height: 120)
            window.contentMaxSize = NSSize(width: unbounded, height: unbounded)
        }
        window.setFrame(frame, display: true, animate: true)
    }

    /// Keeps the panes in step with the note: appearance follows the tint's
    /// light/dark side, the transparency slider drives the frost's BLUR
    /// only — never the glass or content, so text stays crisp and the
    /// saturation boost survives all the way down to "clear" — and both
    /// panes round to the note's corner radius.
    func updateGlass(isDark: Bool, frost: Double, radius: Double, saturation: Double) {
        let look = NSAppearance(named: isDark ? .darkAqua : .aqua)
        glassView?.appearance = look
        frostView?.appearance = look
        frostView?.blurRadius = frost * 30
        frostView?.saturation = saturation
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView,
           glass.cornerRadius != radius {
            glass.cornerRadius = radius
        }
        frostView?.cornerRadius = radius
    }
}

/// Liquid Glass flips to a milky "subdued" look whenever its window stops
/// being key. NSVisualEffectView has `.state = .active` to opt out of
/// exactly this; NSGlassEffectView has no public equivalent, so this
/// subclass closes every app-side path to the dimmed look:
///  - _windowChangedKeyState (push) forwards only while the window is key,
///  - set_subduedState:/set_scrimState: (the content-legibility veil) are
///    pinned to 0,
///  - StickyWindow additionally answers the key-appearance queries (pull)
///    with a permanent yes — that pull path is the one the glass actually
///    re-derives its look from.
/// All selectors are private; if a future macOS renames them the overrides
/// go quiet and unfocused stickies merely fade — nothing crashes.
@available(macOS 26.0, *)
private final class LivelyGlassView: NSGlassEffectView {
    @objc(_windowChangedKeyState)
    func windowChangedKeyState() {
        guard window?.isKeyWindow == true else { return }
        forwardVoid("_windowChangedKeyState")
    }

    @objc(set_subduedState:)
    func setSubduedState(_ state: Int) {
        forwardInt("set_subduedState:", 0)
    }

    @objc(set_scrimState:)
    func setScrimState(_ state: Int) {
        forwardInt("set_scrimState:", 0)
    }

    private func forwardVoid(_ name: String) {
        let sel = NSSelectorFromString(name)
        guard let m = class_getInstanceMethod(NSGlassEffectView.self, sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method_getImplementation(m), to: F.self)(self, sel)
    }

    private func forwardInt(_ name: String, _ value: Int) {
        let sel = NSSelectorFromString(name)
        guard let m = class_getInstanceMethod(NSGlassEffectView.self, sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(method_getImplementation(m), to: F.self)(self, sel, value)
    }
}

enum WindowFactory {
    static func makeSticky(content: some View, autosaveName: String,
                           context: WindowContext) -> NSWindow {
        let window = StickyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let hosting = NSHostingView(rootView: content)
        // Don't let SwiftUI's ideal size constrain the window — the user
        // should be able to drag it to any size.
        hosting.sizingOptions = []
        hosting.focusRingType = .none

        if #available(macOS 26.0, *) {
            // Real Liquid Glass, two panes deep. The glass only bends
            // content that lives INSIDE the window — it can't sample other
            // windows or the desktop behind it (verified: content behind
            // the window stays pixel-sharp through a bare glass pane). So
            // a behind-window blur sits underneath, pulling the desktop
            // imagery into the window for the glass to refract, and the
            // SwiftUI content nests in the glass's contentView — the only
            // placement guaranteed the full effect (rim light, refraction).
            let container = NSView()

            let frost = SaturatingFrostView()
            frost.blendingMode = .behindWindow
            frost.state = .active
            frost.material = .hudWindow
            // Round via maskImage — a layer cornerRadius doesn't survive
            // NSVisualEffectView's layer management, and the un-rounded
            // material pokes out past the glass corners as square edges.
            frost.maskImage = .roundedCornerMask(radius: 16)
            frost.autoresizingMask = [.width, .height]

            let glass = LivelyGlassView()
            glass.cornerRadius = 16
            // .regular glass carries its own smoky, semi-frosted body, so
            // the bottom of the transparency slider could never reach
            // "clear". .clear keeps the refractive edge treatment but lets
            // the pane body go fully transparent; frost + tint layered on
            // top provide all the opacity the slider asks for.
            glass.style = .clear
            glass.focusRingType = .none
            glass.contentView = hosting

            container.addSubview(frost)
            container.addSubview(glass)
            window.contentView = container
            frost.frame = container.bounds
            glass.frame = container.bounds
            glass.autoresizingMask = [.width, .height]

            context.glassView = glass
            context.frostView = frost
        } else {
            window.contentView = hosting
        }

        // AppKit's default (release on close) sends an extra release to a
        // window ARC already owns; the close animation's autorelease pool
        // then drains a freed object and segfaults.
        window.isReleasedWhenClosed = false

        window.isOpaque = false
        window.backgroundColor = .clear
        if #available(macOS 26.0, *) {
            // A transparent window's shadow traces the window's SQUARE
            // surface region, not the rounded glass — it shows up as a
            // hard hairline corner whenever the window is key. The glass
            // rim already defines the edge, so drop the shadow entirely.
            window.hasShadow = false
        } else {
            window.hasShadow = true
        }
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 150, height: 120)
        window.center()
        // Remember position and size across launches, per sticky.
        window.setFrameAutosaveName(autosaveName)
        return window
    }
}
