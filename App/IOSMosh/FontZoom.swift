import UIKit

/// The terminal's font size on an open terminal screen (docs/PLAN.md section 5,
/// "Appearance", M7): pinch, and Cmd-plus / Cmd-minus on a hardware keyboard. The size is
/// stored (`AppSettings.fontSize`), so the next screen starts with it. A new size changes the
/// view's columns and rows; the screen sends them to the server as an ordinary Resize
/// (debounced 100 ms), like a rotation.
///
/// Decisions where the plan is silent: whole points from 8 to 32; a pinch scales the size it
/// started with and applies each whole-point change at once (the Resize debounce keeps the
/// server from seeing every step); Cmd-plus, Cmd-equals and Cmd-minus step by 1 pt.
final class FontZoom: NSObject {
    private weak var surface: TerminalSurface?
    private var pinchStartSize: CGFloat = AppSettings.defaultFontSize

    init(surface: TerminalSurface) {
        self.surface = surface
        super.init()
        surface.fontSize = AppSettings.fontSize
    }

    func install(on view: UIView) {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        view.addGestureRecognizer(pinch)
    }

    /// The size a pinch of `scale` gives from `start`.
    static func pinchSize(start: CGFloat, scale: CGFloat) -> CGFloat {
        AppSettings.clampedFontSize(start * scale)
    }

    static func steppedSize(from size: CGFloat, by step: CGFloat) -> CGFloat {
        AppSettings.clampedFontSize(size + step)
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard let surface else { return }
        switch recognizer.state {
        case .began:
            pinchStartSize = surface.fontSize
            fallthrough
        case .changed:
            surface.fontSize = Self.pinchSize(start: pinchStartSize, scale: recognizer.scale)
        case .ended, .cancelled:
            AppSettings.fontSize = surface.fontSize
        default:
            break
        }
    }

    func step(by points: CGFloat) {
        guard let surface else { return }
        surface.fontSize = Self.steppedSize(from: surface.fontSize, by: points)
        AppSettings.fontSize = surface.fontSize
    }

    /// Cmd-plus (also Cmd-equals, the same key without Shift) and Cmd-minus. Their actions are
    /// `biggerFont(_:)` and `smallerFont(_:)` on the terminal screen.
    static func keyCommands(bigger: Selector, smaller: Selector) -> [UIKeyCommand] {
        let commands = [
            UIKeyCommand(title: "Bigger Font", action: bigger, input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Bigger Font", action: bigger, input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Smaller Font", action: smaller, input: "-", modifierFlags: .command),
        ]
        for command in commands {
            command.wantsPriorityOverSystemBehavior = true
        }
        commands[1].attributes = .hidden
        return commands
    }
}
