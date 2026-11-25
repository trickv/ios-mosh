import UIKit

/// Settings (docs/PLAN.md section 5 and 6): the terminal's font size, colour theme and cursor, the key
/// bar's tmux prefix, the Help, About and Privacy pages, and in debug builds "Crash Now". Opened from the host list. A change applies to the
/// next terminal screen; on an open terminal the font size also follows pinch and
/// Cmd-plus / Cmd-minus (`FontZoom`).
final class SettingsViewController: UITableViewController {
    private enum Row {
        case fontSize, tmuxPrefix, help, about, privacy
        /// M8: one row per colour theme (`TerminalTheme.all`), the stored one checked.
        case theme(TerminalTheme)
        /// M8: cursor shape rows and the blink switch.
        case cursorShape(CursorShape)
        case cursorBlink
        /// Debug builds only (docs/PLAN.md M6): `DebugCrash.now()`.
        case crashNow
    }

    private let sections: [(title: String?, rows: [Row])] = {
        var sections: [(title: String?, rows: [Row])] = [
            ("Terminal", [.fontSize]),
            ("Theme", TerminalTheme.all.map { .theme($0) }),
            ("Cursor", CursorShape.allCases.map { .cursorShape($0) } + [.cursorBlink]),
            ("Key Bar", [.tmuxPrefix]),
            (nil, [.help, .about, .privacy]),
        ]
        if DebugCrash.isAvailable { sections.append(("Debug", [.crashNow])) }
        return sections
    }()

    private let stepper = UIStepper()
    private let blinkSwitch = UISwitch()
    private let prefixField = UITextField()
    private weak var fontSizeLabel: UILabel?
    /// Shown under the prefix row after a rejected entry.
    private var prefixMessage: String?

    init() {
        super.init(style: .insetGrouped)
        title = "Settings"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "settings"
        stepper.minimumValue = Double(AppSettings.fontSizeRange.lowerBound)
        stepper.maximumValue = Double(AppSettings.fontSizeRange.upperBound)
        stepper.stepValue = 1
        stepper.value = Double(AppSettings.fontSize)
        stepper.accessibilityIdentifier = "settings.fontSizeStepper"
        stepper.addAction(UIAction { [weak self] _ in self?.fontSizeStepped() }, for: .valueChanged)
        blinkSwitch.isOn = AppSettings.cursorBlinks
        blinkSwitch.accessibilityIdentifier = "settings.cursorBlink"
        blinkSwitch.addAction(UIAction { [weak self] _ in
            AppSettings.cursorBlinks = self?.blinkSwitch.isOn ?? true
        }, for: .valueChanged)

        prefixField.text = AppSettings.tmuxPrefixText
        prefixField.textAlignment = .right
        prefixField.autocapitalizationType = .none
        prefixField.autocorrectionType = .no
        prefixField.spellCheckingType = .no
        prefixField.returnKeyType = .done
        prefixField.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        prefixField.clearButtonMode = .whileEditing
        prefixField.frame = CGRect(x: 0, y: 0, width: 90, height: 34)
        prefixField.accessibilityIdentifier = "settings.tmuxPrefix"
        prefixField.addAction(UIAction { [weak self] _ in self?.prefixEdited() }, for: .editingDidEnd)
        prefixField.addAction(UIAction { [weak self] _ in self?.prefixField.resignFirstResponder() },
                              for: .editingDidEndOnExit)
    }

    // MARK: Actions

    private func fontSizeStepped() {
        AppSettings.fontSize = CGFloat(stepper.value)
        stepper.value = Double(AppSettings.fontSize)
        // Not a row reload: that would take the stepper out of the window in the middle of its
        // touch, and its autorepeat would never stop.
        fontSizeLabel?.text = "\(Int(AppSettings.fontSize)) pt"
    }

    private func prefixEdited() {
        let text = prefixField.text ?? ""
        if AppSettings.setTmuxPrefix(text) {
            prefixMessage = nil
        } else {
            prefixMessage = "\"\(text)\" is not a prefix; kept \(AppSettings.tmuxPrefixText)."
        }
        prefixField.text = AppSettings.tmuxPrefixText
        tableView.reloadData()
    }


    /// A small picture of a palette: the theme's background with its eight normal colours.
    private static func swatch(_ palette: [RGB], background: RGB?) -> UIImage {
        let size = CGSize(width: 48, height: 24)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(background ?? RGB(0x000000)).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, color) in palette.prefix(8).enumerated() {
                UIColor(color).setFill()
                context.fill(CGRect(x: 4 + CGFloat(index) * 5, y: 7, width: 4, height: 10))
            }
        }
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section].rows.first {
        case .fontSize:
            return "Also by pinching the terminal, or Cmd-plus and Cmd-minus on a hardware keyboard."
        case .cursorShape:
            return "Applies to the next terminal screen."
        case .theme:
            return "Applies to the next terminal screen. System follows the phone's light or dark mode."
        case .crashNow:
            return "Kills the app at once (SIGKILL), as iOS would. Debug builds only."
        case .tmuxPrefix:
            let help = "Sent by the key bar's prefix key. C- and a letter or one of @ [ \\ ] ^ _ (default C-b)."
            return prefixMessage.map { $0 + "\n" + help } ?? help
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none
        switch row {
        case .fontSize:
            cell.textLabel?.text = "Font Size"
            cell.detailTextLabel?.text = "\(Int(AppSettings.fontSize)) pt"
            cell.detailTextLabel?.accessibilityIdentifier = "settings.fontSizeValue"
            fontSizeLabel = cell.detailTextLabel
            cell.accessoryView = stepper
        case .tmuxPrefix:
            cell.textLabel?.text = "tmux Prefix"
            cell.accessoryView = prefixField
        case .help:
            cell.textLabel?.text = "Help"
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "settings.help"
        case .about:
            cell.textLabel?.text = "About"
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "settings.about"
        case .privacy:
            cell.textLabel?.text = "Privacy"
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "settings.privacy"
        case .theme(let theme):
            cell.textLabel?.text = theme.name
            cell.selectionStyle = .default
            let selected = AppSettings.theme == theme
            cell.accessoryType = selected ? .checkmark : .none
            cell.accessibilityIdentifier = "settings.theme.\(theme.id)"
            cell.accessibilityValue = selected ? "selected" : ""
            if let palette = theme.palette {
                cell.imageView?.image = Self.swatch(palette, background: theme.background)
            }
        case .cursorShape(let shape):
            cell.textLabel?.text = shape.name
            cell.selectionStyle = .default
            let selected = AppSettings.cursorShape == shape
            cell.accessoryType = selected ? .checkmark : .none
            cell.accessibilityIdentifier = "settings.cursor.\(shape.rawValue)"
            cell.accessibilityValue = selected ? "selected" : ""
        case .cursorBlink:
            cell.textLabel?.text = "Blinking"
            cell.accessoryView = blinkSwitch
        case .crashNow:
            cell.textLabel?.text = "Crash Now"
            cell.textLabel?.textColor = .systemRed
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "settings.crashNow"
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .help:
            navigationController?.pushViewController(TextPageViewController.help(), animated: true)
        case .about:
            navigationController?.pushViewController(TextPageViewController.about(), animated: true)
        case .privacy:
            navigationController?.pushViewController(TextPageViewController.privacy(), animated: true)
        case .theme(let theme):
            AppSettings.theme = theme
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
        case .cursorShape(let shape):
            AppSettings.cursorShape = shape
            // The shape rows only: reloading the switch's row during a toggle is not wanted.
            let rows = sections[indexPath.section].rows.indices.filter {
                if case .cursorShape = sections[indexPath.section].rows[$0] { return true } else { return false }
            }
            tableView.reloadRows(at: rows.map { IndexPath(row: $0, section: indexPath.section) }, with: .none)
        case .crashNow:
            DebugCrash.now()
        default:
            break
        }
    }
}
