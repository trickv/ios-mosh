import MoshBootstrap
import UIKit

/// Adds or edits a saved host: the per-host fields of docs/PLAN.md, Design 4. Also shows
/// the remembered host key and can forget it (the fix the "Host key changed" error points
/// to), and deletes the host.
final class HostEditorViewController: UIViewController, UITextFieldDelegate {
    /// Called after Save or Delete; the list pops back and reloads.
    var onFinish: (() -> Void)?

    private let store: HostStore
    private let knownHosts: KnownHosts
    private let isNew: Bool
    private var host: SavedHost

    private let stack = UIStackView()
    private var fields: [String: UITextField] = [:]
    private let clipboardSwitch = UISwitch()
    private let swipeSwitch = UISwitch()
    /// M10: local echo. One row per offered mode (`LocalEcho.offeredModes`, plus the stored
    /// one if this build does not offer it); the overwrite switch only if
    /// `LocalEcho.offersOverwrite`.
    private var localEchoMode: LocalEcho.Mode = LocalEcho.standard.mode
    private var localEchoButtons: [LocalEcho.Mode: OptionRow] = [:]
    private let overwriteSwitch = UISwitch()
    private let knownKeyLabel = UILabel()
    private let forgetKeyButton = UIButton(type: .system)

    init(host: SavedHost?, store: HostStore, knownHosts: KnownHosts = AppFiles.knownHosts) {
        self.store = store
        self.knownHosts = knownHosts
        self.isNew = host == nil
        self.host = host ?? SavedHost()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? "New Host" : "Edit Host"
        view.backgroundColor = .systemGroupedBackground
        let save = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
        save.accessibilityIdentifier = "saveHost"
        navigationItem.rightBarButtonItem = save

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])

        addSection("Connection")
        addField("name", label: "Name", text: host.name, placeholder: "optional")
        addField("host", label: "Host", text: host.host, placeholder: "host name or IP address", keyboard: .URL)
        addField("port", label: "SSH port", text: String(host.port), placeholder: "22", keyboard: .numberPad)
        addField("user", label: "User", text: host.user, placeholder: "login name")
        addValueRow(label: "Key", value: "\(host.keyName) (this device)")

        addSection("mosh-server")
        addField("serverPath", label: "Server path", text: host.serverPath, placeholder: "mosh-server")
        addField("locale", label: "Locale", text: host.locale, placeholder: MoshServerCommand.defaultLocale)
        addField("udpPorts", label: "UDP ports", text: host.udpPortRange, placeholder: "60001:60010")
        addField("remoteCommand", label: "Command", text: host.remoteCommand, placeholder: "login shell")
        addPresetsButton()

        addSection("Options")
        addSwitch(clipboardSwitch, id: "switch.clipboard", label: "Allow clipboard write", isOn: host.allowClipboardWrite)
        addSwitch(swipeSwitch, id: "switch.swipe", label: "Swipe sends PgUp/PgDn", isOn: host.swipeSendsPaging)

        addSection("Local echo")
        addLocalEchoRows()

        if !isNew {
            addSection("Host key")
            knownKeyLabel.numberOfLines = 0
            knownKeyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            knownKeyLabel.accessibilityIdentifier = "knownHostKey"
            stack.addArrangedSubview(knownKeyLabel)
            forgetKeyButton.setTitle("Forget Host Key", for: .normal)
            forgetKeyButton.accessibilityIdentifier = "forgetHostKey"
            forgetKeyButton.contentHorizontalAlignment = .leading
            forgetKeyButton.addTarget(self, action: #selector(forgetHostKey), for: .touchUpInside)
            stack.addArrangedSubview(forgetKeyButton)
            updateKnownKey()

            let delete = UIButton(type: .system)
            delete.setTitle("Delete Host", for: .normal)
            delete.setTitleColor(.systemRed, for: .normal)
            delete.accessibilityIdentifier = "deleteHost"
            delete.contentHorizontalAlignment = .leading
            delete.addTarget(self, action: #selector(confirmDelete), for: .touchUpInside)
            stack.setCustomSpacing(28, after: forgetKeyButton)
            stack.addArrangedSubview(delete)
        }
    }

    // MARK: Building

    private func addSection(_ title: String) {
        let label = UILabel()
        label.text = title.uppercased()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        if stack.arrangedSubviews.last != nil { stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!) }
        stack.addArrangedSubview(label)
    }

    private func addField(_ key: String, label: String, text: String, placeholder: String,
                          keyboard: UIKeyboardType = .asciiCapable) {
        let field = UITextField()
        field.text = text
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.keyboardType = keyboard
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .next
        field.delegate = self
        field.accessibilityIdentifier = "field.\(key)"
        field.accessibilityLabel = label
        fields[key] = field
        stack.addArrangedSubview(row(label: label, control: field))
    }

    private func addValueRow(label: String, value: String) {
        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.textColor = .secondaryLabel
        valueLabel.numberOfLines = 0
        stack.addArrangedSubview(row(label: label, control: valueLabel))
    }

    private func addSwitch(_ toggle: UISwitch, id: String, label: String, isOn: Bool) {
        toggle.isOn = isOn
        toggle.accessibilityIdentifier = id
        toggle.accessibilityLabel = label
        let text = UILabel()
        text.text = label
        text.numberOfLines = 0
        let line = UIStackView(arrangedSubviews: [text, toggle])
        line.alignment = .center
        line.spacing = 8
        stack.addArrangedSubview(line)
    }

    private func addLocalEchoRows() {
        localEchoMode = host.localEcho.mode
        var modes = LocalEcho.offeredModes
        if !modes.contains(localEchoMode) { modes.append(localEchoMode) }
        for mode in modes {
            // OptionRow, not a UIButton configuration: see OptionRow for the centring that
            // caused (owner's report on build 183).
            let row = OptionRow(title: mode.title, detail: mode.detail, identifier: "localEcho.\(mode.rawValue)")
            row.addAction(UIAction { [weak self] _ in self?.chooseLocalEcho(mode) }, for: .touchUpInside)
            localEchoButtons[mode] = row
            stack.addArrangedSubview(row)
        }
        if LocalEcho.offersOverwrite {
            addSwitch(overwriteSwitch, id: "switch.localEchoOverwrite", label: LocalEcho.overwriteTitle,
                      isOn: host.localEcho.overwrite)
        }
        chooseLocalEcho(localEchoMode)
    }

    private func chooseLocalEcho(_ mode: LocalEcho.Mode) {
        localEchoMode = mode
        for (each, row) in localEchoButtons {
            row.isChosen = each == mode
        }
    }

    private func addPresetsButton() {
        let button = UIButton(type: .system)
        button.setTitle("Command presets", for: .normal)
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "commandPresets"
        let choices = [""] + SavedHost.remoteCommandPresets
        button.menu = UIMenu(children: choices.map { preset in
            UIAction(title: preset.isEmpty ? "Login shell (no command)" : preset) { [weak self] _ in
                self?.fields["remoteCommand"]?.text = preset
            }
        })
        button.showsMenuAsPrimaryAction = true
        stack.addArrangedSubview(button)
    }

    private func row(label: String, control: UIView) -> UIView {
        let title = UILabel()
        title.text = label
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let line = UIStackView(arrangedSubviews: [title, control])
        line.alignment = .center
        line.spacing = 8
        return line
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let order = ["name", "host", "port", "user", "serverPath", "locale", "udpPorts", "remoteCommand"]
        if let key = fields.first(where: { $0.value === textField })?.key,
           let index = order.firstIndex(of: key), index + 1 < order.count {
            fields[order[index + 1]]?.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return false
    }

    // MARK: Known host key

    private func updateKnownKey() {
        do {
            if let known = try knownHosts.lookup(host: host.host, port: host.port) {
                knownKeyLabel.text = "\(known.keyType)\n\(known.fingerprint)"
                forgetKeyButton.isHidden = false
            } else {
                knownKeyLabel.text = "None remembered yet. It is shown for confirmation on the first connect."
                forgetKeyButton.isHidden = true
            }
        } catch {
            knownKeyLabel.text = "\(error)"
            forgetKeyButton.isHidden = true
        }
    }

    @objc private func forgetHostKey() {
        let alert = UIAlertController(
            title: "Forget the host key?",
            message: "The next connection shows the host's key for confirmation again. Do this only if you know why the key changed (for example, the host was reinstalled).",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Forget", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try self.knownHosts.remove(host: self.host.host, port: self.host.port)
            } catch {
                self.showError("\(error)")
            }
            self.updateKnownKey()
        })
        present(alert, animated: true)
    }

    // MARK: Save and delete

    private func text(_ key: String) -> String {
        (fields[key]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func save() {
        var edited = host
        edited.name = text("name")
        edited.host = text("host")
        let portText = text("port")
        edited.port = portText.isEmpty ? 22 : (Int(portText) ?? 0)
        edited.user = text("user")
        edited.serverPath = text("serverPath")
        let locale = text("locale")
        edited.locale = locale.isEmpty ? MoshServerCommand.defaultLocale : locale
        edited.udpPortRange = text("udpPorts")
        edited.remoteCommand = text("remoteCommand")
        edited.allowClipboardWrite = clipboardSwitch.isOn
        edited.swipeSendsPaging = swipeSwitch.isOn
        edited.localEcho.mode = localEchoMode
        if LocalEcho.offersOverwrite { edited.localEcho.overwrite = overwriteSwitch.isOn }
        if let problem = edited.validationError() {
            showError(problem)
            return
        }
        do {
            try store.upsert(edited)
        } catch {
            showError("\(error)")
            return
        }
        host = edited
        view.endEditing(true)
        onFinish?()
    }

    @objc private func confirmDelete() {
        let alert = UIAlertController(
            title: "Delete \(host.displayName)?", message: "The host's settings are removed.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try self.store.delete(id: self.host.id)
            } catch {
                self.showError("\(error)")
                return
            }
            self.view.endEditing(true)
            self.onFinish?()
        })
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Host", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
