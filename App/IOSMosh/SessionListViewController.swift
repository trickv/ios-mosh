import MoshResume
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The start screen: the host list with each host's sessions under it (docs/PLAN.md M5 and
/// M8, Design 4 "Session list"; docs/notes/multi-session/DESIGN.md 4.1, step 4). Tap a host to
/// start a new session on it; tap a session row to open that session; the info button or a
/// swipe edits a host; a swipe deletes it. "+" adds a host and "Keys" shows the device key.
///
/// - The rows are `SessionList.rows`: every saved host, each followed by every session record
///   linked to it (oldest first), each with its state (`ListedSessionState`) and when it was
///   last used. Records of no saved host (a debug session, a deleted host) are listed in a
///   second section.
/// - A tap on a host always starts a new session, also when the host has sessions (DESIGN.md
///   3.1, step 10); such a host shows a small "+" beside its info button, so that this is plain.
///   A tap on a session row that is not live, not being ended and not "ended" asks the
///   coordinator (`SessionLauncher.coldStart` for that record): resumed, a fallback to a new
///   session, or "try again later". The state shown never decides that; a record that turns out
///   ended, not a record, or gone starts nothing (3.2 S6, S9; review-steps-2-4.md R24-S5).
/// - Every tap goes through one `open` (4.5): taken only when `SessionActivity.Busy` allows it
///   and no terminal screen is open; then "opening" is set (a second tap is dropped, S3) and the
///   launch's "try again later" wait is dropped with its line (2.2, step 11), the
///   open waits until every release asked for before it has returned (`settled()`, G2: a row
///   being saved opens once its park has closed), asks the gate (`OpenGate`, G3) and, in the same
///   main-actor turn, makes the screen, loads it and pushes it. "Opening" is cleared when no
///   screen was pushed and when the list appears again.
/// - Swiping a session row from the leading edge offers "End Session" (a parked row through mosh's
///   own shutdown, `SessionEnder`; a dead or ended one by the server stopped over SSH after the
///   identity check; the record removed if the rules allow) and "Forget" (the record, key and
///   link removed without contacting the host), each after a confirmation. A
///   host row has no leading swipe (DESIGN.md, reading 7). A drag towards a side without
///   actions opens nothing (`SidewaysTouchCanceller`, step 4c).
/// - A session row's first line is its preview (`SessionPreview`: the window title, else the last
///   line of its stored screen), its second line the state line (`SessionList.stateLine`); a
///   green dot marks the session looked at last (DESIGN.md 4.1 to 4.3, step 5).
/// - The list reads the records again every second while it is on screen (4.4), and at once when
///   `SessionActivity` changes (`onChange`: an end, a release or an open began or finished;
///   DESIGN.md step 8). While a row's swipe actions are open nothing reads, reconfigures or
///   reloads the table, on any path (the tick, an end, Forget, Delete, the editor, appearing):
///   what wants it waits and is done once when the swipe has closed, after UIKit's own call that
///   ends the swipe has returned (step 5c). Otherwise, when the rows are the same rows in the
///   same order, the visible cells are reconfigured in place; when rows came or went, the redraw
///   (and the model the taps act on) waits while one of the list's alerts is up.
/// - What this process is doing to a session that is not on screen is in `SessionActivity`:
///   a session whose shutdown runs, from a row or from the terminal, reads "Ending…" and takes
///   no tap and no swipe; one whose release runs (a park, a close) reads "Saving…", takes no
///   swipe, and a tap on it waits for the release (`Busy`; DESIGN.md 2.2).
final class SessionListViewController: UITableViewController {
    private let store: HostStore
    private var hosts: [SavedHost] = []
    /// What the table shows, one array per section (`SessionList.rows`).
    private var rows: [[ListRow]] = [[.noHosts]]
    /// The first line of each session row (`SessionPreview`), read with the rows.
    private var previews: [SessionID: String] = [:]
    private let previewCache = SessionPreviewCache()
    /// The row whose swipe actions are open (`willBeginEditingRowAt` to its `didEndEditingRowAt`),
    /// or nil. While one is open nothing reads, reconfigures or reloads the table (4.4, step 5c).
    /// A row, not a flag: when a second row's swipe begins before the first one's end is
    /// reported, that end does not mark the second one closed.
    private var swipeRow: IndexPath?
    private var swipeOpen: Bool { swipeRow != nil }
    /// What waited for the open swipe: `reload()` (hosts and records), or at least the refresh.
    /// Done once, when the swipe has closed (`swipeClosed`).
    private var reloadWaits = false
    private var refreshTimer: Timer?
    private let waitingLabel = UILabel()

    init(store: HostStore = HostStore()) {
        self.store = store
        super.init(style: .insetGrouped)
        // Here, not in viewDidLoad: a resumed session's screen is pushed over the list before
        // the list has loaded, and its back button takes these.
        title = "Hosts"
        navigationItem.backButtonTitle = "Hosts"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let add = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addHost))
        add.accessibilityIdentifier = "addHost"
        add.accessibilityLabel = "Add Host"
        navigationItem.rightBarButtonItem = add
        let keys = UIBarButtonItem(title: "Keys", style: .plain, target: self, action: #selector(showKeys))
        keys.accessibilityIdentifier = "keysButton"
        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain,
                                       target: self, action: #selector(showSettings))
        settings.accessibilityIdentifier = "settingsButton"
        settings.accessibilityLabel = "Settings"
        navigationItem.leftBarButtonItems = [keys, settings]
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "empty")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "host")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "session")
        // A sideways drag towards a side without swipe actions is never taken as a tap (R24-M1).
        tableView.addGestureRecognizer(SidewaysTouchCanceller(target: nil, action: nil))
        waitingLabel.font = .preferredFont(forTextStyle: .footnote)
        waitingLabel.textColor = .secondaryLabel
        waitingLabel.numberOfLines = 0
        waitingLabel.accessibilityIdentifier = "sessionWaiting"
        SessionActivity.shared.onChange = { [weak self] in self?.activityChanged() }
    }

    /// DESIGN.md 4.4: an end, a release or an open began or finished. The records are read again
    /// now, not at the next tick, while the list is on screen (it reads them when it appears).
    private func activityChanged() {
        guard viewIfLoaded?.window != nil else { return }
        reloadSessions()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.reloadSessions()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // DESIGN.md 4.5: an open that pushed a screen is over once the list is back.
        SessionActivity.shared.openFinished()
        if UITestSupport.isUITesting, let window = view.window {
            LastSessionElement.shared.install(in: window)
            LastSessionElement.shared.update(Self.lastIdentifier(rows))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if SessionActivity.shared.waitingReason != nil { updateWaitingLine() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The list has gone (a push, also from a swipe's own "Edit") with a swipe still marked
        // open, its end not reported: nothing may wait on it. The mark is dropped and the swipe
        // closed; `viewWillAppear` reads everything again. After the transition, so never inside
        // a swipe action's own handler.
        guard swipeOpen else { return }
        DebugLog.shared.log("list: gone with swipe actions open on row \(swipeRow.map { "\($0)" } ?? "-"); closed")
        swipeRow = nil
        reloadWaits = false
        tableView.setEditing(false, animated: false)
    }

    /// Hosts and records read again and the table reloaded: when the list appears, after the
    /// editor, after an end, Forget or Delete. While a swipe is open it waits for its close
    /// (step 5c: a `reloadData()` there resets the swipe, and UIKit's reset calls
    /// `didEndEditingRowAt` from inside the reload).
    private func reload() {
        guard !swipeOpen else {
            reloadWaits = true
            return
        }
        do {
            hosts = try store.load()
        } catch {
            hosts = []
            showError(title: "Hosts", message: "\(error)")
        }
        readSessions()
        tableView.reloadData()
    }

    /// The 1 s refresh (DESIGN.md 4.4). While a row's swipe actions are open, nothing: the model
    /// and the table stay as they are (step 5c: a reconfigure of the open row, even with the same
    /// texts, slid its actions shut and open again with animations on, at every tick, on the phone
    /// on 2026-11-22); `swipeClosed` reads again when the swipe has closed. Otherwise, the same
    /// rows in the same order: the model is taken and the visible cells are reconfigured in place,
    /// at every tick (their texts may have changed). Rows came or went: the model and the table
    /// stay as they are shown while one of the list's alerts is up, so that a tap acts on the row
    /// that is shown; the next tick after that redraws.
    private func reloadSessions() {
        guard !swipeOpen else { return }
        let model = readModel()
        if Self.sameRows(rows, model.rows) {
            apply(model)
            if let visible = tableView.indexPathsForVisibleRows, !visible.isEmpty {
                tableView.reconfigureRows(at: visible)
            }
        } else if !(presentedViewController is UIAlertController) {
            apply(model)
            tableView.reloadData()
        }
        updateWaitingLine()
    }

    private func readSessions() {
        apply(readModel())
        updateWaitingLine()
    }

    private struct Model {
        var rows: [[ListRow]]
        var previews: [SessionID: String]
    }

    private func readModel() -> Model {
        let read = SessionList.load(liveID: TerminalViewController.current?.liveSessionID)
        let busy = SessionActivity.shared.busy
        let sessions = read.map { session in
            // What this process is doing beats the files, in `derive`'s order: on screen, then an
            // "End Session" in flight (of this list or of a terminal screen), then a release in
            // flight (a park: "Saving…", DESIGN.md 2.2, 3.3 B1).
            guard session.state != .live else { return session }
            var marked = session
            if busy.ending.contains(session.id) {
                marked.state = .ending
            } else if busy.parking.contains(session.id) {
                marked.state = .parking
            }
            return marked
        }
        previewCache.keep(only: Set(sessions.map(\.id)))
        var previews: [SessionID: String] = [:]
        for session in sessions {
            previews[session.id] = previewCache.text(root: SessionFiles.root, id: session.id)
        }
        return Model(rows: SessionList.rows(hosts: hosts, sessions: sessions, last: SessionFiles.lastLookedAt()),
                     previews: previews)
    }

    private func apply(_ model: Model) {
        rows = model.rows
        previews = model.previews
        if UITestSupport.isUITesting { LastSessionElement.shared.update(Self.lastIdentifier(rows)) }
    }

    /// Whether two lists have the same rows in the same order: the same host or session at each
    /// place, whatever their texts and states.
    private static func sameRows(_ a: [[ListRow]], _ b: [[ListRow]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.count == y.count && zip(x, y).allSatisfy { rowKey($0) == rowKey($1) }
        }
    }

    private static func rowKey(_ row: ListRow) -> String {
        switch row {
        case .noHosts: return "noHosts"
        case let .host(host, _): return "host-\(host.id)"
        case let .session(session, _, _, _): return "session-\(session.id)"
        }
    }

    /// A row's accessibility identifier (4.7).
    private static func identifier(_ row: ListRow) -> String {
        switch row {
        case .noHosts: return "noHosts"
        case let .host(host, _): return "host-\(host.displayName)"
        case .session(_, let host?, let number, _): return "session-\(host.displayName)-\(number)"
        case .session(let session, nil, _, _): return "session-\(session.id)"
        }
    }

    /// The identifier of the row with the dot, for `lastSession`; nil when no row has it.
    private static func lastIdentifier(_ rows: [[ListRow]]) -> String? {
        for row in rows.joined() {
            if case let .session(_, _, _, isLast) = row, isLast { return identifier(row) }
        }
        return nil
    }

    /// Review M6-6: the launch's cold start said "try again later"; the list says so while the
    /// launch waits (`SessionActivity.waitingReason`, DESIGN.md 2.2).
    private func updateWaitingLine() {
        guard let reason = SessionActivity.shared.waitingReason else {
            if tableView.tableHeaderView != nil { tableView.tableHeaderView = nil }
            return
        }
        let text = SessionList.waitingText(reason)
        guard waitingLabel.text != text || tableView.tableHeaderView?.frame.width != tableView.bounds.width else { return }
        waitingLabel.text = text
        // Laid out again when the table's width changes (`viewDidLayoutSubviews`): at the first
        // read, before the first layout, it may still be zero.
        let width = max(0, tableView.bounds.width - 40)
        let height = waitingLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: height + 16))
        waitingLabel.frame = CGRect(x: 20, y: 8, width: width, height: height)
        header.addSubview(waitingLabel)
        tableView.tableHeaderView = header
    }

    // MARK: Actions

    @objc private func addHost() {
        openEditor(for: nil)
    }

    @objc private func showKeys() {
        navigationController?.pushViewController(KeysViewController(), animated: true)
    }

    @objc private func showSettings() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    private func openEditor(for host: SavedHost?) {
        let editor = HostEditorViewController(host: host, store: store)
        editor.onFinish = { [weak self] in
            guard let self else { return }
            self.navigationController?.popToViewController(self, animated: true)
            self.reload()
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    // MARK: Taps (DESIGN.md 4.5)

    /// The one way in for a tap (DESIGN.md 4.5, step 10). `activity` decides whether the tap is
    /// taken: not while another open is in flight ("opening", 2.2; a second tap is dropped here,
    /// before anything waits, S3). A tap that is taken drops the launch's wait at once (4.5, 2.2,
    /// step 11), unless `dropsTheWait` is false: the launch's own retry (`SceneDelegate`, W6),
    /// which goes the same way and keeps its wait when the gate drops it. Then, in a main-actor
    /// task: the settle (`settled()`, G2: every release asked for so far has returned, so a
    /// record being parked is clean and closed before it is opened again), the gate (`mayOpen`,
    /// G3: asked after the settle), and `action` in the same main-actor turn, with no suspension
    /// from the gate to the push. `action` returns whether it pushed a screen; "opening" is
    /// cleared when it did not (an alert, nothing to open) or the gate dropped the tap, and
    /// otherwise when the list appears again (`viewDidAppear`).
    ///
    /// Static, with the activity and the gate passed in, for the unit tests
    /// (`SessionActivityTests`, `SessionLauncherTests`). Returns the task of a tap that was
    /// taken, nil otherwise.
    @discardableResult
    static func open(_ what: String, activity: SessionActivity, dropsTheWait: Bool = true,
                     mayOpen: @escaping @MainActor () -> Bool,
                     action: @escaping @MainActor () -> Bool) -> Task<Void, Never>? {
        guard activity.beginOpen() else {
            DebugLog.shared.log("list: tap on \(what) dropped: an open is in flight")
            return nil
        }
        if dropsTheWait, let waiting = activity.busy.waiting {
            DebugLog.shared.log("list: tap on \(what) taken; the launch no longer waits for \(waiting)")
            activity.dropWait()
        }
        let tapped = DispatchTime.now().uptimeNanoseconds
        return Task { @MainActor in
            await activity.settled()
            let waited = (DispatchTime.now().uptimeNanoseconds - tapped) / 1_000_000
            // From here to the push nothing suspends (G3).
            guard mayOpen() else {
                DebugLog.shared.log("list: tap on \(what) dropped after the settle (\(waited) ms): the scene is not active, the list is not on top, or a terminal screen is open")
                activity.openFinished()
                return
            }
            DebugLog.shared.log("list: open of \(what) after the settle (\(waited) ms)")
            if !action() { activity.openFinished() }
        }
    }

    /// A tap on a row of this list, through `open` with the app's `SessionActivity` and this
    /// list's gate. Nothing while a terminal screen is open (it is on screen then, so this is
    /// only a guard; the gate asks again after the settle).
    private func open(_ what: String, _ action: @escaping @MainActor (SessionListViewController) -> Bool) {
        guard TerminalViewController.current == nil else { return }
        Self.open(what, activity: .shared, mayOpen: { [weak self] in self?.mayOpenNow() ?? false },
                  action: { [weak self] in
                      guard let self else { return false }
                      return action(self)
                  })
    }

    /// The gate of G3 with this list's facts (`OpenGate.mayOpen`).
    private func mayOpenNow() -> Bool {
        OpenGate.mayOpen(sceneIsActive: view.window?.windowScene?.activationState == .foregroundActive,
                         listIsOnTop: navigationController?.topViewController === self && presentedViewController == nil,
                         terminalIsOpen: TerminalViewController.current != nil)
    }

    /// Every screen an open makes is loaded before it is pushed (DESIGN.md 2.3): `viewDidLoad`
    /// makes it `TerminalViewController.current`, so the scene's resign reaches it before anything
    /// of its session can start. Returns whether it was pushed. A screen that is not pushed is
    /// freed; a resumed coordinator in its slot is then parked by the queue's end, a tracked
    /// release (5.6).
    private func push(_ terminal: TerminalViewController) -> Bool {
        guard let navigation = navigationController else { return false }
        terminal.loadViewIfNeeded()
        navigation.pushViewController(terminal, animated: true)
        return true
    }

    /// A tap on a host row: always a new session on that host, also when it has sessions, an
    /// ended one or one being ended (DESIGN.md 3.1 H1, H2; brief item 2). Not while an open is in
    /// flight (H4).
    private func open(host: SavedHost) {
        guard SessionActivity.shared.busy.mayTapHost else { return }
        open("host \(host.displayName)") { list in
            list.push(TerminalViewController(start: .host(host)))
        }
    }

    /// A tap on a session row: that record, through the coordinator. A row that is on screen,
    /// being ended, or "ended" takes no tap (DESIGN.md 3.2, S6 and S8): an ended record is
    /// finished by "End Session" or the next launch, never by a new session from its own row. A
    /// row being saved takes it, and the open waits for the save (S2).
    private func open(session: ListedSession, host: SavedHost?) {
        guard session.state != .live, session.state != .ended,
              SessionActivity.shared.busy.mayTap(session: session.id) else { return }
        let id = session.id
        open("session \(id)") { list in
            list.openRecord(id, host: host)
        }
    }

    /// A stored session, through the coordinator only: what it says is what happens, as at
    /// launch (`SceneDelegate`). Returns whether a screen was pushed.
    ///
    /// Only a record that is there and wants it gets a new session (a fallback, S4). A record
    /// that turns out ended on purpose, is not a record, or is gone (forgotten since the row was
    /// read: no key and no directory) starts nothing (S6, S9; review-steps-2-4.md R24-S5).
    private func openRecord(_ id: SessionID, host: SavedHost?) -> Bool {
        let decision = SessionLauncher.coldStart(root: SessionFiles.root, id: id, keys: .shared,
                                                 options: SessionLauncher.coldStartOptions(root: SessionFiles.root, id: id))
        switch decision {
        case .nothing:
            // Not an answer for one record; nothing is started from it.
            reloadSessions()
            return false
        case .resumed(let coordinator):
            return push(TerminalViewController(start: .resumed(coordinator, host: host)))
        case .retryLater(let reason):
            // Only an alert: the waiting line belongs to the launch's cold start
            // (`SceneDelegate`), which is the one that tries again.
            showError(title: "Session Not Available Now", message: "The session cannot be opened now: \(reason). Try again later.")
            return false
        case .fallback(let fallback):
            defer { reloadSessions() }
            if fallback.recordDeleted, fallback.meta == nil {
                // Not a record (SessionLauncher.coldStart deleted it): nothing to continue, and
                // no new session (S9).
                SessionFiles.forget(fallback.id)
                return false
            }
            if !fallback.wantsNewSession {
                // Ended on purpose: its server is stopped if the identity check passes; no new
                // session (S6).
                Task { await SessionLauncher.finishEnded(fallback, host: host) }
                return false
            }
            if !fallback.recordDeleted, (try? SessionStore(root: SessionFiles.root, id: fallback.id).exists) == false {
                // The record went after the row was read (forgotten: the record goes before its
                // key, so a missing key with no directory is a forgotten session): nothing to
                // fall back from. What is left of it (a link) is removed.
                DebugLog.shared.log("list: \(fallback.id) is gone (\(fallback.reason)); nothing is started")
                SessionFiles.forget(fallback.id)
                return false
            }
            if let host {
                return push(TerminalViewController(start: .fallback(fallback, host: host, debug: nil)))
            }
            // Nothing to bootstrap a new session with.
            SessionFiles.forget(fallback.id)
            showError(title: ColdStartFallback.plainMessage, message: fallback.reason)
            return false
        }
    }

    // MARK: End Session and Forget

    private func hostName(_ session: ListedSession, _ host: SavedHost?) -> String {
        host?.host ?? session.meta?.hostName ?? "the host"
    }

    /// The question before "End Session" (DESIGN.md 4.6): for a resumable or unreadable row, the
    /// end through mosh (step 12); for a dead or ended row, the SSH way, as before.
    private func confirmEnd(_ session: ListedSession, host: SavedHost?) {
        let name = hostName(session, host)
        let message: String
        switch SessionEndPlan.way(for: session.state) {
        case .mosh?:
            message = "Ends the session on \(name): its shell and the programs in it stop. Then the session is removed from this phone."
        case .ssh?, nil:
            message = "Stops the session's mosh-server on \(name) over SSH (after checking that it is this session's server), with the shell and the programs in it. Then the session is removed from this phone."
        }
        let alert = UIAlertController(title: "End Session?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "End Session", style: .destructive) { [weak self] _ in
            self?.end(session, host: host)
        })
        present(alert, animated: true)
    }

    /// "End Session" on a row (DESIGN.md 3.4, section 6, step 12), by the state the row was read
    /// in (`SessionEndPlan.way`): a resumable or unreadable row is opened again and ended by
    /// mosh's own shutdown, which needs no pid (R1, R4); a dead or ended row, which must send
    /// nothing, by the identity-checked kill over SSH (R2, R3). Either way the record, its key and
    /// its link are removed only when the server is known to be stopped or nothing more can be
    /// done with its pid and start time (review M6-4); otherwise the record stays as its files
    /// say and the user is told why. `SessionEnder` runs it in a background task of its own, the
    /// row "Ending…" meanwhile, and first of all clears "last looked at" for the session and drops
    /// the launch's wait for it (2.2, 2.5).
    private func end(_ session: ListedSession, host: SavedHost?) {
        // One end of a row from this list at a time (a row being ended offers no swipe, R6).
        guard !SessionActivity.shared.busy.ending.contains(session.id) else { return }
        guard let way = SessionEndPlan.way(for: session.state) else {
            DebugLog.shared.log("list: end session \(session.id): not offered in state \(session.state.identifier)")
            return
        }
        SessionEnder.end(id: session.id, meta: session.meta, host: host, hostName: hostName(session, host),
                         way: way) { [weak self] outcome in
            guard let self else { return }
            self.reload()
            if case .notEnded(let problem) = outcome { self.showError(title: "Session Not Ended", message: problem) }
        }
        reload()
    }

    static func notEnded(_ outcome: OldServerOutcome, host: String) -> String {
        let reason: String
        switch outcome {
        case .hostNotReached:
            reason = "\(host) could not be reached with this device's key"
        case .notThere(atSessionAddress: false):
            reason = "\(host) answered from another address, so its answer says nothing about the session's server"
        default:
            reason = "\(host) gave no usable answer"
        }
        return "\(reason.prefix(1).uppercased() + reason.dropFirst()). The session is kept; try again later, or use Forget."
    }

    private func confirmForget(_ session: ListedSession, host: SavedHost?) {
        let alert = UIAlertController(
            title: "Forget Session?",
            message: "Removes the session from this phone without contacting \(hostName(session, host)). If its mosh-server still runs there, it keeps running with its shell until it is stopped on the host or the host restarts; this phone can then neither reach nor stop it.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Forget", style: .destructive) { [weak self] _ in
            guard let self else { return }
            DebugLog.shared.log("list: forget session \(session.id)")
            if SessionFiles.forget(session.id) {
                // A forgotten session is not waited for (2.2, 3.4 R5).
                SessionActivity.shared.dropWait(for: session.id)
            } else {
                self.showError(title: "Session Not Forgotten",
                               message: "The session's record is in use or cannot be deleted now. Try again in a few seconds.")
            }
            self.reload()
        })
        present(alert, animated: true)
    }

    private func delete(_ host: SavedHost) {
        do {
            try store.delete(id: host.id)
        } catch {
            showError(title: "Delete", message: "\(error)")
        }
        reload()
    }

    private func showError(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Table

    private func row(at indexPath: IndexPath) -> ListRow? {
        guard indexPath.section < rows.count, indexPath.row < rows[indexPath.section].count else { return nil }
        return rows[indexPath.section][indexPath.row]
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "Sessions Without a Saved Host" : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section < rows.count ? rows[section].count : 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = row(at: indexPath) else { return UITableViewCell() }
        if case .noHosts = row {
            let cell = tableView.dequeueReusableCell(withIdentifier: "empty", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = "No hosts yet. Tap + to add one."
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "noHosts"
            return cell
        }
        // Dequeued, so that `reconfigureRows(at:)` configures the same cell again (4.4). Every
        // property a row sets is set for every row of its kind.
        let isHost: Bool
        if case .host = row { isHost = true } else { isHost = false }
        let cell = tableView.dequeueReusableCell(withIdentifier: isHost ? "host" : "session", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.color = .secondaryLabel
        cell.accessibilityIdentifier = Self.identifier(row)
        switch row {
        case .noHosts:
            break
        case let .host(host, sessions):
            // As today, without the state line: that is on its session rows (reading 7).
            content.text = host.displayName
            content.secondaryText = "\(host.user)@\(host.host)" + (host.port == 22 ? "" : ":\(host.port)")
            if sessions == 0 {
                // Without sessions the row is exactly as before (4.1).
                cell.accessoryView = nil
                cell.accessoryType = .detailButton
            } else {
                // With sessions: the "+" and the info button (4.1, step 10). The same view is
                // kept when the row is configured again (the 1 s refresh), so that a finger on
                // its button is not lost.
                let accessory = (cell.accessoryView as? HostAccessoryView) ?? HostAccessoryView()
                accessory.onInfo = { [weak self] in self?.openEditor(for: host) }
                cell.accessoryType = .none
                cell.accessoryView = accessory
            }
            // For UI tests: "none" when the host has no record.
            cell.accessibilityValue = sessions == 0 ? "none" : "sessions=\(sessions)"
        case let .session(session, host, _, isLast):
            // First line the preview, second line the state line, grey; a 10-point dot, green
            // for the session looked at last and clear otherwise, so the texts line up. The dot
            // is the only green on the screen (4.1).
            content.text = previews[session.id] ?? SessionPreview.placeholder
            let line = SessionList.stateLine(session, now: Date())
            if host != nil {
                content.directionalLayoutMargins.leading += 20
                content.secondaryText = line
            } else {
                // No host row above it says where it runs.
                let meta = session.meta
                let place = meta.map { $0.user.isEmpty ? $0.hostName : "\($0.user)@\($0.hostName)" } ?? "Unknown host"
                content.secondaryText = place + " · " + line
            }
            content.image = UIImage(systemName: "circle.fill",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
            content.imageProperties.tintColor = isLast ? .systemGreen : .clear
            content.imageProperties.maximumSize = CGSize(width: 10, height: 10)
            content.imageProperties.reservedLayoutSize = CGSize(width: 10, height: 10)
            cell.accessoryView = nil
            cell.accessoryType = .none
            // The state for UI tests.
            cell.accessibilityValue = session.state.identifier
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch row(at: indexPath) {
        case let .host(host, _)?:
            open(host: host)
        case let .session(session, host, _, _)?:
            open(session: session, host: host)
        case .noHosts?, nil:
            break
        }
    }

    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard case let .host(host, _)? = row(at: indexPath) else { return }
        openEditor(for: host)
    }

    /// "End Session" and "Forget" (Design 4, "Session list"), on a session row that is not open
    /// and not being ended. Swiped from the leading edge, and never by a full swipe. The actions
    /// act on the session of the row that was swiped, captured here.
    override func tableView(
        _ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case let .session(session, host, _, _)? = row(at: indexPath),
              session.state != .live, SessionActivity.shared.busy.maySwipe(session: session.id) else { return nil }
        let end = UIContextualAction(style: .destructive, title: "End Session") { [weak self] _, _, done in
            self?.confirmEnd(session, host: host)
            done(true)
        }
        let forget = UIContextualAction(style: .normal, title: "Forget") { [weak self] _, _, done in
            self?.confirmForget(session, host: host)
            done(true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [end, forget])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    override func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        swipeRow = indexPath
        DebugLog.shared.log("list: swipe actions open on row \(indexPath); the refresh waits")
    }

    override func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        // The end of another row's swipe, reported after this row's began: this one stays open.
        if let indexPath, let open = swipeRow, indexPath != open { return }
        swipeRow = nil
        DebugLog.shared.log("list: swipe actions closed; the list is read again")
        // Not from here: UIKit calls this from inside its own reset of the swipe (also from
        // inside a `reloadData()` or a swipe action's completion), and a reload or reconfigure
        // made then trips UITableView's assertion and aborts the app (step 5c, with animations
        // on). What waited is done once, after this call has returned.
        DispatchQueue.main.async { [weak self] in self?.swipeClosed() }
    }

    /// The swipe has closed: what waited for it is done once, and the list is read again in any
    /// case, so what changed meanwhile is drawn. If another swipe opened in the meantime, it
    /// waits for that one.
    private func swipeClosed() {
        guard !swipeOpen else { return }
        if reloadWaits {
            reloadWaits = false
            reload()
        } else {
            reloadSessions()
        }
    }

    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case let .host(host, _)? = row(at: indexPath) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.delete(host)
            done(true)
        }
        let edit = UIContextualAction(style: .normal, title: "Edit") { [weak self] _, _, done in
            self?.openEditor(for: host)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete, edit])
    }
}

/// The accessory of a host row that has sessions (docs/notes/multi-session/DESIGN.md 4.1, step
/// 10): a small "+" (identifier `hostPlus`; a tap on the row starts another session, brief item
/// 2) and, right of it, the info button that opens the host's editor. The button is a
/// `UIButton`, so the UI tests still reach it as the cell's first button; the "+" is an image,
/// not a button: a touch on it is a tap on the row.
final class HostAccessoryView: UIStackView {
    /// The info button's action: the editor of the row's host (set at every configuration).
    var onInfo: (() -> Void)?

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 12
        let plus = UIImageView(image: UIImage(systemName: "plus",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
        plus.tintColor = .secondaryLabel
        plus.isAccessibilityElement = true
        plus.accessibilityIdentifier = "hostPlus"
        plus.accessibilityLabel = "New session"
        let info = UIButton(type: .detailDisclosure, primaryAction: UIAction { [weak self] _ in self?.onInfo?() })
        addArrangedSubview(plus)
        addArrangedSubview(info)
        frame = CGRect(origin: .zero, size: systemLayoutSizeFitting(UIView.layoutFittingCompressedSize))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// Cancels a touch on the list that moved sideways and that no other gesture took, so that it
/// never opens a row (review-steps-2-4.md, R24-M1; step 4c). A host row has no leading swipe
/// actions and a session row no trailing ones; a drag towards that side starts neither the
/// swipe nor the scroll, and UIKit then took its end as a tap on the row (seen on the
/// simulator, docs/MAC.md, step 4c).
///
/// It decides only when the touch ends, so it never takes a touch from another gesture: when
/// the table's swipe actions or its scrolling begin, this recognizer fails (it does not
/// recognize alongside another one), and the touch goes on as before. At the end it recognizes
/// only when the finger is, or was, more than `sidewaysSlop` points left or right of where it
/// went down; `cancelsTouchesInView` then cancels the touch for the table, which therefore
/// selects nothing. Every other touch ends in `.failed`, and the table gets its end as before
/// (`delaysTouchesEnded` holds it only until this recognizer has decided, which it does in its
/// own `touchesEnded`).
/// A touch that begins on a control (a host row's detail button, a swipe action's button) or
/// a second finger is left alone. No target and no action: nothing is shown or done.
final class SidewaysTouchCanceller: UIGestureRecognizer {
    /// How far a finger may move sideways and still make a tap, in points.
    static let sidewaysSlop: CGFloat = 10

    private var start: CGPoint?
    private var movedSideways = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard start == nil, touches.count == 1, let touch = touches.first, !Self.beginsOnAControl(touch) else {
            state = .failed
            return
        }
        // Window coordinates: the table's own move with its content does not count.
        start = touch.location(in: nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        note(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        note(touches)
        state = movedSideways ? .recognized : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .failed
    }

    override func reset() {
        super.reset()
        start = nil
        movedSideways = false
    }

    private func note(_ touches: Set<UITouch>) {
        guard let start, let touch = touches.first else { return }
        if abs(touch.location(in: nil).x - start.x) > Self.sidewaysSlop { movedSideways = true }
    }

    private static func beginsOnAControl(_ touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view, !(current is UITableView) {
            if current is UIControl { return true }
            view = current.superview
        }
        return false
    }
}
