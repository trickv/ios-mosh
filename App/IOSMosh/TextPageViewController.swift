import UIKit

/// A page of text under Settings: Help, About and Privacy (docs/PLAN.md section 5 "OSC 52" and
/// section 6; `PrivacyPolicy`), and the licence pages that About leads to (`LicencePages`).
final class TextPageViewController: UIViewController {
    /// A button above the text that opens another page.
    struct Link {
        let title: String
        let identifier: String
        let page: () -> UIViewController
    }

    private let text: String
    private let identifier: String
    private let links: [Link]

    init(title: String, text: String, identifier: String, links: [Link] = []) {
        self.text = text
        self.identifier = identifier
        self.links = links
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = .link
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        textView.text = text
        textView.accessibilityIdentifier = identifier
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        guard !links.isEmpty else {
            textView.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
            return
        }
        let buttons = UIStackView(arrangedSubviews: links.map(button))
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.axis = .vertical
        buttons.spacing = 8
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 4),
        ])
    }

    private func button(_ link: Link) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = link.title
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 8
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = .preferredFont(forTextStyle: .body)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.navigationController?.pushViewController(link.page(), animated: true)
        })
        button.contentHorizontalAlignment = .fill
        button.accessibilityIdentifier = link.identifier
        return button
    }

    static func help() -> TextPageViewController {
        TextPageViewController(title: "Help", text: AppTexts.help, identifier: "helpText")
    }

    static func about() -> TextPageViewController {
        TextPageViewController(title: "About", text: AppTexts.about(), identifier: "aboutText", links: [
            Link(title: "GNU General Public License v3", identifier: "about.gpl", page: gpl),
            Link(title: "App Store permission", identifier: "about.appStore", page: appStorePermission),
            Link(title: "Third-party licences", identifier: "about.thirdParty", page: thirdParty),
        ])
    }

    static func privacy() -> TextPageViewController {
        TextPageViewController(title: "Privacy", text: PrivacyPolicy.page(), identifier: "privacyText")
    }

    static func appStorePermission() -> TextPageViewController {
        TextPageViewController(title: "App Store permission", text: LicencePages.appStorePermissionPage(),
                               identifier: "appStorePermissionText")
    }

    static func gpl() -> TextPageViewController {
        TextPageViewController(title: "GNU GPL v3", text: LicencePages.gplPage(), identifier: "gplText")
    }

    static func thirdParty() -> TextPageViewController {
        TextPageViewController(title: "Third-party licences", text: LicencePages.thirdPartyPage(),
                               identifier: "thirdPartyText")
    }
}

/// The texts of the Help and About pages.
enum AppTexts {
    static let sourceURL = "https://github.com/trickv/ios-mosh"

    /// The copyright notice (the same lines as NOTICE and README.md at the top of the repository).
    static let copyright = """
    Copyright (C) 2026 Patrick van Staveren. Portions Copyright 2012 Keith Winstein and the \
    mosh authors (https://mosh.org), ported from mosh 1.4.0.
    """

    static let help = """
    The terminal

    • Long-press the screen (about 0.7 s) for the edit menu: Select, Select All, Paste. Select \
    picks a word; drag to extend it, then Copy. Copy covers the visible screen only. This also \
    works while tmux or vim has mouse mode on.
    • Pinch to change the font size, or use Cmd-plus and Cmd-minus on a hardware keyboard. The \
    size is kept; Settings also has it.
    • If a host has "Swipe sends PgUp/PgDn" on, a vertical swipe sends PgUp (finger down) or \
    PgDn (finger up) while the remote program has mouse mode off.
    • The bell makes the phone buzz.

    The key bar

    Esc, Ctrl (sticky: it applies to the next key), Tab, the arrows (hold to repeat) and Paste \
    stay in place. Swipe the rest for Alt (sticky), | / ~ - _, PgUp, PgDn, Home, End, the tmux \
    prefix (Settings, default C-b) and the key that hides the keyboard. With a hardware keyboard \
    the bar folds into one "Keys" button.

    Copying from the host to the iPhone (OSC 52)

    A program on the host can put text on the iPhone's clipboard with OSC 52; a short note \
    says "Copied N bytes". The host's "allow clipboard write" switch turns it off. Details \
    and tests: docs/SERVER-SETUP.md in the source code.

    tmux: add to ~/.tmux.conf
        set -s set-clipboard on
        set -as terminal-overrides ',xterm*:Ms=\\E]52;c;%?%{0}%t%p1%s%;%p2%s\\a'
    then run tmux source-file ~/.tmux.conf, detach and attach again. This carries copies \
    made in tmux and by programs in a pane (neovim, printf).

    neovim 0.10 or newer: in ~/.config/nvim/init.lua
        local osc52 = require('vim.ui.clipboard.osc52')
        local last = { {}, 'v' }
        local function copy(reg)
          local send = osc52.copy(reg)
          return function(lines, regtype)
            last = { lines, regtype }
            send(lines)
          end
        end
        local function paste() return last end
        vim.g.clipboard = {
          name = 'OSC 52',
          copy = { ['+'] = copy('+'), ['*'] = copy('*') },
          paste = { ['+'] = paste, ['*'] = paste },
        }
    Copy with "+y. "+p pastes the last text copied in this neovim; to paste from the \
    iPhone, use the Paste key. Outside tmux, "*y does not arrive.

    Limits: about 12 KB of text per copy (a longer copy arrives cut off and is refused); the \
    same text copied twice in a row arrives once (mosh issue 1090); the app never sends the \
    iPhone's clipboard to the host.

    Local echo (per host, in the host editor)

    mosh can show what you type before the host's answer arrives. In mosh's words:
    • Adaptive: \(LocalEcho.Mode.adaptive.detail)
    • Always: \(LocalEcho.Mode.always.detail)
    • Never: \(LocalEcho.Mode.never.detail)
    """

    static func about(version: String = BuildInfo.version, build: String = BuildInfo.build,
                      sha: String = BuildInfo.gitSHA, fontLicences: String = TerminalFont.licencePage()) -> String {
        """
        iOS-mosh

        Version \(version) (\(build)) \(sha)

        A terminal for the mosh protocol: sessions survive the app being suspended or closed.

        Source code: \(sourceURL)

        \(copyright)

        This program is free software: you can redistribute it and/or modify it under the terms \
        of the GNU General Public License as published by the Free Software Foundation, either \
        version 3 of the License, or (at your option) any later version. It is distributed in \
        the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied \
        warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General \
        Public License for more details: its full text is on the page "GNU General Public \
        License v3" above, and at https://www.gnu.org/licenses/gpl-3.0.html

        The additional permission under section 7 of the GPL for Apple's App Store and \
        TestFlight, and mosh's own statement on the App Store, are on the page "App Store \
        permission" above (the file COPYING.iOS in the source code).

        The mosh protocol, the terminal emulation and the local echo are ported from mosh \
        1.4.0 (https://mosh.org), GPL version 3 or later.

        Built with:
        • SwiftTerm, MIT License, https://github.com/migueldeicaza/SwiftTerm
        • SwiftNIO, SwiftNIO SSH, SwiftNIO Transport Services, Swift Crypto, \
        Apache License 2.0, https://github.com/apple
        Their licence and NOTICE texts, and those of the packages they use, are on the page \
        "Third-party licences" above.
        • \(TerminalFont.familyName) (the terminal font), Nerd Fonts v3.5.1, \
        https://github.com/ryanoasis/nerd-fonts: Hack, MIT License and Bitstream Vera License; \
        glyph sets under the MIT License, CC BY 4.0, Apache License 2.0, SIL Open Font License \
        1.1 and The Unlicense. Their licence texts are below.

        Font licences

        \(fontLicences)
        """
    }
}
