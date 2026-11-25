# M10 groundwork: the test tools

A map of the tools a differential test of mosh's prediction engine would use, as they
are on 2026-11-18. Every fact has a file:line. mosh paths are relative to
`.refs/mosh/src/` (mosh 1.4.0) unless they start with `/opt/mosh-src` (the built tree in
the dev container, looked at with `scripts/dev.sh bash -c 'ls ...; nm ...'`). No design
here beyond the list at the end.

## 1. Two oracles, not one

The repository has two programs that link mosh's own code:

| Tool | Source | Built by | Protocol | Used by |
|---|---|---|---|---|
| `mosh-oracle` | `Tools/mosh-oracle/main.cc` | `Tools/mosh-oracle/build.sh` (by hand, or by the scripts) | files in, JSON lines out | `scripts/corpus-check.sh`, `scripts/record-golden.sh`, `check_format.py`; no Swift test |
| `moshref` | `Tests/MoshTerminalTests/Support/moshref.cc` | `Support/build-moshref.sh`, run by the test process itself | commands on stdin, text dump on stdout | `MoshCrossCheckTests`, `DisplayDiffCrossCheckTests` (through `MoshRef.swift`) |

The M10 task names `Tools/mosh-oracle` (docs/CLOUD.md:353-356), but the one that is
already a live, per-test, command-driven reference is `moshref`. Both are described.

### 1.1 Tools/mosh-oracle: build and link

- Build: `scripts/dev.sh Tools/mosh-oracle/build.sh`, output
  `/work/.build/mosh-oracle/mosh-oracle` in the build volume (build.sh:2-5,
  README.md:24). `MOSH_SRC` defaults to `/opt/mosh-src` (build.sh:15).
- It refuses to run without the four archives `statesync/libmoshstatesync.a`,
  `terminal/libmoshterminal.a`, `protobufs/libmoshprotos.a`, `util/libmoshutil.a`
  (build.sh:18-23).
- Compile: `c++ -std=gnu++11 -DHAVE_CONFIG_H`, include dirs `src/include`, `util`,
  `terminal`, `statesync`, `protobufs` (not `network`, not `crypto`), mosh's own
  hardening and `-fno-default-inline -pipe -g -O2`, plus `-fno-access-control` to read
  private members without changing layouts (build.sh:7-11, 27-34; README.md:36-40).
- Link: `main.o` + the four archives + `-lprotobuf -ltinfo -lz`, as a PIE
  (build.sh:35-38). `libmoshnetwork.a` and `libmoshcrypto.a` are not linked.
- The `/opt/mosh-src` tree comes from `git clone --depth 1 --branch mosh-1.4.0` and
  `./autogen.sh && ./configure && make` in the image (docker/Dockerfile.dev:13-14).
- Needs the `en_US.UTF-8` locale and dies without it (main.cc:1365-1369,
  README.md:53).
- On 2026-11-18 the main checkout's build volume holds no built oracle
  (`ls /work/.build/mosh-oracle/` → no such directory); the scripts build it on demand
  when it is missing or older than main.cc (corpus-check.sh:42-44,
  record-golden.sh:31-33).

### 1.2 Tools/mosh-oracle: commands and JSON

Command line (main.cc:9-19, usage at main.cc:1351-1361, dispatch main.cc:1375-1420,
table README.md:44-51):

| Mode | Does |
|---|---|
| `gen --session FILE --out DIR [--allow-few-old-bases]` | server simulation of `session.jsonl`; writes `meta.json`, `instructions.jsonl`, `server.jsonl`, then `expected.jsonl` |
| `apply DIR [--no-verify-ops] [--full]` | client simulation of `instructions.jsonl`, prints `expected.jsonl` |
| `server DIR [--full]` | server simulation only, prints `server.jsonl` |
| `screen DIR N\|last [--plain] [--server]` | human-readable state |
| `selftest` | dump completeness |
| `respond W H` | co-process of the pty recorder, answers DA/DSR |

Usage errors exit 64 (main.cc:1360). It is a batch tool: it reads whole files, not a
command stream. Formats (Tools/mosh-oracle/FORMAT.md):

- Files of a case and who writes them: FORMAT.md:11-21. `moshcli --record` writes only
  `meta.json` and `instructions.jsonl` (FORMAT.md:27-28; Sources/moshcli/Connect.swift:18,
  Sources/moshcli/Recorder.swift:1-2).
- `session.jsonl`: first line `{"width":W,"height":H}`, then one of `bytes_b64`,
  `resize`, `echo_ack` per line (FORMAT.md:39-56).
- `instructions.jsonl`: `old_num`, `new_num`, `diff_b64`, `ops` (FORMAT.md:58-101).
- State lines (`expected.jsonl`, `server.jsonl`): delta rule and every key with its
  mosh field (FORMAT.md:102-274); fields not dumped (FORMAT.md:417-429).
- Own JSON reader and writer in main.cc (`JV` main.cc:242, `JSONReader` main.cc:277,
  `make_dump` main.cc:558, `delta_line` main.cc:638).
- Time already appears once: `session_step` drives the server's echo ack with a
  `fake_clock` passed to `register_input_frame(n, now)` and `set_echo_ack(now)`, 1000 ms
  apart (main.cc:880-906). That works because `Complete` takes `now` as a parameter;
  it reads no clock.

### 1.3 Who calls mosh-oracle, and skipping

- No Swift test runs it. The corpus files are committed and read by
  `Tests/MoshTestSupport/GoldenCorpus.swift` (lines 2, 6: "neither oracle nor mosh, so it
  runs on a Mac too"); `Tests/MoshTerminalTests/CorpusTests.swift:10` says the same.
  Users of the corpus: `CorpusTests` (testClientStatesEqualTheOracle and three more,
  CorpusTests.swift:745-789), `CorpusDisplayTests`,
  `Tests/MoshSessionTests/TerminalRemoteStateTests.swift:146`. Nothing to skip.
- `scripts/corpus-check.sh` (whole file, 101 lines): re-runs itself through
  `scripts/dev.sh` when `/opt/mosh-src` is absent (lines 20-22); builds the oracle if
  needed (42-44); per case `apply` must equal the committed `expected.jsonl` and `server`
  the committed `server.jsonl` (59-73); `--gen` runs `gen` twice and compares all four
  files, then `check_format.py` (74-86, 93-95); `--regen` rewrites `syn-*` from
  `synthetic.py` and runs `gen` in place (46-53); `--sizes` against a 10 MB budget
  (28-40). Exit 0 only if every case passes (96-101).
- Where the corpus comes from: `syn-*` from `Tools/mosh-oracle/synthetic.py`
  (README.md:16, corpus-check.sh:47); `rec-*` from `scripts/record-golden.sh`, which
  plays `Tools/mosh-oracle/recordings/NAME.rec` in a pty through `scripts/pty-record.py`
  and runs `gen` (record-golden.sh:2-14; README.md:162-182). Recording again gives new
  files: timing and clocks are not fixed (README.md:180-182). 38 cases, 2916 states
  (README.md:228).

### 1.4 moshref: the stdin-driven reference

- Commands on stdin, one per line: `new W H`, `bytes HEX`, `resize W H`, `echoack N`,
  `userbytes HEX`, `save`, `drop`, `dump`, `cmp`, `reply`, `diff I [E B T]`,
  `applydiff I` (moshref.cc:10-27); loop on `std::getline` (moshref.cc:272). Output
  blocks end with `=== end`; the dump format is `TerminalState.debugDump()` of the
  port (moshref.cc:2-5).
- Private members via `#define private public` / `protected public` around
  `completeterminal.h` (moshref.cc:29, 52-56), not `-fno-access-control`.
- Build: `g++ -std=gnu++11 -O1 -g -DHAVE_CONFIG_H -Wall`, the same include dirs and
  the same four archives as mosh-oracle (build-moshref.sh:13-21).
- Skip and build in the test: `MoshRef.tool` checks for
  `$MOSH_SRC/src/terminal/libmoshterminal.a` and returns `XCTSkip("no built mosh tree
  ...")` when it is missing; otherwise runs `build-moshref.sh` into a per-process temp
  dir, a build failure is a test failure, not a skip (Tests/MoshTerminalTests/MoshRef.swift:48-67).
  Tests call `MoshRef.reference(ops)`, which throws that skip (MoshRef.swift:70-71),
  writes the script to a temp file and reads stdout from a temp file
  (MoshRef.swift:90-104). The whole file is `#if os(Linux)` (MoshRef.swift:5).
- The Swift side of the same script is `MoshRef.port(ops)` (MoshRef.swift:108-150).
  Random inputs come from a seeded generator (Tests/MoshTerminalTests/TerminalFuzz.swift:1-3,
  `init(seed:)` at :39); the case count is `MOSH_FUZZ_CASES`
  (MoshCrossCheckTests.swift:244, DisplayDiffCrossCheckTests.swift:20).

## 2. Can an oracle drive mosh's PredictionEngine?

Yes, from what is on disk; nobody has tried to link it.

- `/opt/mosh-src/src/frontend/` holds `terminaloverlay.cc` (26276 bytes),
  `terminaloverlay.h` and the built `terminaloverlay.o` (1411272 bytes), next to
  `stmclient.o`, `mosh-client.o`, `mosh-client` (`scripts/dev.sh ls -la`). It is a plain
  object, not in any archive: `mosh_client_SOURCES = mosh-client.cc stmclient.cc
  stmclient.h terminaloverlay.cc terminaloverlay.h` (/opt/mosh-src/src/frontend/Makefile:343).
- It was compiled with exactly the flags build.sh copies, plus `-I./../network
  -I./../crypto` (`make -n -W terminaloverlay.cc terminaloverlay.o` in
  `/opt/mosh-src/src/frontend`: `c++ -std=gnu++11 -DHAVE_CONFIG_H -I. -I../../src/include
  -I./../statesync -I./../terminal -I./../network -I./../crypto -I../protobufs
  -I./../util -D_DEFAULT_SOURCE -D_XOPEN_SOURCE=600 -Wall -fno-strict-overflow
  -D_FORTIFY_SOURCE=2 -fstack-protector-all -Wstack-protector --param ssp-buffer-size=1
  -fPIE -fno-default-inline -pipe -g -O2`). So either the .o or the .cc can be used.
- Undefined symbols of `terminaloverlay.o` (`nm -C --undefined-only`, libc/libstdc++
  left out): `Network::timestamp()`; `Terminal::Renditions::set_background_color(int)`,
  `set_foreground_color(int)`, `Terminal::Cell::reset(unsigned)`, `Terminal::Cell::Cell(unsigned)`,
  `Terminal::DrawState::move_col(int,bool,bool)`, `move_row(int,bool)`; typeinfo of
  `Parser::CSI_Dispatch`, `Esc_Dispatch`, `Print`, `Execute`; libc `wcwidth`, `wcrtomb`,
  `swprintf`, `snprintf`. Everything except `Network::timestamp()` is in
  `libmoshterminal.a`, which both oracles link already.
- `Network::timestamp()` is defined in `network.o` of `libmoshnetwork.a`
  (`nm`: `T Network::timestamp()`), as `return frozen_timestamp();`
  (network/network.cc:596-599). `network.o` in turn needs nine `Crypto::` symbols
  (`nm --undefined-only network/libmoshnetwork.a | grep -c Crypto::` = 9), i.e.
  `libmoshcrypto.a` and `-lssl -lcrypto` (the client's `LDADD`,
  frontend/Makefile:341, `CRYPTO_LIBS = -lssl -lcrypto` :226).
- Compiling against `terminaloverlay.h` needs more include dirs than build.sh has: it
  includes `network.h`, `transportsender.h`, `parser.h`, `terminalframebuffer.h`
  (frontend/terminaloverlay.h:36-39); `network.h` includes `crypto.h` (network/network.h:47),
  which includes `ae.h` (crypto/crypto.h:36); `transportsender.h` includes
  `transportinstruction.pb.h`, `transportstate.h`, `transportfragment.h`, `prng.h`
  (network/transportsender.h:40-44). So `-I network -I crypto` (headers only; no extra
  link unless `network.o` is pulled).
- The engine's public API (frontend/terminaloverlay.h): `set_display_preference`,
  `set_predict_overwrite` (:272-273), `apply(fb) const` (:275), `new_user_byte(char, fb)`
  (:276), `cull(fb)` (:277), `reset()` (:279), `set_local_frame_sent/acked/late_acked`
  (:281-283), `set_send_interval` (:285), `wait_time()` (:287-292). Thresholds are
  constants at :203-213. Private state the oracle could dump: `prediction_epoch`,
  `confirmed_epoch` (:230-231), `flagging`, `srtt_trigger`, `glitch_trigger`,
  `last_quick_confirmation` (:237-240), `send_interval` (:248), `last_height/width`
  (:250), plus `overlays` and `cursors` (:242). `OverlayManager::apply` = `cull`, `apply`,
  then the notification and title engines (frontend/terminaloverlay.cc:333-340).
- No randomness in the engine: `grep rand\|getenv` in terminaloverlay.cc finds only
  `human_readable_duration` and a static string (terminaloverlay.cc:169, 230).

How mosh-client calls it (the call order a test must replay):

- Per user read: `set_local_frame_sent(net.get_sent_state_last())`, a read over 100
  bytes resets and is not predicted, otherwise `new_user_byte(byte, local_framebuffer)`
  per byte (frontend/stmclient.cc:322-334). Note: `local_framebuffer` is the last
  frame drawn, with overlays.
- Per network receive: `set_local_frame_acked(get_sent_state_acked())`,
  `set_send_interval(send_interval())`,
  `set_local_frame_late_acked(latest_remote_state.get_echo_ack())`
  (stmclient.cc:290-301).
- Per frame: `new_state = latest remote fb; overlays.apply(new_state); display.new_frame(...)`;
  `local_framebuffer = new_state` (stmclient.cc:267-288).
- On a resize: `reset()` (stmclient.cc:417-418). The main loop waits at most
  `overlays.wait_time()` (stmclient.cc:444).
- Mode from `MOSH_PREDICTION_DISPLAY` (always, never, adaptive, experimental) and
  `MOSH_PREDICTION_OVERWRITE=yes` (frontend/mosh-client.cc:174-179,
  frontend/stmclient.h:109-124).
- mosh's own prediction test is end to end through tmux (`--predict=always`,
  tests/prediction-unicode.test:1-25, :92), not a unit harness.

## 3. Time

The engine reads `timestamp()` at terminaloverlay.cc:160-161 (constructor of
`NotificationEngine`), :184, :307, :316, :453, :663, :866 and in inline header code
(terminaloverlay.h:168, 188, 194). The `timestamp()` it calls is `Network::timestamp()`
(the only time symbol in its undefined list, section 2), which returns
`frozen_timestamp()` (network/network.cc:596-599). `util/timestamp.h:38-39` declares
only `freeze_timestamp()` and `frozen_timestamp()`; `frozen_timestamp()` returns the
cached `millis_cache` and fills it on first use (util/timestamp.cc:61-70);
`freeze_timestamp()` reads `CLOCK_MONOTONIC` (`HAVE_CLOCK_GETTIME 1`,
/opt/mosh-src/src/include/config.h:14) into the cache (timestamp.cc:72-92). In
mosh-client the cache is refreshed by `Select::select` (util/select.h:187) and after a
network error sleep (stmclient.cc:567). So the engine's clock moves only when someone
calls `freeze_timestamp()`.

Today neither oracle pulls any time symbol: no archive they link has an undefined
`timestamp`, `Network::` or `Crypto::` symbol (`nm -A --undefined-only` over
statesync, terminal, protobufs, util), and `util/timestamp.o` is only pulled to satisfy
`freeze_timestamp`/`frozen_timestamp` (its only global symbols, `nm`).

Ways to run the engine at chosen times:

| Way | How | Evidence it is possible |
|---|---|---|
| A. Own `Network::timestamp()` | define `uint64_t Network::timestamp(void)` in the oracle's .cc returning a variable the command stream sets; link `terminaloverlay.o` (or .cc) with the existing four archives | `Network::timestamp()` is the engine's only clock symbol; with it defined in `main.o` the linker never extracts `network.o`, so no crypto or OpenSSL. If something later pulls `network.o` the link fails with a duplicate symbol, it does not silently pick one. Declaration comes from `network.h` (network/network.h:54) |
| B. Own `frozen_timestamp()`/`freeze_timestamp()` | link `libmoshnetwork.a` + `libmoshcrypto.a` + `-lssl -lcrypto` for the real `Network::timestamp()`, define the two util functions in the oracle so `util/timestamp.o` is not extracted | timestamp.o defines only those two (`nm`); costs the crypto link that A avoids |
| C. Patched copy of util/timestamp.cc | compile a copy with a settable `millis_cache` instead of the archive member, plus network.o as in B | same as B; no advantage over B |
| D. Real sleeps | link the real network.o and timestamp.o, `nanosleep`, then call `freeze_timestamp()` before each engine call | works but the times are only approximate and the engine still sees a value frozen at the last `freeze_timestamp()`; thresholds of 20-80 ms (terminaloverlay.h:203-207) make outcomes flaky |

A `LD_PRELOAD` shim cannot replace `Network::timestamp()` (static archive, resolved at
link time). libfaketime on `clock_gettime` would act on D only; it is not in the image
(not checked further). Precedent in the oracle for an explicit clock: `fake_clock`
(main.cc:880-906).

## 4. moshcli

Subcommands (Sources/moshcli/main.swift:7-13): `handshake`, `connect` (run a script),
`resume`, `bootstrap`, `soak`.

Script language (Sources/moshcli/ScriptCommand.swift:55-82, parser :107-191): `type
TEXT` and `key NAME` (both are keystrokes, `.type(bytes)`), `resize W H`, `wait-ack
[MS]`, `expect TEXT MS` (host bytes), `expect-screen TEXT MS` (newest rendered screen),
`settle MS`, `sleep MS`, `rebind`, `quiesce [--after-send]`, `resume`, `resume-mem
[--drop-first N]`, `dump-screen FILE`, `dump-bytes FILE`, `shutdown`. Escapes
`\n \r \t \e \\ \s \xHH` (ScriptCommand.swift:57). Run by `runScript`
(Sources/moshcli/Connect.swift:117-145). Exit codes: Sources/moshcli/ScriptedSession.swift:20-39.

Shared options: `SessionOptions.names` = `--host --port --key --width --height
--seq-log` + `SessionTuning.names` = `--server-size --no-reply-ms --loss`
(Sources/moshcli/SessionOptions.swift:49-50, 84). `connect`, `soak` and `bootstrap`
share `SessionTuning` (SessionOptions.swift:82).

How `--loss` drops datagrams (the model for a client-side delay):

- Parsed as 0...99 (SessionOptions.swift:101), passed to
  `WireTap(seqLogPath:lossPercent:)` (Connect.swift:85, Soak.swift:60).
- `WireTap.open` wraps every socket the session makes in `TappedTransport`
  (Sources/moshcli/WireTap.swift:66-72); the session gets it through `makeTransport`
  (ScriptedSession.swift:211, the `MoshSession(... makeTransport:)` call at :204-212).
- Outgoing: `TappedTransport.send` asks `willSend`, which logs the sequence number,
  applies `--drop-first`, then drops with `Int.random(in: 0..<100) < lossPercent`
  (WireTap.swift:77-98, 133-137). Incoming: the receive handler calls `didReceive`, same
  test (WireTap.swift:101-110, 123-131). Dropped datagrams count as `lost`
  (WireTap.swift:48-49). The random source is not seeded.
- So a delay fits in `TappedTransport`: hold the datagram in `send` and in the receive
  handler and pass it on later; `--delay` would join `SessionTuning.names`.

Where a `--predict` switch would attach:

- Option: `SessionTuning` (SessionOptions.swift:84-114), so all three commands get it.
- Keystrokes reach the session at `ScriptedSession.type` → `SessionDriver.type` →
  `MoshSession.type` (ScriptedSession.swift:341-344, :62-67;
  Sources/MoshSession/MoshSession.swift:291-293).
- The screen `expect-screen` and `dump-screen` read is `MoshSession.screen()`, the
  newest remote state without any overlay (MoshSession.swift:309-312, via
  ScriptedSession.swift:386-399, 534-544 and SessionDriver.screen :76-81). PLAN puts the
  overlay on "a copy of the newest framebuffer before `DisplayDiff`" (docs/PLAN.md:973-974).
- Engine inputs available today: `acknowledgedStateNumber()` (MoshSession.swift:324,
  MoshConnection.swift:326), `smoothedRoundTripTime()` (MoshSession.swift:319),
  `RTTEstimator.sendInterval` = ceil(SRTT/2) within 20...250 (Sources/MoshTransport/RTTEstimator.swift:52-57,
  mosh: network/transportsender-impl.h:73), `lastSentStateNumber` in the core
  (Sources/MoshTransport/TransportCore.swift:892; not exposed by `MoshSession`), echo ack
  `TerminalRemoteState.echoAck` (Sources/MoshSession/TerminalRemoteState.swift:86-87).

## 5. scripts/itest.sh and scripts/soak.sh

`scripts/itest.sh` (112 lines):

- Header lists every case (itest.sh:6-28). The mosh cases go to `mosh_itest`, which
  runs `scripts/itest-mosh.sh` in the dev container (or natively with
  `ITEST_NO_CONTAINER=1`) (itest.sh:38-44, 85-87). `all` lists them again
  (itest.sh:101-102); usage line itest.sh:109.
- Adding `predict` touches: the header, the case pattern `handshake|hello|...|soak` at
  :85, `all` at :102, usage at :109.

`scripts/itest-mosh.sh` (407 lines), where the cases live:

- Builds moshcli unless `ITEST_SKIP_BUILD=1` (itest-mosh.sh:10-14).
- `start_server CMD...` starts a detached `mosh-server new -i 127.0.0.1 -- CMD` with
  stdin `/dev/null` (so 80x24) and sets `PORT`, `MOSH_KEY` (exported), `PID`
  (itest-mosh.sh:28-44). `server_alive` (:46-49), `fail` (:51-54).
- `run_script EXPECTED_EXIT NAME [moshcli options]` writes stdin to
  `$TMP/NAME.script`, runs `moshcli connect --host 127.0.0.1 --port $PORT --script ...
  --quiet`, checks the exit code (itest-mosh.sh:56-69).
- A case is a `test_NAME()` function: e.g. `test_hello` = `start_server sh`, a heredoc
  script piped into `run_script`, then greps on the dumped screen and bytes
  (itest-mosh.sh:78-119). Dispatcher: `for TEST in "$@"; case ... NAME) echo "== NAME";
  test_NAME ;;` then `PASS $TEST` (itest-mosh.sh:395-407); usage at :395.
- So `predict` = a `test_predict()` plus one dispatcher line plus the itest.sh lines.

`scripts/soak.sh` (97 lines): mosh-server running `tmux -L $SOCKET` (status off),
`moshcli soak ... --seq-log --screen-out --settle-ms "$@"`, then the client screen must
equal `tmux capture-pane -p` padded to the height (soak.sh:48-63, 75-93). Extra
arguments pass through to `moshcli soak` (soak.sh:6, 63), so a `--predict`/delay option
can be tried there without editing it. itest `soak` calls it twice (itest-mosh.sh:331-336).
`scripts/netem.sh` runs it under tc netem (soak.sh:9-11).

## 6. docs/PLAN.md and other mentions

M10 text, quoted in full (docs/PLAN.md:973-974):

> **M10 — Prediction.** Port of mosh's `terminaloverlay.cc` (about 930 lines). The
> overlay is applied to a copy of the newest framebuffer before `DisplayDiff`.

Its verification row, the milestone table (docs/PLAN.md:837-838, 849):

> | M10 | Prediction | yellow, phone | Typed characters appear at once on a 300 ms link |

The Verification section (docs/PLAN.md:1037 onward) has no row for prediction or local
echo (grep of `predict`, `local echo`, `M10` there finds none). Other rows in PLAN:

- docs/PLAN.md:59-61: "Not in Build 1: ... local echo prediction, key import, ..."
- docs/PLAN.md:107: "| Later, if you want | Resume after a crash at any instant; local echo; TestFlight | |"
- docs/PLAN.md:222: "After v1: stage 2 resume (M9), local echo prediction (M10)."
- docs/PLAN.md:862: "| Later, if wanted | M9, M10, TestFlight | Resume after a kill at any instant; local echo; builds away from charlie |"

Elsewhere in docs/ (`grep -rni 'predict\|local echo' docs App`, excluding this folder):

- docs/CLOUD.md:348, 353-356: M10 stopped once for usage; the task "port of mosh's
  `terminaloverlay.cc` with differential tests against mosh's own engine through
  `Tools/mosh-oracle`, `moshcli --predict` and a client-side delay, `scripts/itest.sh
  predict`". docs/CLOUD.md:393-394: this groundwork.
- docs/research/03-mosh-terminal.md:169 (paste heuristic), :171-199 (section 5,
  prediction engine and notification bar), :282 ("unit-test with synthetic ack and
  echo-ack timelines. Use src/tests/prediction-unicode.test as a reference"), :474-480
  (engine inputs: local_frame_sent, local_frame_acked, late_acked = echo_ack,
  send_interval), :505 (native banner instead of the row-0 bar).
- docs/research/10-first-design.md:123, 168, 204, 454, 834-846 (prediction deferred to
  an optional M10; "overlay applied to a copy of the newest framebuffer before
  DisplayDiff").
- docs/research/05-swift-libs.md:83 (value type that supports speculative local echo).
- docs/research/01-mosh-wire.md:160 (`MOSH_PREDICTION_DISPLAY`).
- docs/research/04-prior-art.md:41-42, 128, 238 (Blink's `predict_mode`,
  `--predict-overwrite` in 1.4.0).
- docs/research/14-revised-plan-review.md:479, 483 (milestone count only).
- docs/research/06-ios-platform.md:156, 631: iOS "inline prediction" keyboard trait,
  not mosh's.
- App/: no match.

## 7. What a differential test of the engine needs

Inputs to generate (one timeline, fed to mosh's engine and the port alike):

1. A starting framebuffer (size, contents, cursor), from host bytes through
   `Complete` as moshref already does.
2. Events with a time each: user bytes (one `new_user_byte` per byte, with the
   current `local_framebuffer`; reads over 100 bytes reset instead, stmclient.cc:325-334);
   `set_local_frame_sent(n)`; network receives that set `local_frame_acked`,
   `send_interval`, `local_frame_late_acked` (echo ack); new server framebuffers
   (host bytes that echo, partly echo, or do something else); resizes (`reset`); frames
   (`cull` + `apply` on a copy of the newest server fb, then that becomes
   `local_framebuffer`).
3. Settings: display preference (Always, Never, Adaptive, Experimental) and
   `predict_overwrite`.
4. Byte classes: printable ASCII, multibyte UTF-8 and wide characters (the
   prediction-unicode bug), backspace 0x7f, CR, CSI C/D and SS3 arrows, other controls,
   ESC sequences cut across reads.
5. Timing that crosses each threshold: send_interval around 20/30 and 50/80 ms,
   pending ages around 250 and 5000 ms, confirmations 150 ms apart
   (terminaloverlay.h:203-213).

Outputs to compare after every event:

1. The framebuffer after `apply` (full dump, as moshref's `dump`), including
   underline renditions of flagged predictions and the predicted cursor.
2. Engine state: epochs, `flagging`, `srtt_trigger`, `glitch_trigger`,
   `last_quick_confirmation`, `active()`, `wait_time()`, and the overlay rows and cursor
   moves with their tentative/expiration fields (readable through
   `-fno-access-control` or `#define private public`).
3. Optionally the `Display::new_frame` bytes from the previous drawn frame to this one.

What must be deterministic:

1. The clock: the engine's `Network::timestamp()` replaced by the oracle (way A in
   section 3) and the port's clock injected, both set from the timeline.
2. The input generator: seeded, as TerminalFuzz.swift is; nothing from `Int.random`.
3. Locale and widths: `en_US.UTF-8` glibc `wcwidth` on the mosh side (main.cc:1365,
   FORMAT.md:8-9) and the port's table from `scripts/gen-wcwidth.c`.
4. No network in the differential test: transport numbers come from the timeline.
   Live checks (moshcli `--predict` with a client-side delay, itest `predict`) are a
   separate, non-differential layer.
