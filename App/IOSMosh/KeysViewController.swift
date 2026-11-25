import MoshKeys
import UIKit

/// The keys screen (docs/PLAN.md, Design 4 "Keys"): the device key's
/// `ssh-ed25519 AAAA… ios-mosh@<device>` line, its SHA256 fingerprint, Copy and the share
/// sheet. The key is made here if it does not exist yet. The private key is never shown.
///
/// "Install my key on this host" is offered after a password login (TerminalViewController),
/// over the connection that is already open.
final class KeysViewController: UIViewController {
    private let store: KeyStore
    private(set) var key: StoredKey?

    private let nameLabel = UILabel()
    private let lineLabel = UILabel()
    private let fingerprintLabel = UILabel()
    private let noteLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)

    init(store: KeyStore = KeychainKeyStore()) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Keys"
        view.backgroundColor = .systemGroupedBackground

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        lineLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        lineLabel.numberOfLines = 0
        lineLabel.lineBreakMode = .byCharWrapping
        lineLabel.accessibilityIdentifier = "publicKey"
        fingerprintLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        fingerprintLabel.numberOfLines = 0
        fingerprintLabel.lineBreakMode = .byCharWrapping
        fingerprintLabel.accessibilityIdentifier = "keyFingerprint"
        noteLabel.font = .preferredFont(forTextStyle: .footnote)
        noteLabel.textColor = .secondaryLabel
        noteLabel.numberOfLines = 0
        noteLabel.text = "Add this line to ~/.ssh/authorized_keys on a host to log in with this device's key. After a password login the app offers to do it for you (\"Install my key on this host\"). The private key stays in this device's Keychain and is never shown or backed up."

        copyButton.setTitle("Copy Public Key", for: .normal)
        copyButton.accessibilityIdentifier = "copyPublicKey"
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        shareButton.setTitle("Share…", for: .normal)
        shareButton.accessibilityIdentifier = "sharePublicKey"
        shareButton.addTarget(self, action: #selector(share), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [copyButton, shareButton])
        buttons.spacing = 24

        let stack = UIStackView(arrangedSubviews: [nameLabel, lineLabel, fingerprintLabel, buttons, noteLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        buttons.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
        load()
    }

    private func load() {
        do {
            let key = try DeviceKey.ensure(in: store)
            self.key = key
            nameLabel.text = "This device (\(key.name))"
            lineLabel.text = key.authorizedKeysLine
            lineLabel.accessibilityValue = key.authorizedKeysLine
            fingerprintLabel.text = key.fingerprint
            fingerprintLabel.accessibilityValue = key.fingerprint
            copyButton.isEnabled = true
            shareButton.isEnabled = true
        } catch {
            key = nil
            nameLabel.text = "No key"
            lineLabel.text = "The device key cannot be read or made: \(error)"
            fingerprintLabel.text = ""
            copyButton.isEnabled = false
            shareButton.isEnabled = false
            DebugLog.shared.log("keys: \(error)")
        }
    }

    /// Puts the public key line on the pasteboard. Returns the line, nil without a key.
    @discardableResult
    func copyPublicKey() -> String? {
        guard let line = key?.authorizedKeysLine else { return nil }
        UIPasteboard.general.string = line
        return line
    }

    @objc private func copyTapped() {
        guard copyPublicKey() != nil else { return }
        copyButton.setTitle("Copied", for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyButton.setTitle("Copy Public Key", for: .normal)
        }
    }

    @objc private func share() {
        guard let line = key?.authorizedKeysLine else { return }
        let sheet = UIActivityViewController(activityItems: [line], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = shareButton
        present(sheet, animated: true)
    }
}
