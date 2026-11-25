import MoshTerminal
import SwiftTerm
import UIKit

/// What the app needs from the view that draws the terminal. SwiftTerm stays
/// behind this protocol: this is the only app file that imports it.
protocol TerminalSurface: AnyObject {
    var view: UIView { get }
    /// Bytes the user produced (keys, paste, mouse reports).
    var onInput: (([UInt8]) -> Void)? { get set }
    /// The view's size in cells changed.
    var onSizeChange: ((_ columns: Int, _ rows: Int) -> Void)? { get set }
    var columns: Int { get }
    var rows: Int { get }
    /// Shows a mosh framebuffer (docs/PLAN.md, Design 2, "Drawing"): the bytes from
    /// `SurfaceFeed` that take the view from the last framebuffer shown to this one.
    /// Returns false, and feeds nothing, when the framebuffer's size is not the
    /// view's (between a resize and the server's answer to it).
    @discardableResult
    func show(_ framebuffer: MoshTerminal.Framebuffer) -> Bool
    /// Raw bytes for the screen. Only for a surface that never shows a framebuffer
    /// (the placeholder's echo): the surface feed assumes nobody else writes.
    func feed(_ bytes: [UInt8])
    /// The visible rows as text, trailing spaces trimmed.
    func visibleText() -> [String]
    func focus()

    // MARK: Key bar and paste (docs/PLAN.md section 5, M7)

    /// Stops the view's own input accessory (SwiftTerm's `TerminalAccessory`): the app's
    /// `KeyBarView` replaces it.
    func removeBuiltInAccessory()
    /// Sends one key the way the terminal view itself encodes it (cursor keys follow the
    /// view's cursor-key mode; `SurfaceFeed` keeps it in application mode, and mosh-server
    /// translates for the remote program).
    func sendKey(_ key: TerminalKey)
    /// Text as if typed: the sticky modifiers apply to it.
    func typeText(_ text: String)
    /// A paste: the view removes ESC and other control bytes and adds bracketed-paste markers
    /// when the remote program asked for them (the mode comes with the framebuffer).
    func paste(_ text: String)
    /// Sticky Ctrl and Alt. The view clears them after the next typed key and then calls
    /// `onModifiersChange`.
    var controlModifier: Bool { get set }
    var metaModifier: Bool { get set }
    var onModifiersChange: (() -> Void)? { get set }
    func dismissKeyboard()

    // MARK: Appearance (docs/PLAN.md section 5, M7)

    /// The font size in points (the bundled `TerminalFont` faces). A change recomputes the view's
    /// columns and rows (`onSizeChange` follows) and repaints the screen in full.
    var fontSize: CGFloat { get set }

    // MARK: Appearance (docs/PLAN.md section 5, M8)

    /// The theme's palette and default colours, and the cursor style. A theme without its own
    /// colours (`TerminalTheme.system`) leaves the view's own as they are. Applied before the
    /// first screen is shown. mosh carries no cursor style from the host (its framebuffer has
    /// none), so the style stays as set here.
    func apply(_ appearance: TerminalAppearance)
    /// The colour the view paints behind its cells, as drawn (resolved, sRGB), or nil when it
    /// paints none (the view behind it shows through). The bars over the terminal take it.
    func drawnBackground() -> RGB?
    /// UI tests: the view's own colours, font and cursor as it reports them,
    /// `background=#RRGGBB foreground=#RRGGBB font=<regular>,<bold>,<italic>,<bold italic>@<size>
    /// cursor=<SwiftTerm tag name>` (font faces by PostScript name).
    func appearanceDescription() -> String
}

/// Keys of the key bar that are not plain text.
enum TerminalKey: Equatable {
    case escape, tab
    case up, down, left, right
    case home, end, pageUp, pageDown
    /// Raw bytes with no encoding of their own (the tmux prefix, a control byte).
    case bytes([UInt8])
}

final class SwiftTermSurface: NSObject, TerminalSurface, TerminalViewDelegate {
    private let terminalView: TerminalView
    /// The feed for this view's terminal; one per SwiftTerm terminal (SurfaceFeed's rule).
    private var surfaceFeed = SurfaceFeed()

    var onInput: (([UInt8]) -> Void)?
    var onSizeChange: ((_ columns: Int, _ rows: Int) -> Void)?

    override init() {
        // glibc, and so mosh-server's layout, counts a regional indicator as one column.
        // SurfaceFeed assumes SwiftTerm does the same (SurfaceFeed.swift, header).
        let options = TerminalOptions(regionalIndicatorWidth: .narrow)
        terminalView = TerminalView(frame: .zero, options: options)
        super.init()
        terminalView.terminalDelegate = self
        // mosh carries no scrollback. SwiftTerm's own would fill with partial frames
        // and reflow them on resize.
        terminalView.changeScrollback(nil)
        terminalView.accessibilityIdentifier = "terminal"
        setFaces(size: terminalView.font.pointSize)
        for name in [Notification.Name.terminalViewControlModifierReset, .terminalViewMetaModifierReset] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(modifierReset), name: name, object: terminalView)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var view: UIView { terminalView }
    // SwiftTerm 1.99 no longer hands out its Terminal. The view offers copied reads.
    var columns: Int { terminalView.terminalDimensions.cols }
    var rows: Int { terminalView.terminalDimensions.rows }

    @discardableResult
    func show(_ framebuffer: MoshTerminal.Framebuffer) -> Bool {
        let dimensions = terminalView.terminalDimensions
        guard framebuffer.ds.width == dimensions.cols, framebuffer.ds.height == dimensions.rows else {
            return false
        }
        let bytes = surfaceFeed.feed(to: framebuffer)
        if !bytes.isEmpty {
            terminalView.feed(byteArray: bytes[...])
        }
        return true
    }

    func feed(_ bytes: [UInt8]) {
        terminalView.feed(byteArray: bytes[...])
    }

    func visibleText() -> [String] {
        terminalView.visibleRowsText(0..<rows).map { row in
            var text = Substring(row)
            while text.last == " " { text.removeLast() }
            return String(text)
        }
    }

    func focus() {
        _ = terminalView.becomeFirstResponder()
    }

    // MARK: Key bar and paste

    var onModifiersChange: (() -> Void)?

    func removeBuiltInAccessory() {
        terminalView.inputAccessoryView = nil
        if terminalView.isFirstResponder { terminalView.reloadInputViews() }
    }

    func sendKey(_ key: TerminalKey) {
        switch key {
        case .escape: terminalView.send(EscapeSequences.cmdEsc)
        case .tab: terminalView.send(EscapeSequences.cmdTab)
        case .up: terminalView.sendKeyUp()
        case .down: terminalView.sendKeyDown()
        case .left: terminalView.sendKeyLeft()
        case .right: terminalView.sendKeyRight()
        case .home: terminalView.sendKeyHome()
        case .end: terminalView.sendKeyEnd()
        case .pageUp: terminalView.send(EscapeSequences.cmdPageUp)
        case .pageDown: terminalView.send(EscapeSequences.cmdPageDown)
        case .bytes(let bytes): terminalView.send(bytes)
        }
    }

    func typeText(_ text: String) {
        terminalView.insertText(text)
    }

    func paste(_ text: String) {
        terminalView.pasteText(text)
    }

    var controlModifier: Bool {
        get { terminalView.controlModifier }
        set { terminalView.controlModifier = newValue }
    }

    var metaModifier: Bool {
        get { terminalView.metaModifier }
        set { terminalView.metaModifier = newValue }
    }

    @objc private func modifierReset() {
        onModifiersChange?()
    }

    func dismissKeyboard() {
        _ = terminalView.resignFirstResponder()
    }

    // MARK: Appearance

    /// The faces last given to the view (SwiftTerm keeps bold and italic to itself).
    private var faces: TerminalFont.Faces?

    var fontSize: CGFloat {
        get { terminalView.font.pointSize }
        set {
            guard newValue != terminalView.font.pointSize else { return }
            setFaces(size: newValue)
        }
    }

    /// The bundled regular, bold, italic and bold italic faces at `size`. SwiftTerm's `setFonts`
    /// recomputes the grid from the regular face and calls `sizeChanged` (below), which
    /// invalidates the feed: the next screen is a full repaint, modes included. (Its `font`
    /// setter would derive bold and italic from the regular face instead of using the real ones.)
    private func setFaces(size: CGFloat) {
        let faces = TerminalFont.faces(size: size)
        self.faces = faces
        terminalView.setFonts(normal: faces.normal, bold: faces.bold, italic: faces.italic,
                              boldItalic: faces.boldItalic)
    }

    func apply(_ appearance: TerminalAppearance) {
        let theme = appearance.theme
        if let palette = theme.palette, palette.count == 16 {
            terminalView.installColors(palette.map {
                Color(red8: UInt16($0.red), green8: UInt16($0.green), blue8: UInt16($0.blue))
            })
        }
        if let foreground = theme.foreground { terminalView.nativeForegroundColor = UIColor(foreground) }
        if let background = theme.background { terminalView.nativeBackgroundColor = UIColor(background) }
        terminalView.setCursorStyle(Self.cursorStyle(appearance.cursorShape, blinks: appearance.cursorBlinks))
    }

    nonisolated static func cursorStyle(_ shape: CursorShape, blinks: Bool) -> CursorStyle {
        switch shape {
        case .block: return blinks ? .blinkBlock : .steadyBlock
        case .underline: return blinks ? .blinkUnderline : .steadyUnderline
        case .bar: return blinks ? .blinkBar : .steadyBar
        }
    }

    /// SwiftTerm paints the terminal's default background as its layer's background colour (a
    /// theme's background; for System what SwiftTerm set up itself, which the simulator showed
    /// black in light and dark mode) and draws default-background cells transparent over it.
    func drawnBackground() -> RGB? {
        guard let color = terminalView.layer.backgroundColor, color.alpha > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let srgb = color.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = srgb.components, parts.count >= 3 else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return RGB(byte(parts[0]) << 16 | byte(parts[1]) << 8 | byte(parts[2]))
    }

    func appearanceDescription() -> String {
        let traits = terminalView.traitCollection
        let background = Self.hex(terminalView.nativeBackgroundColor.resolvedColor(with: traits))
        let foreground = Self.hex(terminalView.nativeForegroundColor.resolvedColor(with: traits))
        let cursor = terminalView.terminalStateSnapshot().cursorStyle.tagName
        // The regular face as the view reports it; the other three as they were given to it.
        let drawn = terminalView.font
        let others = faces.map { [$0.bold, $0.italic, $0.boldItalic].map(\.fontName) } ?? ["?", "?", "?"]
        let font = ([drawn.fontName] + others).joined(separator: ",") + "@\(Int(drawn.pointSize.rounded()))"
        return "background=\(background) foreground=\(foreground) font=\(font) cursor=\(cursor)"
    }

    private static func hex(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "?" }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm has resized its own buffer: its screen is no longer what was fed.
        // The next show() is a reset, clear and full repaint. The surface never calls
        // resize(cols:rows:), softReset() or resetToInitialState() (they reset the
        // cursor-key mode).
        surfaceFeed.invalidate()
        onSizeChange?(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    // The remote must not reach the iOS clipboard through SwiftTerm. Clipboard
    // writes go through ClipboardPolicy, from the mosh framebuffer.
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
}

extension RGB {
    /// A UIColor as it resolves now, 8 bits per channel (black when it has no RGB form).
    init(_ color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        _ = color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        self.init(byte(red) << 16 | byte(green) << 8 | byte(blue))
    }
}

extension UIColor {
    convenience init(_ rgb: RGB) {
        self.init(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }
}
