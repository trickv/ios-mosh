import UIKit

/// M0 placeholder: a terminal view that echoes what is typed. It proves the build,
/// signing, install and UI-test route before the real screens exist.
final class PlaceholderViewController: UIViewController {
    private let surface: TerminalSurface = SwiftTermSurface()
    private let screenText = ScreenTextElement()
    private var displayLink: CADisplayLink?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let terminal = surface.view
        terminal.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        surface.onInput = { [weak self] bytes in
            self?.echo(bytes)
        }
        surface.feed(Array("iOS-mosh \(BuildInfo.summary)\r\nplaceholder: typed keys are echoed\r\n".utf8))

        if UITestSupport.isUITesting {
            screenText.install(in: view)
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        surface.focus()
    }

    private func echo(_ bytes: [UInt8]) {
        var out: [UInt8] = []
        for byte in bytes {
            switch byte {
            case 0x0D: out += [0x0D, 0x0A]
            case 0x7F: out += [0x08, 0x20, 0x08]
            default: out.append(byte)
            }
        }
        surface.feed(out)
    }

    @objc private func tick() {
        screenText.update(rows: surface.visibleText())
    }
}
