# Terminal font

The terminal draws with Hack Nerd Font Mono (docs/PLAN.md section 5: a bundled monospace font
with powerline glyphs). Chosen by Trick on 2026-11-19. This whole directory is copied into the
app as the folder `Fonts` (App/project.yml); `UIAppFonts` in the generated Info.plist registers
the four faces, and `App/IOSMosh/TerminalFont.swift` loads them by PostScript name.

## Source

Nerd Fonts release v3.5.1 (https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.5.1,
published 2026-08-21), asset `Hack.tar.xz`, Hack 3.003. Only the "Nerd Font Mono" faces
(every glyph one cell wide) are bundled; the archive's "Nerd Font" and "Nerd Font Propo"
faces are not.

| File | SHA-256 | PostScript name |
|---|---|---|
| `Hack.tar.xz` (the archive, not committed) | `cdd389472e10e2261520140ff1b382b4f8a226af5fd0b2735b975d31151d9c3c` | - |
| `HackNerdFontMono-Regular.ttf` | `e5aeb58577a8acf2b42083e4a07ce48bd53116fdd868636403cadb5b547351be` | `HackNFM-Regular` |
| `HackNerdFontMono-Bold.ttf` | `7c2c76c26ff80fb546798b204ae519335573417c969eb3142d202298722d3832` | `HackNFM-Bold` |
| `HackNerdFontMono-Italic.ttf` | `7b45fbee724e4a58bca6e23d176006d6334cdc848d0ec53ec38daef252900fa8` | `HackNFM-Italic` |
| `HackNerdFontMono-BoldItalic.ttf` | `ad9e8d4504c0ffaab07ff44bb98cc0cfd67655df9cda97f5c9fc15e77b301497` | `HackNFM-BoldItalic` |

The archive's SHA-256 is the one GitHub lists for the asset. The files are unchanged.

## Licences (`licenses/`)

Shown in the app at the end of Settings, "About" (which also names the font and its licences).

| File | From | Covers |
|---|---|---|
| `Hack-LICENSE.md` | the archive | Hack: MIT (Source Foundry), Bitstream Vera License (base design; "Bitstream" and "Vera" reserved, the font is renamed), DejaVu changes public domain |
| `Hack-NerdFonts-README.md` | the archive | the glyph sets patched in, with version and licence |
| `NerdFonts-LICENSE.txt`, `NerdFonts-license-audit.md` | nerd-fonts v3.5.1 | Nerd Fonts' own work: MIT (scripts), SIL OFL 1.1 (patched fonts and glyph fonts) |
| `PowerlineSymbols-LICENSE.txt` | nerd-fonts v3.5.1 `src/glyphs/powerline-symbols` | Powerline symbols U+E0A0-E0A2, U+E0B0-E0B3: MIT |
| `PowerlineExtraSymbols-LICENSE.txt` | nerd-fonts v3.5.1 `src/glyphs/powerline-extra` | MIT |
| `Codicons-LICENSE.txt` | nerd-fonts v3.5.1 `src/glyphs/codicons` | CC BY 4.0 (full text) |
| `FontAwesome-LICENSE.txt` | nerd-fonts v3.5.1 `src/glyphs/font-awesome` | icons CC BY 4.0, font SIL OFL 1.1 |
| `MaterialDesignIcons-LICENSE.txt`, `Apache-2.0.txt` | nerd-fonts v3.5.1 `src/glyphs/materialdesign`; apache.org | Apache License 2.0 |
| `Octicons-LICENSE.txt` | nerd-fonts v3.5.1 `src/glyphs/octicons` | MIT |
| `Pomicons-LICENSE.txt` | nerd-fonts v3.5.1 `src/glyphs/pomicons` | SIL OFL 1.1, Reserved Font Name "Pomicons" |
| `WeatherIcons-OFL.txt` | nerd-fonts v3.5.1 `src/glyphs/weather-icons` | SIL OFL 1.1 |
| `Devicons-LICENSE.txt` | devicons/devicon v2.17.0 | MIT |
| `FontAwesomeExtension-LICENSE.txt` | AndreLZGava/font-awesome-extension (master) | MIT |
| `FontLogos-LICENSE.txt` | lukas-w/font-logos v1.3.0 | The Unlicense (public domain) |
| `SetiUI-LICENSE.txt` | jesseweed/seti-ui (master) | MIT |
| `IECPowerSymbols-LICENSE.txt` | jloughry/Unicode (master) | MIT |

None of them forbids shipping the fonts inside a GPLv3 app: they are separate files in the
bundle, not sold by themselves, under their original names, with their notices and licence
texts inside the app.
