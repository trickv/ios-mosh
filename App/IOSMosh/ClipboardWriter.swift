import MoshSession
import UIKit

/// Carries out `ClipboardPolicy`'s decisions (docs/PLAN.md section 5, "OSC 52"): the remote
/// program sets the iOS clipboard, never the other way round. The policy (in the session)
/// decides; this writes `UIPasteboard.general` and shows a toast:
/// - `.write`: the text goes to the pasteboard, "Copied N bytes".
/// - `.invalid`: nothing is written, "Clipboard data from the host was invalid or truncated".
/// - `.none`: nothing.
/// Clipboard contents never go to the log.
final class ClipboardWriter {
    static let invalidMessage = "Clipboard data from the host was invalid or truncated"

    private let toast = UILabel()
    private var hideWork: DispatchWorkItem?
    private let pasteboard: UIPasteboard

    init(pasteboard: UIPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Adds the toast to `parent`, below `top`.
    func install(in parent: UIView, below top: NSLayoutYAxisAnchor) {
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.textColor = .white
        toast.backgroundColor = UIColor.darkGray.withAlphaComponent(0.92)
        toast.font = .preferredFont(forTextStyle: .footnote)
        toast.textAlignment = .center
        toast.numberOfLines = 0
        toast.layer.cornerRadius = 8
        toast.layer.masksToBounds = true
        toast.isHidden = true
        toast.accessibilityIdentifier = "clipboardToast"
        parent.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.topAnchor.constraint(equalTo: top, constant: 12),
            toast.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            toast.widthAnchor.constraint(lessThanOrEqualTo: parent.widthAnchor, constant: -40),
            toast.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }

    func apply(_ decision: ClipboardPolicy.Decision) {
        switch decision {
        case .write(let text, let byteCount):
            pasteboard.string = text
            DebugLog.shared.log("clipboard: wrote \(byteCount) bytes from the host")
            show("Copied \(byteCount) bytes", seconds: 2.5)
        case .invalid(let reason):
            DebugLog.shared.log("clipboard: not written (\(reason))")
            show(Self.invalidMessage, seconds: 4)
        case .none:
            break
        }
    }

    private func show(_ text: String, seconds: TimeInterval) {
        toast.text = "  \(text)  "
        toast.isHidden = false
        toast.superview?.bringSubviewToFront(toast)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast.isHidden = true }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
