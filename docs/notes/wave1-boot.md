# wt/boot working notes (M4: MoshKeys, MoshBootstrap)

Read this first if you continue this work. The integrator removes this file on merge.

## State (round 3, 2026-11-12): FINISHED

- [x] MoshKeys: KeyGenerator, OpenSSHPublicKey, Fingerprint, KeyStore, FileKeyStore, unit tests
- [x] MoshBootstrap pure parts: ShellQuote, MoshServerCommand, ConnectLineParser, KnownHosts,
      BootstrapError + classify, IdentityCheck parser, ConnectTimeoutPolicy, KexInit parser,
      AuthorizedKeys script, unit tests
- [x] MoshBootstrap SSH layer on swift-nio-ssh: SSHConnection (connect, run, close),
      startMoshServer, installAuthorizedKey, readIdentity / checkIdentity / killServer,
      ServerProbe.probe, SSHBootstrap.run / runReplacing
- [x] scripts/itest.sh bootstrap (one dev.sh --root call; scripts/itest-sshd.sh inside the
      container starts four sshd variants and runs the tests as ubuntu)

Proof (all run in round 3, after the last code change):

- `scripts/itest.sh bootstrap`: 108 tests, 0 failures, 0 skipped, of which 33 are the
  integration tests in SSHBootstrapIntegrationTests (three runs in a row green).
- `scripts/dev.sh swift test -j 4`: 137 tests, 33 skipped (the gated ones), 0 failures.
  97 unit tests: 22 in MoshKeysTests, 75 in MoshBootstrapTests. No compiler warnings in the two
  modules, their tests or the helpers.

Nothing is in progress. Left for later waves (not part of this task):

- `moshcli bootstrap` (wave 2) and the "MOSH CONNECT seen, no UDP reply in 15 s" row: the
  case `BootstrapError.udpBlocked(port:)` and its message exist; raising it needs the transport.
- The `#if canImport(Network)` branches (NIOTransportServices connect, WaitingForConnectivity)
  have never been compiled: first build on the Mac will tell.
- KeychainKeyStore is app code.

## Things learned in round 3

- script(1) gives its pty no size when its standard input is not a terminal, and mosh-client
  aborts on a 0x0 screen (`s_height > 0`). Test helpers that run mosh-client under script must
  set a size first: `script -qfc "stty rows 24 cols 80; exec mosh-client ..." /dev/null`.
- A command WITH a pty (the server start) gets SIGHUP when its channel is closed after a
  timeout, so a hung `mosh-server` stand-in is gone afterwards. A command WITHOUT a pty
  (`SSHConnection.run`) is not signalled by sshd when the channel closes; it lives on until
  it ends by itself or writes to the closed pipe. Our own remote commands (ps, kill, the
  authorized_keys script) all end by themselves.

## Decisions (and why)

- Public API has no NIOSSH types (`LoginMethods`, `SSHFailureKind` mirror them), so test
  targets and the app need no NIOSSH import and Package.swift stays untouched.
- Server path field: empty = `mosh-server`; no slash = program name; path whose last component
  starts with `mosh-server` = program; any other path = directory, `/mosh-server` appended.
  Always ONE quoted word, never a command with arguments. Leading `~/` stays unquoted.
- Remote command: mosh-server execvp's the words after `--` (no shell), so the command goes as
  one quoted word to a shell inside the session. Default `.loginShell`:
  `-- sh -c 'exec "${SHELL:-/bin/sh}" -lc "$1"' sh '<cmd>'` (profile is read, so PATH is the
  login PATH; needed for Homebrew tmux on a Mac). Alternative `.sh`: `-- sh -c '<cmd>'`.
- mosh-server starts the remote command only after the FIRST client datagram
  (`child_released` in mosh-server.cc). The tmux integration test therefore runs the real
  `mosh-client` (in the image) for a moment to release it.
- Identity check command gets `TZ=UTC0` in front (deviation from the plan): lstart is local
  time otherwise, wrong by an hour after a DST change, and not an absolute time.
- procps prints user names longer than 8 chars as 7 chars + `+`; `userMatches` accepts that as
  a prefix match. The itest user name is long on purpose to exercise it.
- Every remote script is wrapped in `sh -c '<one line>'`: login shells may be fish or csh, and
  csh cannot quote a line break.
- KnownHosts: one key per host:port; any different key (even another type) is "changed".
  An unreadable file is an error, never an empty store.
- swift-nio-ssh reports every negotiation failure as `keyExchangeNegotiationFailure`. To tell
  "RSA host keys only" apart, a pipeline handler in front of NIOSSHHandler reads the server's
  clear-text KEXINIT (`ServerKexInitParser`).
- Shared test helpers added (new files only): `ToolRunner`, `ScratchDirectory`.
