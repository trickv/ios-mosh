import GameController
import UIKit

/// The key bar (docs/PLAN.md section 5, M7), pinned to the keyboard layout guide's top by the
/// terminal screen. It replaces SwiftTerm's own `TerminalAccessory`.
///
/// - Fixed part: Esc, Ctrl (sticky), Tab, four arrows with repeat, Paste (a `UIPasteControl`,
///   kept fully visible, so a paste needs no iOS prompt).
/// - Scrolling part: Alt (sticky), `| / ~ - _`, PgUp, PgDn, Home, End, the tmux prefix
///   (default `C-b`), hide keyboard.
/// - Bytes come from the terminal view (`TerminalSurface.sendKey`), which encodes cursor keys
///   by its cursor-key mode. The app writes no escape sequence of its own.
/// - With a hardware keyboard (`GCKeyboard.coalesced`) the bar collapses to one "Keys" button
///   that opens it again.
final class KeyBarView: UIView {
    static let keyWidth: CGFloat = 40
    static let height: CGFloat = 40

    private weak var surface: TerminalSurface?
    private let pasteController = PasteController()
    private let fixedStack = UIStackView()
    private let scrollView = UIScrollView()
    private let scrollStack = UIStackView()
    private let expandButton = UIButton(type: .system)
    private var ctrlButton: UIButton!
    private var altButton: UIButton!

    /// Bytes of the tmux prefix key.
    var tmuxPrefix: [UInt8] = KeyBarView.configuredTmuxPrefix()

    private var repeatTimer: Timer?
    private var repeatKey: TerminalKey?

    private var hardwareKeyboard = false
    /// The user opened the collapsed bar while a hardware keyboard is connected.
    private var expandedByUser = false

    init(surface: TerminalSurface) {
        self.surface = surface
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.12, alpha: 1)
        accessibilityIdentifier = "keyBar"
        build()
        pasteController.onPaste = { [weak self] text in
            self?.surface?.paste(text)
        }
        surface.onModifiersChange = { [weak self] in self?.refreshModifiers() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardsChanged), name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardsChanged), name: .GCKeyboardDidDisconnect, object: nil)
        keyboardsChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        repeatTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: Layout

    private func build() {
        for stack in [fixedStack, scrollStack] {
            stack.axis = .horizontal
            stack.spacing = 3
            stack.alignment = .fill
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        fixedStack.addArrangedSubview(key("Esc", "esc") { $0.surface?.sendKey(.escape) })
        ctrlButton = key("Ctrl", "ctrl") { $0.toggleControl() }
        fixedStack.addArrangedSubview(ctrlButton)
        fixedStack.addArrangedSubview(key("Tab", "tab") { $0.surface?.sendKey(.tab) })
        for (symbol, name, key) in [("arrow.left", "left", TerminalKey.left), ("arrow.up", "up", .up),
                                    ("arrow.down", "down", .down), ("arrow.right", "right", .right)] {
            fixedStack.addArrangedSubview(repeatingKey(symbol: symbol, name: name, key: key))
        }
        fixedStack.addArrangedSubview(makePasteControl())

        altButton = key("Alt", "alt") { $0.toggleMeta() }
        scrollStack.addArrangedSubview(altButton)
        for (text, name) in [("|", "pipe"), ("/", "slash"), ("~", "tilde"), ("-", "dash"), ("_", "underscore")] {
            scrollStack.addArrangedSubview(key(text, name) { $0.surface?.typeText(text) })
        }
        scrollStack.addArrangedSubview(key("PgUp", "pageUp") { $0.surface?.sendKey(.pageUp) })
        scrollStack.addArrangedSubview(key("PgDn", "pageDown") { $0.surface?.sendKey(.pageDown) })
        scrollStack.addArrangedSubview(key("Home", "home") { $0.surface?.sendKey(.home) })
        scrollStack.addArrangedSubview(key("End", "end") { $0.surface?.sendKey(.end) })
        scrollStack.addArrangedSubview(key(Self.label(forPrefix: tmuxPrefix), "tmuxPrefix") {
            $0.surface?.sendKey(.bytes($0.tmuxPrefix))
        })
        let hide = key(symbol: "keyboard.chevron.compact.down", "hideKeyboard") { $0.surface?.dismissKeyboard() }
        hide.accessibilityLabel = "Hide Keyboard"
        scrollStack.addArrangedSubview(hide)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.accessibilityIdentifier = "keyBar.scroll"
        if UITestSupport.isUITesting { scrollView.delegate = self }
        scrollView.addSubview(scrollStack)

        expandButton.setTitle("Keys", for: .normal)
        expandButton.accessibilityIdentifier = "keyBar.expand"
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.addAction(UIAction { [weak self] _ in self?.expandByUser() }, for: .touchUpInside)
        expandButton.isHidden = true

        addSubview(fixedStack)
        addSubview(scrollView)
        addSubview(expandButton)
        NSLayoutConstraint.activate([
            fixedStack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 3),
            fixedStack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            fixedStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            scrollView.leadingAnchor.constraint(equalTo: fixedStack.trailingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -3),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            scrollStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            scrollStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            scrollStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            scrollStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            scrollStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            expandButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func styled(_ button: UIButton, name: String) -> UIButton {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = UIColor(white: 0.3, alpha: 1)
        button.layer.cornerRadius = 5
        button.tintColor = .white
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(.black, for: .selected)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        button.accessibilityIdentifier = "keyBar.\(name)"
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.keyWidth).isActive = true
        logTouchesForUITests(button, name: name)
        return button
    }

    /// UI-test launches only: every touch event of a key and every drag of the scrolling part
    /// goes to the debug log, so a failed key-bar test shows which key fired and when. Key
    /// names are input, so this is never on outside UI tests (DebugLog: no typed input).
    private func logTouchesForUITests(_ button: UIButton, name: String) {
        guard UITestSupport.isUITesting else { return }
        let events: [(UIControl.Event, String)] = [
            (.touchDown, "down"), (.touchUpInside, "up-inside"), (.touchUpOutside, "up-outside"),
            (.touchCancel, "cancel"),
        ]
        for (event, text) in events {
            button.addAction(UIAction { [weak self] _ in
                DebugLog.shared.log("keyBar: \(name) \(text) (scroll x \(Int(self?.scrollView.contentOffset.x ?? -1)))")
            }, for: event)
        }
    }

    private func key(_ title: String, _ name: String, action: @escaping (KeyBarView) -> Void) -> UIButton {
        let button = styled(UIButton(type: .custom), name: name)
        button.setTitle(title, for: .normal)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            action(self)
        }, for: .touchUpInside)
        return button
    }

    private func key(symbol: String, _ name: String, action: @escaping (KeyBarView) -> Void) -> UIButton {
        let button = key("", name, action: action)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        return button
    }

    /// An arrow: sends on touch down, then repeats after 0.5 s every 0.1 s while held.
    private func repeatingKey(symbol: String, name: String, key: TerminalKey) -> UIButton {
        let button = styled(UIButton(type: .custom), name: name)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = name.capitalized
        button.addAction(UIAction { [weak self] _ in self?.startRepeat(key) }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            button.addAction(UIAction { [weak self] _ in self?.stopRepeat() }, for: event)
        }
        return button
    }

    private func makePasteControl() -> UIView {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = UIColor(white: 0.3, alpha: 1)
        configuration.baseForegroundColor = .white
        let control = UIPasteControl(configuration: configuration)
        control.target = pasteController
        control.translatesAutoresizingMaskIntoConstraints = false
        control.accessibilityIdentifier = "keyBar.paste"
        control.widthAnchor.constraint(equalToConstant: Self.keyWidth).isActive = true
        return control
    }

    // MARK: Keys

    private func startRepeat(_ key: TerminalKey) {
        stopRepeat()
        surface?.sendKey(key)
        repeatKey = key
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let key = self.repeatKey else { return }
                self.surface?.sendKey(key)
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatKey = nil
    }

    private func toggleControl() {
        guard let surface else { return }
        surface.controlModifier.toggle()
        refreshModifiers()
    }

    private func toggleMeta() {
        guard let surface else { return }
        surface.metaModifier.toggle()
        refreshModifiers()
    }

    /// Shows Ctrl and Alt as set or not; called also when the view cleared them after a key.
    private func refreshModifiers() {
        for (button, on) in [(ctrlButton, surface?.controlModifier ?? false),
                             (altButton, surface?.metaModifier ?? false)] {
            guard let button else { continue }
            button.isSelected = on
            button.backgroundColor = on ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.3, alpha: 1)
            button.accessibilityValue = on ? "on" : "off"
        }
    }

    // MARK: Hardware keyboard

    @objc private func keyboardsChanged() {
        let connected = Self.hardwareKeyboardConnected()
        if connected != hardwareKeyboard { expandedByUser = false }
        hardwareKeyboard = connected
        applyCollapse()
    }

    private func expandByUser() {
        expandedByUser = true
        applyCollapse()
    }

    private func applyCollapse() {
        let collapsed = hardwareKeyboard && !expandedByUser
        fixedStack.isHidden = collapsed
        scrollView.isHidden = collapsed
        expandButton.isHidden = !collapsed
        refreshModifiers()
    }

    static func hardwareKeyboardConnected() -> Bool {
        #if DEBUG
        // UI tests fix the answer, so the bar does not depend on the simulator's settings.
        if UITestSupport.isUITesting, let forced = UserDefaults.standard.string(forKey: "uiTestingHardwareKeyboard") {
            return forced == "1"
        }
        #endif
        return GCKeyboard.coalesced != nil
    }

    // MARK: tmux prefix

    /// The prefix from the setting `keyBarTmuxPrefix` (`C-b` style), `C-b` when unset or invalid.
    static func configuredTmuxPrefix() -> [UInt8] {
        UserDefaults.standard.string(forKey: "keyBarTmuxPrefix").flatMap(prefixBytes) ?? [0x02]
    }

    /// `C-x` (a letter or one of `@[\]^_ `) as its control byte; nil for anything else.
    static func prefixBytes(_ text: String) -> [UInt8]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 3, trimmed.lowercased().hasPrefix("c-"),
              let scalar = trimmed.unicodeScalars.last, scalar.isASCII else { return nil }
        let value = UInt8(scalar.value)
        switch value {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return [value - 0x60]
        case UInt8(ascii: "@")...UInt8(ascii: "_"): return [value - 0x40]
        case UInt8(ascii: " "): return [0]
        default: return nil
        }
    }

    static func label(forPrefix bytes: [UInt8]) -> String {
        guard bytes.count == 1, bytes[0] < 0x20 else { return "Prefix" }
        return "^" + String(UnicodeScalar(bytes[0] + 0x40))
    }
}

extension KeyBarView: UIScrollViewDelegate {
    // Set as the delegate in UI-test launches only (`logTouchesForUITests`).
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        DebugLog.shared.log("keyBar: scroll drag begins at x \(Int(scrollView.contentOffset.x))")
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        DebugLog.shared.log("keyBar: scroll drag ends at x \(Int(scrollView.contentOffset.x)), decelerate \(decelerate)")
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        DebugLog.shared.log("keyBar: scroll stops at x \(Int(scrollView.contentOffset.x))")
    }
}

/// The target of the Paste key (docs/PLAN.md section 5, "Paste"). `UIPasteControl` hands it
/// the pasteboard's text without the iOS paste prompt; the text goes to the terminal view's
/// paste (bracketed when the remote program asked for it).
final class PasteController: UIResponder {
    var onPaste: ((String) -> Void)?

    override init() {
        super.init()
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains { $0.canLoadObject(ofClass: NSString.self) }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let text = object as? String, !text.isEmpty else { return }
            DispatchQueue.main.async { self?.onPaste?(text) }
        }
    }
}
