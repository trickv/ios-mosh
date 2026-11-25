# Research: swift_libs

> Planning-session notes, converted from workflow output on 2026-11-12. Reference only.

## summary

Recommended stack for iOS-mosh, as of 2026-11-11. Terminal UI: SwiftTerm (MIT) pinned exactly to v1.99.3. That release is a 2.0 preview, so expect the API to change. SwiftTerm already covers most front-end needs. Its iOS TerminalView implements UIKeyInput and UITextInput, handles hardware keys in pressesBegan, ships a replaceable `inputAccessoryView` (TerminalAccessory), offers optional Metal rendering, and exposes OSC 52 through the delegate methods `clipboardCopy(source:content: Data)` and `clipboardRead(source:) -> Data?`. Its headless core builds and is tested on Linux in CI (container swift:6.2-jammy). It also has a renderer-only view (TerminalRenderView fed by a TerminalExternalFrameSource) that fits a "remote framebuffer" model. SwiftTerm does not provide a way to clone a whole Terminal. mosh's client applies each server diff to a copy of an older stored state (`old_num`), so the app needs its own copyable mosh framebuffer and should use SwiftTerm only for display and input. SSH bootstrap: apple/swift-nio-ssh 0.15.1 (Apache-2.0). It supports Ed25519, ECDSA P-256/384/521 and Secure Enclave P-256 keys, password and publickey auth, and a host-key validation hook. It does not support keyboard-interactive (issue #136 open), RSA, or OpenSSH private-key parsing (issue #66 open). Citadel adds RSA, jump hosts and openssh-key-v1 parsing, but it now depends on a personal fork (Wellz26/swift-nio-ssh 0.3.x) and calls BoringSSL directly; that is risky. Crypto: swift-crypto 5.1.1. Its CryptoExtras module has `AES.permute(_:key:)`, a single-block AES call added in 2.2.4; it is BoringSSL-backed and re-derives the key schedule on every call. For production OCB, use CommonCrypto ECB with the key set up once, or vendor Krovetz's OCB3 C code (permissive licence, already has a CommonCrypto backend in mosh's `ocb_internal.cc`). OCB patents were abandoned in Feb 2021. Protobuf: encode mosh's three proto2 schemas by hand. zlib: link the system libz. Apple's COMPRESSION_ZLIB writes raw DEFLATE, not the zlib-wrapped format that mosh's compress()/uncompress() use.

## details

## 1. Terminal front end

### SwiftTerm (github.com/migueldeicaza/SwiftTerm)
- **Licence and releases.** MIT. Latest release is v1.99.3 (2026-11-06); also v1.99.2 (10-29), v1.99.1 (10-21) and v1.99.0 (10-08, "Preview before 2.0"). The README describes "the new SwiftTerm 2.0 API"; the 1.x API lives on the `v1.x` branch. Pin `exact: "1.99.3"`.
- **Package.** `swift-tools-version:6.2`, so Xcode 26 or later is needed. Minimum iOS is 14. Swift 6 language mode. Dependencies: swift-argument-parser, swift-docc-plugin, swift-png (only on Linux, Windows, WASI and Android, under the `PortableGraphics` trait).
- **Linux.** Package.swift has `#if os(Linux) || os(Windows) let platformExcludes = ["Apple","Mac","iOS"]`. CI job `linux-headless` runs on `ubuntu-latest` in container `swift:6.2-jammy` and runs `swift build --target SwiftTerm` and `swift test --no-parallel`. The engine (`Terminal`, `HeadlessTerminal`) can therefore be tested on the Linux box.

#### iOS view
`open class TerminalView: UIScrollView, UITextInputTraits, UIKeyInput, UIScrollViewDelegate, TerminalDelegate, UIPointerInteractionDelegate`, plus `extension TerminalView: UITextInput` in iOSTextInput.swift. That extension covers marked text and IME, dictation and the floating cursor.

**Keyboard input**
- Hardware keys: `open override func pressesBegan(_:with:)` at iOSTerminalView.swift:3250. Code comment: "Hardware keyboard text input is delivered here [insertText]; special keys are handled in pressesBegan."
- Kitty keyboard protocol encoder: KittyKeyboardEncoder.swift.
- Properties: `optionAsMetaKey = true` (Cmd-Opt-O toggles it), `backspaceSendsControlH`, `controlModifier`, `metaModifier`.

**Accessory bar**
- `public override var inputAccessoryView: UIView?` is a settable stored property. The default is `TerminalAccessory: UIInputView`, created in `setupAccessoryView()` with height 36 or 48.
- Built-in buttons: esc, tab, ctrl (sticky), ~ | / -, F1–F10, auto-repeat arrows, keyboard toggle, touch toggle.
- `inputView` can also be set, for a fully custom keyboard.
- If you replace the accessory, the view still reads `terminalAccessory?.controlModifier`. A custom bar must either subclass TerminalAccessory or use `terminalView.controlModifier`.

**Selection and copy**
- Long-press gesture → `UIMenuController.shared`. That API is deprecated since iOS 16; UIEditMenuInteraction is not used.
- `copy(_:)` returns `selection.getSelectedText()`. `canPerformAction` gates copy and paste. `pasteText(_:)` handles bracketed paste.

**Links**
- `linkReporting: .none | .explicit (OSC 8) | .implicit` (default) and `linkHighlightMode`.
- Delegate: `requestOpenLink(source:request: TerminalLinkRequest)`. On iOS a link tap does nothing unless you implement it. Treat the link text as untrusted.

**Fonts, theme and rendering**
- Fonts: `font: UIFont`, or `setFonts(normal:bold:italic:boldItalic:)`.
- Colours: `installColors(_ colors: [Color])`, `nativeForegroundColor` / `nativeBackgroundColor`, `configureNativeColors()`, `setCursorStyle(_:)`.
- Renderer: CoreGraphics/CoreText by default. Metal is opt-in with `try setUseMetal(true)` (throws `MetalError`) and `metalBufferingMode: .perRowPersistent | .perFrameAggregated`.

**Mouse reporting**
- `allowMouseReporting: Bool = true`. Taps go through `forwardTap(at:)`. A one-finger vertical drag becomes wheel presses; two fingers scroll.

**Byte flow and resize**
- Host feeds output with `feed(byteArray: ArraySlice<UInt8>)` or `feed(text:)`.
- User input reaches the delegate `send(source: TerminalView, data: ArraySlice<UInt8>)`.
- Size changes reach `sizeChanged(source:newCols:newRows:)`. A size change is coalesced to at most one notification per display frame, and the callback can arrive after the call stack that caused it has returned.
- `TerminalView` owns its `Terminal` and does not expose it. Read state with `terminalDimensions`, `terminalStateSnapshot()` and `getBufferAsData(kind:encoding:)`.

**OSC 52**
- Engine: `Terminal.oscClipboard` handles `ESC]52;<sel>;<base64>ST` writes and `ESC]52;<sel>;?ST` queries. Any `<sel>` value is accepted and an empty one is treated as `c`.
- Delegate: `func clipboardCopy(source: TerminalView, content: Data)` (default does nothing) and `func clipboardRead(source: TerminalView) -> Data?` (default nil, i.e. deny). The core also has `clipboardReadRequest(source:selection:) -> Bool` for asynchronous reads.
- Kitty OSC 5522 clipboard delegates also exist.
- Payload size: within `oscClipboard` itself there is no size check (it only base64-decodes the payload). I did not check whether the OSC parser has a global length limit.

**Snapshots and cloning**
- Copy-out snapshots exist: `TerminalContentSnapshot` with `TerminalContentRegion` and `TerminalCellSnapshot`, `makeRenderSnapshot(scope:)`, and `TerminalInputStateSnapshot`.
- Only `BufferLine` can be copied (`BufferLine.init(from:)`, `copyFrom(line:)`). Nothing in Terminal.swift, Buffer.swift or BufferSet.swift clones a whole Terminal or serialises it.

**Renderer-only path**
- `open class TerminalRenderView: UIView` (iOSTerminalRenderView.swift): "Draws the frames of a TerminalExternalFrameSource ... The view does no terminal emulation and handles no input. Use it when the terminal runs somewhere else."
- The frame source implements `@MainActor protocol TerminalExternalFrameSource { func withFrame(_ body: (TerminalExternalFrame, TerminalRowStore, (Int) -> BufferLine?) -> Void) }`.
- `TerminalExternalFrame` carries columns, rows, topLine, cursorLine and cursorColumn, cursorVisible, cursorStyle, isAlternateBuffer, a 256-entry palette, selection, images and kitty graphics.
- Call `requestRedraw()` when a frame is ready. `onGridSizeChange` reports grid size changes. `setUseMetal` is available.
- You must supply input, selection and scrolling yourself.

**Open iOS issues that matter**
- #591: Option-as-Meta drops Shift (M-: is sent as M-;).
- #483: external keyboard shortcuts are not activated.
- #663: a double tap ignores mouse reporting mode.
- #292: the accessory view ignores the safe area.
- #190: a double tap on ctrl should lock it.
- #271: backspace auto-repeat stops at a space.
- #274, #218, #221: selection problems.
- #12: accessibility is missing.

#### Fit with the mosh model
mosh's client keeps a list of received states. It applies each server diff to the stored state whose number matches `old_num`, working on a copy (networktransport-impl.h:96–140: `TimestampedState<RemoteState> new_state = *reference_state; ... new_state.state.apply_string(inst.diff())`). The client therefore needs a framebuffer it can copy; SwiftTerm's Terminal cannot be cloned. Recommended design:
1. Port mosh's `Terminal::Complete` / `Framebuffer` as a Swift value type. It must parse the server's diff bytes, be cheap to copy (copy-on-write rows), and support speculative local echo (predictive echo overlay).
2. Show it either way:
   - (a) Pass the newest state's repaint bytes (or the server diff itself, when it applies to the state on screen) to `TerminalView.feed`. This keeps SwiftTerm's UITextInput/IME, selection, links, OSC 52, mouse and accessory handling, but SwiftTerm then keeps a second terminal state (double emulation; scrollback would only be whatever the repaints happened to leave in it).
   - (b) Use `TerminalRenderView` + `TerminalExternalFrameSource` to draw the framebuffer directly as `BufferLine`s, and supply your own UIKeyInput/UITextInput view and selection.
- Option (a) gets features fastest. Note that mosh-server already consumes OSC 52 from the remote side; check how mosh 1.4 forwards clipboard (it added OSC 52 support) before relying on SwiftTerm's handler. I did not verify this here.

**A custom CoreText or Metal grid instead**
- Gains: no dependency churn from the 2.0 preview, exact control of the mosh framebuffer, smaller binary.
- Losses: grapheme and emoji width handling, BiDi, IME/marked text, dictation, the floating cursor, selection, link detection and a tested Metal glyph atlas — weeks of work.

### Alternatives
**libghostty-vt**
- `vt-1.0.0` tagged 2026-11-06 (very new).
- PACKAGING-LIBGHOSTTY.md: release artefacts include `ghostty-vt-VERSION.xcframework.zip`. Tier 1 targets ("Built and tested in CI") include iOS 13+ and Linux. Semantic versioning with ABI checks in CI.
- The README still says "API signatures are still in flux". libghostty-vt is parsing and state only, with no renderer.
- The full libghostty, including its renderer, is embedded on iOS by VVTerm (GPL-3.0; "uses Ghostty for terminal rendering, libssh2 and OpenSSL for SSH transport"). That requires building with Zig on macOS.

**Blink Shell**
- GPL-3.0. Uses hterm in a WKWebView (`Resources/hterm_all.min.js`) and LibSSH (libssh; `ssh_userauth_kbdint` in SSH/AuthMethods.swift).
- Avoid copying its code because of the GPL.

**xterm.js in WKWebView**
- Feasible, but it brings JS-bridge latency, IME quirks and first-responder fights. Not recommended.

## 2. SSH bootstrap library

### apple/swift-nio-ssh
- 0.15.1 (2026-10-26), Apache-2.0. Swift 6.1 or later for 0.13+. iOS 13. Depends on swift-nio 2.81+, swift-crypto `"1.0.0"..<"6.0.0"` and swift-atomics.
- **Private keys** (NIOSSHPrivateKey.swift): `init(ed25519Key: Curve25519.Signing.PrivateKey)`, `init(p256Key:)`, `init(p384Key:)`, `init(p521Key:)`, and `init(secureEnclaveP256Key: SecureEnclave.P256.Signing.PrivateKey)`.
- **No custom key backend.** `BackingKey` is a closed enum, so there is no RSA and no custom signer.
- **Host key algorithms:** `"ssh-ed25519","ecdsa-sha2-nistp384","ecdsa-sha2-nistp256","ecdsa-sha2-nistp521"`. No rsa-sha2 host keys, so a server with only an RSA host key will fail to connect.
- **Key exchange:** ECDH P-384, P-256 and P-521, and curve25519, from a static list. No ML-KEM or sntrup.
- **Ciphers:** `aes128-gcm@openssh.com` and `aes256-gcm@openssh.com` only. Ciphers are pluggable through `NIOSSHTransportProtection`.
- **Client auth methods:** `.publicKey`, `.password`, `.hostBased`. No keyboard-interactive (the state machine has no "keyboard" reference; issue #136 is open).
- **Certificates:** `NIOSSHCertifiedPublicKey` exists, and the offer can be built with `PrivateKey(privateKey:certifiedKey:)`.
- **Host-key hook:** `NIOSSHClientServerAuthenticationDelegate.validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise:)`.
- **Public-key text:** `NIOSSHPublicKey(openSSHPublicKey: String)` parses and `String(openSSHPublicKey:)` writes the authorized_keys form, including for Secure Enclave keys (they map to ecdsaP256).
- **No private-key file parsing** (issue #66 open).
- **ProxyJump:** possible by opening a `directTCPIP` child channel and running a second NIOSSHHandler over it (Citadel's `jump(to:)` does exactly this).
- **Linux:** works. Secure Enclave paths are Darwin-only.

### orlandos-nl/Citadel
- 0.12.1 (2026-04-04), MIT. Requires iOS 17 and macOS 14.
- Depends on `https://github.com/Wellz26/swift-nio-ssh.git "0.3.4"..<"0.4.0"`, a user fork of Joannis/swift-nio-ssh. The commit "use Wellz26 nio-ssh fork for Mac Catalyst compatibility" is dated 2026-04-02. Also depends on BigInt and ColorizeSwift.
- Adds: RSA (`Insecure.RSA` via BoringSSL BIGNUM), DH group14 sha1/sha256, AES-CTR, jump hosts, SFTP, exec (`withExec`), and openssh-key-v1 parsing with bcrypt KDF and aes128/256-ctr (`OpenSSH.PrivateKey(string:decryptionKey:)`, vendored C in `CCitadelBcrypt`).
- `makeSSHRepresentation` only writes unencrypted keys (cipher "none").
- No keyboard-interactive; `.custom(NIOSSHClientUserAuthenticationDelegate)` is possible but the underlying protocol support is missing.
- Risky: forked core, calls into BoringSSL directly.

### libssh2 (BSD-3) options
- Lakr233/libssh2-spm: product `CSSH2`, built from source with `LIBSSH2_OPENSSL`, depends on Lakr233/openssl-spm ≥ 3.6.0, iOS 12+. Last push 2026-04.
- libssh2 itself supports keyboard-interactive, RSA, passphrase-protected key import and custom signing callbacks (not checked in this pass).

### libssh (LGPL-2.1)
- Blink's choice. Has keyboard-interactive, certificates and ProxyJump.
- The LGPL with static linking on the App Store is a licensing burden, and I found no maintained SwiftPM package for it.

### Recommendation
- Use swift-nio-ssh 0.15.1 directly with NIOPosix, so the same code runs in Linux integration tests against a local sshd.
- Write openssh-key-v1 import and export yourself (see §3).
- Accepted gaps for v1: keyboard-interactive and 2FA, RSA user and host keys, ML-KEM key exchange.
- If 2FA is required, switch the bootstrap to libssh2-spm (BSD + OpenSSL) behind a protocol. The bootstrap is only "connect, auth, exec `mosh-server new -s -c 256 -l LANG=...`, read the `MOSH CONNECT <port> <key>` line, disconnect", so it is easy to swap.

## 3. Keys
**Generation**
- `Curve25519.Signing.PrivateKey()`; persist `rawRepresentation` (32 bytes). Works with CryptoKit on iOS and with swift-crypto `Crypto` on Linux.
- Secure Enclave: `SecureEnclave.P256.Signing.PrivateKey(compactRepresentable:accessControl:authenticationContext:)`. Apple's doc example uses `SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [], nil)`.
- A Secure Enclave key's `dataRepresentation` is an opaque, device-bound blob; the key is not exportable and cannot be synced or backed up. Store the blob in the Keychain. Export only the public key.

**Keychain**
- Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Apple: "recommended for items that need to be accessible only while the application is in the foreground ... will not be present" after a restore from another device. This fits an app that never runs in the background.
- Add `SecAccessControl` with `.userPresence` or `.biometryCurrentSet` if the user turns it on.
- Set `kSecAttrSynchronizable = false` (no iCloud Keychain). `ThisDeviceOnly` classes cannot sync anyway.
- Store items as `kSecClassGenericPassword` holding raw key bytes, or `kSecClassKey`.

**Public key export (authorized_keys)**
- `String(openSSHPublicKey: NIOSSHPublicKey)` from swift-nio-ssh, or hand-encode:
  - `ssh-ed25519`: wire = string("ssh-ed25519") || string(32-byte pk).
  - `ecdsa-sha2-nistp256`: wire = string("ecdsa-sha2-nistp256") || string("nistp256") || string(65-byte uncompressed point 0x04||X||Y, i.e. `x963Representation`).
  - Line = `type base64(wire) comment`.
- Fingerprint = `"SHA256:" + base64(SHA256(wire))` without `=` padding.
- Hand-encoding takes about 40 lines and is easy to test on Linux against `ssh-keygen -lf`.

**openssh-key-v1 import/export**
- Format: `"openssh-key-v1\0"`, ciphername, kdfname, kdfoptions (string(salt 16) || uint32 rounds, default 16), uint32 N=1, string(pubkey), string(encrypted private section). The private section is checkint×2, the key, the comment and padding 1,2,3…
- Encryption: `bcrypt_pbkdf(pass, salt, rounds) → 48 bytes` = key 32 + IV 16, then `aes256-ctr`.
- Library support:
  - swift-crypto CryptoExtras has `AES._CTR.encrypt/decrypt(_:using:nonce:)` and PBKDF2/Scrypt, but no bcrypt_pbkdf.
  - Citadel's parser only works as part of Citadel.
  - Comraich/swift-bcrypt-pbkdf exists (pushed 2025-11, licence "other"; not checked).
- Recommendation: vendor OpenBSD `bcrypt_pbkdf.c` + `blowfish.c` (ISC/BSD) as a small C target and write the container format in Swift. Test round trips against `ssh-keygen -p` on Linux.
- Also accept the ed25519 PKCS#8 PEM format (`Curve25519+PEM` in CryptoExtras).

**known_hosts / TOFU**
- On first connect, store `{host, port, keytype, base64 wire}` in app storage (file protection `.complete`) or the Keychain.
- On a later mismatch, refuse inside `validateHostKey`.
- Show the SHA256 fingerprint so the user can confirm it.

## 4. Crypto for mosh (AES-128-OCB3, RFC 7253)
**iOS / Apple**
- CryptoKit has no OCB and no raw block API.
- Use CommonCrypto: `CCCryptorCreateFromData(kCCEncrypt, kCCAlgorithmAES128, kCCOptionECBMode, key, 16, NULL, buf, sizeof buf, &ref, NULL)` once per session, then `CCCryptorUpdate` per 16·n bytes. This is exactly mosh's `USE_APPLE_COMMON_CRYPTO_AES` backend (src/crypto/ocb_internal.cc:477–560, `#define BPI 4`). OCB decryption only uses the encrypt direction.

**Linux (and Apple)**
- swift-crypto CryptoExtras: `AES.permute<Payload: MutableCollection>(_ payload: inout Payload, key: SymmetricKey) throws` and `AES.inversePermute(...)`, payload exactly 16 bytes.
- Added in swift-crypto 2.2.4 in `_CryptoExtras` (commit d330d21, 2023-01-18, "Add AES block function to CryptoExtras (#142)"). Now in the `CryptoExtras` module (`_CryptoExtras` remains as a re-export target).
- It calls `CCryptoBoringSSL_AES_set_encrypt_key` on every call, so the key schedule is rebuilt per block. Fine for tests, wasteful in production. It also adds BoringSSL to the iOS binary.

**Implementation options**
- (A) Port the RFC 7253 OCB3 algorithm to Swift on an `AESBlock` protocol: CommonCrypto ECB on Darwin, `AES.permute` on Linux. Validate with the RFC 7253 Appendix A vectors (AES-128, TAGLEN 128) and against the real mosh-server 1.4.0.
- (B) Vendor Ted Krovetz's OCB3 reference C from mosh (`ocb_internal.cc`). Licence text: "Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted..." (ISC-style, Copyright 2012 Ted Krovetz, 2022 Google LLC). It is C++-flavoured with SSE/NEON paths, and needs an AES backend: CommonCrypto on Apple; OpenSSL or nettle on Linux (or a small portable AES).
- Mosh nonce: 12 bytes = 4 zero bytes || 8-byte big-endian sequence number, with the direction bit in the top bit. Tag is 16 bytes. Key is the 22-character base64 MOSH_KEY (16 bytes).
- Patent status: Rogaway confirmed on the IETF CFRG list (thread "OCB patents are abandoned; freely usable", 2021-02-26) that he abandoned all OCB patents and placed his OCB-related IP in the public domain. His license.htm page says "I long ago stopped paying my patent-renewal fees. This wasn't an accident; it was a decision."
- Recommendation: (A) if you want pure Swift and tests on Linux. Either way, test against RFC vectors and mosh-server.

## 5. Protobuf and zlib
**Schemas**
- userinput.proto (`ClientBuffers`): UserMessage{repeated Instruction=1}; Instruction is extensions 2+ with Keystroke{bytes keys=4} as extension 2 and ResizeMessage{int32 width=5, height=6} as extension 3.
- hostinput.proto (`HostBuffers`): HostBytes{bytes hoststring=4} as extension 2, ResizeMessage as extension 3, EchoAck{uint64 echo_ack_num=8} as extension 7.
- transportinstruction.proto: Instruction{uint32 protocol_version=1, uint64 old_num=2, new_num=3, ack_num=4, throwaway_num=5, bytes diff=6, bytes chaff=7}.
- All proto2 with `LITE_RUNTIME`.
- Hand-encoding needs only varints, tag/length-delimited fields and nested extension fields encoded as plain field numbers: about 200 lines, no code generator.
- apple/swift-protobuf 1.40.0 (released 2026-11-11, Apache-2.0, Linux OK, supports proto2 extensions) can serve as a test oracle.

**zlib**
- mosh uses `compress()` / `uncompress()` (src/network/compressor.cc:44,52) with `BUFFER_SIZE = 2048*2048`. That is RFC 1950 zlib framing.
- Apple's `COMPRESSION_ZLIB`: "The encoded format is the raw DEFLATE format" (RFC 1951), encoder at level 5 only. To use it you would add the 2-byte header (0x78 0x5E/0x9C) and a big-endian Adler-32 trailer yourself, and strip them when decoding. The Compression framework also does not exist on Linux.
- Recommendation: a SwiftPM `systemLibrary` target `CZlib` with `module.modulemap { header "shim.h"; link "z" }`. libz is in the iOS SDK; on Linux it needs `zlib1g-dev`. Call `compress2` / `uncompress`, with output capped at 4 MiB.

## Recommended dependency set
| Component | Choice / version | Licence | Linux-testable | Risk |
|---|---|---|---|---|
| Terminal view | SwiftTerm exact 1.99.3 (2.0 preview) | MIT | headless core yes (CI swift:6.2-jammy) | MEDIUM: pre-2.0 API churn; deprecated UIMenuController; iOS keyboard bugs #591 #483 |
| mosh framebuffer | own Swift port of mosh Terminal::Complete (CoW) | GPL-3 if translated directly from mosh source; write it clean-room | yes | HIGH effort; licence care |
| SSH | swift-nio-ssh 0.15.1 + swift-nio ≥2.81 | Apache-2.0 | yes | MEDIUM: no kbd-interactive, no RSA, no RSA host keys |
| Crypto | swift-crypto 5.1.1 (Crypto, CryptoExtras) / CryptoKit on device | Apache-2.0 | yes | low |
| AES block | CommonCrypto ECB (iOS); CryptoExtras AES.permute (Linux/tests) | system / Apache-2.0 | yes | low |
| OCB3 | own Swift RFC 7253, or vendored Krovetz C | own / ISC-style | yes | MEDIUM: crypto correctness, must pass RFC vectors and interop |
| bcrypt_pbkdf | vendored OpenBSD bcrypt_pbkdf.c + blowfish.c | ISC/BSD | yes | low |
| Protobuf | hand-encoded (swift-protobuf 1.40.0 as test oracle) | Apache-2.0 | yes | low |
| zlib | system libz via systemLibrary module | zlib | yes (zlib1g-dev) | low |
| Avoid | Citadel (fork dependency), libssh (LGPL), Blink/VVTerm code (GPL-3) | | | |

## findings

### 1. SwiftTerm version/licence

**topic:** SwiftTerm version/licence

**claim:** Latest release is v1.99.3 (2026-11-06), a preview of 2.0; MIT; swift-tools 6.2; iOS 14 minimum

#### evidence

gh release list: 'v1.99.3 Latest 2026-11-06', 'Preview before 2.0 v1.99.0'; Package.swift '// swift-tools-version:6.2', '.iOS(.v14)'; README 'This README ... describe the new SwiftTerm 2.0 API'

**confidence:** high

### 2. SwiftTerm Linux

**topic:** SwiftTerm Linux

**claim:** Headless engine builds and is tested on Linux in CI

#### evidence

Package.swift '#if os(Linux) || os(Windows) let platformExcludes = ["Apple", "Mac", "iOS"]'; .github/workflows/xcode.yml 'linux-headless: runs-on: ubuntu-latest container: swift:6.2-jammy ... swift test --no-parallel'

**confidence:** high

### 3. SwiftTerm OSC 52

**topic:** SwiftTerm OSC 52

#### claim

Delegate methods are clipboardCopy(source: TerminalView, content: Data) and clipboardRead(source: TerminalView) -> Data? (default nil = deny); the engine accepts any selection character

#### evidence

Sources/SwiftTerm/Apple/TerminalViewDelegate.swift; Terminal.swift:4005 'func oscClipboard' ('On Apple platforms every selection maps to the system clipboard, so we accept any value')

**confidence:** high

### 4. SwiftTerm input

**topic:** SwiftTerm input

#### claim

iOS TerminalView conforms to UIKeyInput and UITextInput, handles hardware keys in pressesBegan, and has a settable inputAccessoryView whose default is TerminalAccessory

#### evidence

iOSTerminalView.swift:109 'open class TerminalView: UIScrollView, UITextInputTraits, UIKeyInput, ...'; iOSTextInput.swift:72 'extension TerminalView: UITextInput'; :3250 'open override func pressesBegan'; :1672 'public override var inputAccessoryView: UIView?'; iOSAccessoryView.swift:22 'public class TerminalAccessory: UIInputView'

**confidence:** high

### 5. SwiftTerm byte I/O

**topic:** SwiftTerm byte I/O

**claim:** Host feeds output with feed(byteArray:) and receives user input through TerminalViewDelegate.send(source:data: ArraySlice<UInt8>)

#### evidence

AppleTerminalView.swift:1313 'public func feed(byteArray: ArraySlice<UInt8>)'; TerminalViewDelegate.swift 'func send (source: TerminalView, data: ArraySlice<UInt8>)'

**confidence:** high

### 6. SwiftTerm renderer-only

**topic:** SwiftTerm renderer-only

**claim:** TerminalRenderView draws frames supplied by a TerminalExternalFrameSource and does no emulation or input

#### evidence

iOS/iOSTerminalRenderView.swift: 'The view does no terminal emulation and handles no input. Use it when the terminal runs somewhere else'; Apple/TerminalExternalFrame.swift 'func withFrame (_ body: (TerminalExternalFrame, TerminalRowStore, (Int) -> BufferLine?) -> Void)'

**confidence:** high

### 7. SwiftTerm Metal

**topic:** SwiftTerm Metal

**claim:** Metal rendering is opt-in through setUseMetal(_:) throws; the default is CoreGraphics/CoreText

**evidence:** iOSTerminalView.swift:534 'Metal rendering is **disabled by default**', :547 'public func setUseMetal(_ enabled: Bool) throws'

**confidence:** high

### 8. SwiftTerm cloning

**topic:** SwiftTerm cloning

**claim:** No API clones or serialises a whole Terminal; only BufferLine copy and read-only snapshots exist

#### evidence

grep of Terminal.swift/Buffer.swift/BufferSet.swift for clone/copy found nothing; BufferLine.swift:265 'public init (from other: BufferLine)'; TerminalContentSnapshot.swift

**confidence:** medium

### 9. mosh client state model

**topic:** mosh client state model

**claim:** The mosh client applies each diff to a copy of a stored older state chosen by old_num, so its framebuffer must be copyable

#### evidence

mosh src/network/networktransport-impl.h:98 'if ( inst.old_num() == reference_state->num )', :135 'TimestampedState<RemoteState> new_state = *reference_state;', :140 'new_state.state.apply_string( inst.diff() );'

**confidence:** high

### 10. libghostty-vt

**topic:** libghostty-vt

#### claim

libghostty-vt 1.0.0 was tagged 2026-11-06; an XCFramework is published; iOS 13+ is a Tier-1 CI target; the README still says API signatures are in flux

#### evidence

tag vt-1.0.0 commit date 2026-11-06T22:55:16Z; PACKAGING-LIBGHOSTTY.md '- ghostty-vt-VERSION.xcframework.zip', table 'Linux ... macOS 13+, iOS 13+'; README 'the API signatures are still in flux'

**confidence:** medium

### 11. swift-nio-ssh keys

**topic:** swift-nio-ssh keys

**claim:** Supports Ed25519, P-256/384/521 and SecureEnclave P-256 private keys through a closed enum; no RSA

#### evidence

Sources/NIOSSH/Keys And Signatures/NIOSSHPrivateKey.swift:39-56 'init(ed25519Key:)... init(secureEnclaveP256Key key: SecureEnclave.P256.Signing.PrivateKey)'; supportedServerHostKeyAlgorithms = 'ssh-ed25519, ecdsa-sha2-nistp384/256/521'

**confidence:** high

### 12. swift-nio-ssh auth

**topic:** swift-nio-ssh auth

#### claim

Only publickey, password and hostbased auth; keyboard-interactive is unsupported (issue #136 open); OpenSSH private-key parsing is missing (issue #66 open)

#### evidence

UserAuthenticationMethod.swift:28-37 'publicKey ... password ... hostBased'; gh issue list: '136 OPEN Support keyboard-interactive authentication', '66 OPEN Support OpenSSH Keys'

**confidence:** high

### 13. swift-nio-ssh version

**topic:** swift-nio-ssh version

**claim:** 0.15.1 released 2026-10-26; accepts swift-crypto 1.0.0..<6.0.0; ciphers are AES-GCM only

#### evidence

gh release list; Package.swift '.package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"6.0.0")'; AESGCM.swift 'aes128-gcm@openssh.com', 'aes256-gcm@openssh.com'

**confidence:** high

### 14. swift-nio-ssh public key export

**topic:** swift-nio-ssh public key export

**claim:** String(openSSHPublicKey:) and NIOSSHPublicKey(openSSHPublicKey:) write and parse the authorized_keys format

**evidence:** NIOSSHPublicKey.swift:36 'public init(openSSHPublicKey: String) throws', :461 'public init(openSSHPublicKey: NIOSSHPublicKey)'

**confidence:** high

### 15. Citadel

**topic:** Citadel

**claim:** Citadel 0.12.1 depends on a personal fork of swift-nio-ssh and adds RSA, jump hosts and openssh-key-v1 parsing with bcrypt + aes-ctr

#### evidence

Citadel Package.swift '.package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0")'; commit 2026-04-02 'use Wellz26 nio-ssh fork for Mac Catalyst compatibility'; Sources/Citadel/OpenSSHKey.swift 'case aes128ctr = "aes128-ctr"', 'case bcrypt(salt:iterations:)'

**confidence:** high

### 16. Blink stack

**topic:** Blink stack

**claim:** Blink uses hterm (WKWebView) and libssh, and is GPL-3.0

**evidence:** blinksh/blink raw branch: Resources/hterm_all.min.js; SSH/AuthMethods.swift 'import LibSSH' ... 'ssh_userauth_kbdint'; license GPL-3.0

**confidence:** high

### 17. AES single block on Linux

**topic:** AES single block on Linux

#### claim

swift-crypto CryptoExtras exposes AES.permute(_:key:) and AES.inversePermute(_:key:) for exactly 16 bytes; first shipped in 2.2.4; it re-expands the key on every call through BoringSSL

#### evidence

Sources/CryptoExtras/AES/Block Function.swift 'public static func permute<Payload: MutableCollection>(_ payload: inout Payload, key: SymmetricKey) throws', 'CCryptoBoringSSL_AES_set_encrypt_key'; commit d330d21 2023-01-18 'Add AES block function to CryptoExtras (#142)'; present in tag 2.2.4, absent in 2.2.3

**confidence:** high

### 18. AES block on iOS

**topic:** AES block on iOS

**claim:** CommonCrypto ECB with a cryptor created once per key is the block primitive mosh itself uses on Apple

#### evidence

mosh src/crypto/ocb_internal.cc:477-530 'USE_APPLE_COMMON_CRYPTO_AES ... CCCryptorCreateFromData(kCCEncrypt, kCCAlgorithmAES128, kCCOptionECBMode, ...)'

**confidence:** high

### 19. OCB C implementation licence

**topic:** OCB C implementation licence

**claim:** mosh's OCB3 reference code by Krovetz carries a permissive ISC-style licence

#### evidence

ocb_internal.cc header: 'Copyright (c) 2012 Ted Krovetz. Copyright 2022 Google LLC / Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted'

**confidence:** high

### 20. OCB patents

**topic:** OCB patents

**claim:** Rogaway abandoned all OCB patents (CFRG announcement 2021-02-26, later confirmed by him)

#### evidence

https://mailarchive.ietf.org/arch/msg/cfrg/0_vT9sVzbB4M0Bf2FfChQlvafPU/ '[CFRG] OCB patents are abandoned; freely usable'; https://www.cs.ucdavis.edu/~rogaway/ocb/license.htm 'I long ago stopped paying my patent-renewal fees. This wasn't an accident; it was a decision.'

**confidence:** high

### 21. zlib framing

**topic:** zlib framing

#### claim

mosh uses zlib compress()/uncompress() (RFC 1950 framing); Apple COMPRESSION_ZLIB writes raw DEFLATE, so it does not match without adding a header and Adler-32 trailer by hand

#### evidence

mosh src/network/compressor.cc:44 'compress( buffer, &len, ...)', :52 'uncompress(...)'; Apple doc JSON compression_zlib: 'The encoded format is the raw DEFLATE format as described in...'

**confidence:** high

### 22. mosh protobuf schemas

**topic:** mosh protobuf schemas

**claim:** All three schemas are tiny proto2 messages that use extensions; hand-encoding is practical

#### evidence

mosh src/protobufs/userinput.proto 'extend Instruction { optional Keystroke keystroke = 2; optional ResizeMessage resize = 3; }'; hostinput.proto 'optional EchoAck echoack = 7'; transportinstruction.proto fields 1-7

**confidence:** high

### 23. Keychain accessibility

**topic:** Keychain accessibility

#### claim

kSecAttrAccessibleWhenUnlockedThisDeviceOnly is Apple's recommended class for items needed only in the foreground, and it does not migrate to a new device

#### evidence

developer.apple.com doc JSON: 'This is recommended for items that need to be accessible only while the application is in the foreground ... after restoring from a backup of a different device, these items will not be present.'

**confidence:** high

### 24. swift-protobuf

**topic:** swift-protobuf

**claim:** swift-protobuf 1.40.0 released 2026-11-11, Apache-2.0

**evidence:** gh release list -R apple/swift-protobuf: '1.40.0 Release Latest 2026-11-11'

**confidence:** high

### 25. libssh2 SwiftPM

**topic:** libssh2 SwiftPM

**claim:** Lakr233/libssh2-spm builds libssh2 from source with the OpenSSL backend (Lakr233/openssl-spm ≥3.6.0), iOS 12+

#### evidence

Lakr233/libssh2-spm Package.swift '.package(url: "https://github.com/Lakr233/openssl-spm.git", from: "3.6.0")', '.define("LIBSSH2_OPENSSL")'

**confidence:** high

## recommendations

- Pin SwiftTerm exact 1.99.3 and isolate it behind a TerminalSurface protocol; re-check the 2.0 final API before release.
- Write a copyable (copy-on-write) Swift mosh framebuffer; SwiftTerm's Terminal cannot be cloned, and mosh applies diffs to old states chosen by old_num.
- Start with option (a): feed repaint bytes into SwiftTerm TerminalView to get IME, selection, links, OSC 52 and the accessory bar. Keep TerminalRenderView + TerminalExternalFrameSource as the later path that drops the second terminal state.
- Replace the default TerminalAccessory with a custom bar: subclass TerminalAccessory, or drive TerminalView.controlModifier/metaModifier directly. Work around issues #591 and #483 for hardware keyboards.
- Implement clipboardCopy(source:content:) by writing to UIPasteboard. Keep clipboardRead returning nil or behind a user prompt.
- Use swift-nio-ssh 0.15.1 directly for the bootstrap; run integration tests on Linux against a local sshd and mosh-server 1.4.0.
- Hand-write openssh-key-v1 import/export using vendored OpenBSD bcrypt_pbkdf + blowfish (ISC/BSD) and CryptoExtras AES._CTR; check interop with ssh-keygen on Linux.
- Store keys with kSecAttrAccessibleWhenUnlockedThisDeviceOnly and kSecAttrSynchronizable=false; offer Secure Enclave P-256 keys (non-exportable) alongside Ed25519.
- Implement OCB3 over an AESBlock protocol: CommonCrypto ECB on iOS with the key set up once per session, CryptoExtras AES.permute on Linux. Validate with the RFC 7253 Appendix A vectors and against a real mosh-server.
- Hand-encode the three mosh protobuf schemas and use swift-protobuf 1.40.0 only as a test oracle, if at all.
- Link the system libz through a SwiftPM systemLibrary target; do not use the Compression framework (raw DEFLATE, Apple-only).

## risks

- SwiftTerm is in a 2.0 preview (1.99.x); the API is changing and needs Xcode 26 / Swift 6.2.
- SwiftTerm iOS still uses UIMenuController (deprecated since iOS 16) for the selection menu; there are open iOS selection and keyboard bugs (#591 Option-Meta drops Shift, #483 external shortcuts, #663 double tap with mouse reporting).
- Running mosh's framebuffer and SwiftTerm side by side means two terminal states; width and grapheme mismatches between them can cause rendering drift.
- swift-nio-ssh has no keyboard-interactive (2FA), no RSA user keys and no RSA host keys; servers that offer only RSA host keys, or require 2FA, will fail.
- Citadel depends on a personal fork (Wellz26/swift-nio-ssh) and calls BoringSSL directly: supply-chain and maintenance risk.
- Hand-rolled crypto (OCB3, openssh-key-v1 parsing) can be subtly wrong; test it hard against RFC vectors and real tools.
- A Swift port of mosh's terminal or framebuffer code may be a derivative of mosh's GPL-3 code; decide on clean-room versus GPL licensing early.
- libghostty-vt 1.0.0 is five days old and has no renderer; the full libghostty API is unstable and needs Zig and macOS to build.
- Secure Enclave keys are device-bound and cannot be exported or backed up; users must be told that losing the device means re-provisioning the key on servers.

## unverified

- Whether SwiftTerm's OSC parser limits the length of OSC 52 payloads.
- Whether BoringSSL's AES_encrypt, used by CryptoExtras AES.permute, uses ARMv8 or AES-NI hardware instructions.
- libssh2's exact auth method support (keyboard-interactive, sign callbacks for Secure Enclave keys, passphrase-protected OpenSSH key import with the OpenSSL backend); not read from source in this pass.
- Licence and quality of Comraich/swift-bcrypt-pbkdf.
- Whether mosh 1.4.0 passes OSC 52 from the remote application through to the client framebuffer and on to the client's outer terminal, and how a mosh-diff-driven SwiftTerm would receive it.
- Whether swift-crypto exports the CCryptoBoringSSL product unconditionally to downstream packages (Package.swift line 71 sits inside a condition).
- Whether full libghostty (with its renderer) has a stable embedding API on iOS; VVTerm shows it can be done but its build was not inspected.
- Whether CryptoKit Curve25519 signatures being non-deterministic on Apple affects any test that compares signatures across platforms.

