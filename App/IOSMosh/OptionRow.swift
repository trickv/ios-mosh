import UIKit

/// One row of a pick-one list in the host editor (local echo): a title, a detail line under it
/// and a checkmark at the trailing edge on the chosen row, drawn like the Settings screen's
/// option rows (a table cell with `.checkmark`): text in the label colours, only the checkmark
/// in the tint colour.
///
/// The editor used `UIButton.Configuration.plain()` with `contentHorizontalAlignment = .fill`
/// and the checkmark as the button's image. `.fill` lays out the image and the title block
/// across the width only while there is an image: a row whose image was removed (not chosen)
/// had its title and subtitle centred, so rows jumped between left and centre when the choice
/// changed; and `plain()` draws title and subtitle in the tint colour. Here the text is always
/// pinned to the leading edge and the checkmark keeps its width when hidden (alpha 0), so
/// nothing moves when the choice changes.
final class OptionRow: UIControl {
    let titleLabel = UILabel()
    let detailLabel = UILabel()
    private let checkmark = UIImageView(image: UIImage(systemName: "checkmark"))

    var isChosen = false {
        didSet { update() }
    }

    /// `identifier` names the row for UI tests; its title and detail get `.title` and
    /// `.detail` appended.
    init(title: String, detail: String, identifier: String) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityIdentifier = identifier + ".title"
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.accessibilityIdentifier = identifier + ".detail"
        checkmark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .default)
        checkmark.contentMode = .center
        checkmark.setContentHuggingPriority(.required, for: .horizontal)
        checkmark.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 2
        let line = UIStackView(arrangedSubviews: [text, checkmark])
        line.alignment = .center
        line.spacing = 8
        line.isUserInteractionEnabled = false
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        isAccessibilityElement = true
        accessibilityIdentifier = identifier
        accessibilityLabel = title
        accessibilityHint = detail
        // The row is one element for VoiceOver; UI tests also reach its two labels.
        automationElements = [titleLabel, detailLabel]
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .systemFill : .clear }
    }

    private func update() {
        checkmark.alpha = isChosen ? 1 : 0
        accessibilityTraits = isChosen ? [.button, .selected] : .button
        accessibilityValue = isChosen ? "chosen" : ""
    }
}
