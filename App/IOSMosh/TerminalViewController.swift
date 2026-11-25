import MoshBootstrap
import MoshCrypto
import MoshKeys
import MoshResume
import MoshSession
import MoshTerminal
import MoshTransport
import UIKit

/// The terminal screen: one resumable session (`ResumeCoordinator`, docs/PLAN.md section 3 and
/// docs/RESUME.md) drawn by a `TerminalSurface`. The screen talks to the session only through
/// the coordinator, so every send passes the record's file-backed gate.
///
/// - Start: from a saved host, an SSH bootstrap with the device key (Design 4: host key
///   check against `KnownHosts`, password if the key is rejected, "Install my key on this
///   host" after a password login, `mosh-server new` in a pty of the view's size); in debug
///   builds, straight to a given port and key (`DebugLaunch`); a session the cold start
///   resumed; or the fallback of a cold start that could not resume (message and reason
///   shown, a new session bootstrapped, the old server killed if the identity check passes,
///   then the old record deleted).
/// - A new session: its key goes to the Keychain (`SessionKeychain`), then
///   `ResumeCoordinator.create` makes the record (`storesKey: false`), then `start()`.
/// - Screens: one frame to draw (`FrameToDraw`): the session's `.display` frames (local echo,
///   M10: the server's screen with the guesses drawn), or its `.screen` frames in Never mode;
///   a display link shows it when it changed (intermediate frames are skipped, docs/PLAN.md
///   Design 2 "Drawing"). A frame whose size is not the view's is not shown (between a
///   Resize and the server's answer). Local echo is the saved host's setting, passed at every
///   `create` and cold start; a change saved while the session is open reaches it through
///   `setPrediction`.
/// - Input, resizes and the lifecycle calls go to the coordinator in the order they happened,
///   through one serial queue of commands (`SessionQueue`). Its slot holds the screen's
///   coordinator from the moment the screen has one (a resumed one from `init`, a new one from
///   `openSession`); commands reach it once `attach` has run. Every read of the screen's session
///   asks whether it is attached (`queue.isAttached`, `queue.attached`), except the leave, the
///   queue's end and `openSession`'s guard, which ask whether the slot is filled (`queue.held`;
///   DESIGN.md 2.3, rule 2).
/// - Leaving the foreground (`sceneWillResignActive`, from `SceneDelegate`): in a background
///   task, `enterBackground()` (quiesce, snapshot, clean mark). Returning
///   (`sceneDidBecomeActive`): `enterForeground()` ("dirty", new socket).
/// - A change of the network path (`PathWatcher`): `replaceSocket()`.
/// - Health: "Last contact N s ago" after 6.5 s without the server; after 15 s the SSH probe
///   (`ServerProbe`, key login, no prompts) tells a gone server (fallback to a new session)
///   from an unreachable host (keep waiting) and blocked UDP (say so, keep the session).
/// - Leaving the screen (`leaveScreen`, DESIGN.md 5.3, decided by `LeaveAction.decide`): "‹ Hosts"
///   parks the session (2.3: `.park` at the end of the command queue, which saves it as the
///   scene's save does and closes it; a tracked release in `SessionActivity`); the session stays,
///   resumable from its row. Only "End Session" ends it: the slot is emptied first, then
///   `shutdown()` in a background task (the record is marked ended first; the session is
///   "ending" in `SessionActivity` until the end returns, so its row reads "Ending…"), then
///   `close()`, then, if the server acknowledged, the record, its key and its host link are
///   deleted; a shutdown without an answer keeps the "ended" record for the identity-checked
///   kill (`SessionEnding`, review M6-4); a refused shutdown stops the server over SSH and forgets
///   the record only by `LeaveAction.afterStop` (E4). A resumed session ended before `attach` is
///   only closed: it never started, and its record stays as it was (C11). Back while a fallback
///   is still connecting keeps the old record, "Could not be resumed" (B3). Nothing holds the
///   controller after that (the display link goes through a weak proxy).
/// - Every release of a record is tracked in `SessionActivity` (DESIGN.md 2.4 G2), so that an
///   open from the list waits for it: the park, the close of an unattached session, and from
///   step 10 the close after the server's end (`finish`) and the run-time fallback's
///   `abandon()`. A resign during the pop of a confirmed "End Session" saves nothing, so that
///   the leave's shutdown is sent (`sceneWillResignActive`).
/// - "End Session" behind the "…" button of the navigation bar (docs/notes/multi-session/
///   DESIGN.md 5.2) asks once, clears "last looked at" for the session it ends, then leaves the
///   screen.
final class TerminalViewController: UIViewController {
    enum Start {
        case host(SavedHost)
        case debug(DebugLaunch.Request)
        case resumed(ResumeCoordinator, host: SavedHost?)
        case fallback(SessionFallback, host: SavedHost?, debug: DebugLaunch.Request?)
    }

    /// The screen whose session follows the scene's lifecycle (one scene, one live session).
    static weak var current: TerminalViewController?

    /// Controllers alive now; UI tests read it (through the host list) to see that a
    /// terminal screen is freed after it is left.
    static var liveCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return count
    }

    private static let countLock = NSLock()
    private static var count = 0

    private let start: Start
    private let keyStore: KeyStore
    private let knownHosts: KnownHosts
    private let surface: TerminalSurface = SwiftTermSurface()
    private let screenText = ScreenTextElement()
    private let appearanceText = TerminalAppearanceElement()
    private var appearanceShownAt = Date.distantPast
    /// UI tests: the bars' colours and the system's mode, as `terminalBars`.
    private let barsText = TerminalAppearanceElement()
    /// The colours of the navigation bar and the status bar over this screen (`applyBars`).
    private var bars: TerminalBars?
    private let statusLabel = UILabel()
    private let progressLabel = UILabel()
    private let contactLabel = UILabel()
    /// M7: the key bar under the terminal, and the writer of OSC 52 clipboard decisions.
    private lazy var keyBar = KeyBarView(surface: surface)
    private let clipboardWriter = ClipboardWriter()
    /// Font size by pinch and Cmd-plus / Cmd-minus (stored in `AppSettings`).
    private lazy var fontZoom = FontZoom(surface: surface)
    /// The bell as a haptic.
    private let bell = BellHaptic()
    /// PgUp / PgDn by a vertical swipe, if the host has that option on.
    private lazy var swipePaging = SwipePaging(surface: surface,
                                               hostOption: host?.swipeSendsPaging ?? SwipePaging.debugOption)

    /// The saved host of the session (nil for a debug session): for the probe and a fallback.
    private var host: SavedHost?
    /// The command queue and its slot, the screen's coordinator (DESIGN.md 2.3). Read by unit
    /// tests.
    let queue = SessionQueue()
    /// A record that fell back and is deleted once the new session has started.
    private var oldSession: SessionID?
    /// Its `meta`: the old server's pid and start time, if the screen is left before the
    /// replacement's bootstrap has dealt with it.
    private var oldMeta: SessionMeta?
    private var connectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    /// Set when the screen is left; nothing starts after that.
    private var ended = false
    private var startRequested = false
    /// `start()` failed (its counters change could not be written): tried again at the next
    /// return to the foreground.
    private var startFailed = false
    /// The server ended the session (`.serverEnded`): no health check, no probe, no new
    /// session by itself (review M6-3).
    private var serverEnded = false
    /// "End Session" was confirmed in the question of the "…" button (DESIGN.md 5.2). The prompts
    /// read it (a question of the connect is not shown to a screen that is being left); the leave
    /// decides by it (`LeaveAction.decide`): without it a leave never ends the session.
    private var endRequested = false
    /// From the confirmed "End Session" to the leave (the pop between): see `endFromMenu`.
    private var endPopTask: BackgroundTask?
    /// When this screen was made, and whether its first screen has been drawn: the time from a
    /// resumed screen's making to its first screen goes to the log (DESIGN.md risk 1, step 9).
    private let madeAt = Date()
    private var firstScreenShown = false
    /// The "End Session?" alert while it is up, and the prompts of the connect that wait for
    /// it to be answered (`ask`): UIKit shows one alert at a time, and a `present` over it
    /// would be dropped, its continuation never resumed.
    private var endConfirmation: UIAlertController?
    private var promptsWaitingForEndConfirmation: [CheckedContinuation<Void, Never>] = []

    /// Local echo of this screen's sessions, and the frame to draw (M10).
    private var localEcho: LocalEcho
    private var frames: FrameToDraw
    /// The serial (`FrameToDraw.serial`) of the frame on the view; nil forces a repaint.
    private var shownSerial: UInt64?
    /// UI tests: what the session says its local echo is, and the sizes of the last inputs
    /// handed to `coordinator.type` (a paste must arrive as one, DESIGN.md section 5 item 5).
    private let localEchoText = LocalEchoElement()
    private var sessionLocalEcho = "?"
    private var inputSizes: [Int] = []
    private var displayLink: CADisplayLink?
    private var resizeTimer: Timer?
    private var announcedSize: TerminalSize?
    /// Asks the session for a new socket when the network path changes.
    private var pathWatcher: PathWatcher?

    // Session health.
    private var healthTimer: Timer?
    private var isAppActive = true
    /// Whether a session attached now needs the background save at once (review M6-2).
    private var savePolicy = SceneSavePolicy()
    /// `-uiTestingBackgroundInset`: a real layout after the background save (UI tests only).
    private var backgroundLayout = BackgroundLayoutChange.fromLaunch
    private var activeSince = Date()
    private var lastContact = Date()
    private var nextProbeAt = Date.distantPast
    private var probing = false

    init(start: Start, keyStore: KeyStore = KeychainKeyStore(), knownHosts: KnownHosts = AppFiles.knownHosts) {
        self.start = start
        self.keyStore = keyStore
        self.knownHosts = knownHosts
        let saved: SavedHost?
        switch start {
        case .host(let host): saved = host
        case .resumed(_, let host), .fallback(_, let host, _): saved = host
        case .debug: saved = nil
        }
        localEcho = LocalEcho.forSession(host: saved)
        frames = FrameToDraw(display: localEcho.mode.display)
        super.init(nibName: nil, bundle: nil)
        Self.countLock.lock()
        Self.count += 1
        Self.countLock.unlock()
        switch start {
        case .host(let saved): host = saved
        case .resumed(_, let saved), .fallback(_, let saved, _): host = saved
        case .debug: host = nil
        }
        title = host?.displayName ?? "Session"
        NotificationCenter.default.addObserver(self, selector: #selector(hostSaved(_:)), name: LocalEcho.hostSaved, object: nil)
        // The slot holds a resumed coordinator from here on, so that a screen left or freed
        // before `attach` still releases it (DESIGN.md 2.3, rule 2).
        if case .resumed(let resumed, _) = start { queue.hold(resumed) }
        // The queue's three callbacks; each holds this screen weakly.
        queue.inputCounted = { [weak self] count in self?.noteInput(count) }
        queue.predictionApplied = { [weak self] coordinator in self?.readSessionLocalEcho(coordinator) }
        queue.layoutAfterSave = { [weak self] in
            guard let self, self.backgroundLayout.inset != nil else { return nil }
            let task = BackgroundTask(name: "ui test: layout after the save")
            return { [weak self] clean in
                if let self { self.changeLayoutAfterTheSave(clean: clean, task: task) } else { task.end() }
            }
        }
    }

    /// The record of the session this screen has open now, for the host list's "live" state;
    /// nil once the screen was left (the session is ending) or before a session is attached.
    var liveSessionID: SessionID? { ended ? nil : queue.attached?.id }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        displayLink?.invalidate()
        resizeTimer?.invalidate()
        healthTimer?.invalidate()
        connectTask?.cancel()
        // Not left through `leaveScreen` (a test, a resumed screen that never appeared): the
        // queue is freed with this screen and finishes; its consumer runs what was sent before
        // and then parks a coordinator still in the slot (DESIGN.md 5.6). After a leave the
        // slot is empty, or holds the coordinator the queued park releases.
        Self.countLock.lock()
        Self.count -= 1
        Self.countLock.unlock()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Self.current = self

        // M8: theme (and cursor) from Settings, before the first screen; a change in Settings
        // applies to the next terminal screen.
        let appearance = AppSettings.appearance
        surface.apply(appearance)
        if let background = appearance.theme.background { view.backgroundColor = UIColor(background) }
        applyBars()
        let terminal = surface.view
        terminal.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminal)
        surface.removeBuiltInAccessory()
        keyBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyBar)

        for (label, color, identifier) in [
            (statusLabel, UIColor.systemRed, "sessionStatus"),
            (progressLabel, UIColor.darkGray, "connectProgress"),
            (contactLabel, UIColor.systemOrange, "contactBanner"),
        ] {
            label.textColor = .white
            label.backgroundColor = color.withAlphaComponent(0.85)
            label.font = .preferredFont(forTextStyle: .footnote)
            label.numberOfLines = 0
            label.textAlignment = .center
            label.isHidden = true
            label.accessibilityIdentifier = identifier
        }

        // The banners take room from the terminal instead of covering its rows: status and
        // progress in a stack above it, "Last contact" in one between it and the key bar. A
        // stack whose labels are all hidden has no height, so without a banner the terminal
        // has the full height. A banner coming or going changes the terminal's rows, which
        // reach the server as an ordinary resize (`onSizeChange`).
        let topBanners = UIStackView(arrangedSubviews: [statusLabel, progressLabel])
        let bottomBanners = UIStackView(arrangedSubviews: [contactLabel])
        for stack in [topBanners, bottomBanners] {
            stack.axis = .vertical
            stack.alignment = .fill
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
        }

        NSLayoutConstraint.activate([
            topBanners.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBanners.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBanners.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topBanners.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomBanners.topAnchor),
            bottomBanners.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBanners.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBanners.bottomAnchor.constraint(equalTo: keyBar.topAnchor),
            keyBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        installSessionMenu()
        clipboardWriter.install(in: view, below: view.safeAreaLayoutGuide.topAnchor)
        fontZoom.install(on: terminal)
        swipePaging.install(on: terminal)
        bell.install(in: view)

        surface.onInput = { [weak self] bytes in
            self?.queue.send(.input(bytes))
        }
        surface.onSizeChange = { [weak self] _, _ in
            self?.viewSizeChanged()
        }

        if UITestSupport.isUITesting {
            screenText.install(in: view)
            appearanceText.install(in: view)
            barsText.install(in: view, identifier: "terminalBars")
            localEchoText.install(in: view)
        }
        // A display link keeps its target; the proxy keeps this controller weakly.
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// `-uiTestingBackgroundInset` (`BackgroundLayoutChange`): `delay` after a clean background
    /// save, a real layout with a narrower safe area, so that SwiftTerm's grid changes and the
    /// size path runs as it does when iOS lays the view out. `task` keeps the process running
    /// until the resize timer and the held mark are through.
    private func changeLayoutAfterTheSave(clean: Bool, task: BackgroundTask) {
        guard let inset = backgroundLayout.insetAfterSave(clean: clean) else {
            task.end()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + BackgroundLayoutChange.delay) { [weak self] in
            guard let self else {
                task.end()
                return
            }
            let state = view.window?.windowScene?.activationState
            DebugLog.shared.log("ui test: left inset +\(inset) pt after the save (scene background: \(state == .background))")
            additionalSafeAreaInsets.left += CGFloat(inset)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { task.end() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        surface.focus()
        startSessionIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: The bars over the terminal

    /// The navigation bar (the session's title, the back and "…" buttons) and the status bar
    /// take the terminal's colours (`TerminalBars`), not the system's: with the phone in light
    /// mode the System theme's terminal is still black, and the system's black title and status
    /// bar on it could not be read. Only this screen's bars: its own navigation item's appearance,
    /// and the status bar style that `AppNavigationController` asks the top screen for. The view
    /// behind the terminal gets the same colour, so that the bars and the terminal are one area.
    private func applyBars() {
        let background = surface.drawnBackground() ?? RGB(view.backgroundColor ?? .black)
        let bars = TerminalBars(background: background)
        self.bars = bars
        view.backgroundColor = UIColor(background)
        let text = UIColor(bars.text)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(background)
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: text]
        appearance.largeTitleTextAttributes = [.foregroundColor: text]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        navigationItem.compactScrollEdgeAppearance = appearance
        setNeedsStatusBarAppearanceUpdate()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        guard let bars else { return .default }
        return bars.lightText ? .lightContent : .darkContent
    }

    /// The leave runs here and only here: a back swipe let go half way calls `viewWillDisappear`
    /// but not this (DESIGN.md 3.3 B6), and leaves nothing to undo.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            leaveScreen()
        }
    }

    // MARK: Scene lifecycle (SceneDelegate)

    /// Leaving the foreground (docs/PLAN.md section 3): quiesce, snapshot, clean mark, in a
    /// background task. With no session yet (bootstrap in flight) the save is queued when the
    /// session is attached (`attach`, `SceneSavePolicy`).
    func sceneWillResignActive() {
        isAppActive = false
        contactLabel.isHidden = true
        // A resumed coordinator in the slot before `attach` is not a session yet: the policy
        // notes the resign and `attach` saves at once (CL-S1).
        guard savePolicy.sceneResigned(hasSession: queue.isAttached && !ended) else { return }
        guard !endRequested else {
            // "End Session" was confirmed and the pop runs; the leave comes at its end. A save
            // now would quiesce the session, and the shutdown that the leave asks for next
            // would wait for a return to the foreground (`MoshSession.shutdown`), so it would
            // never be sent. The end runs in its own background task (DESIGN.md 3.5 W4), the
            // pop in the one `endFromMenu` began; a death before the shutdown leaves the record
            // dirty, as W4 says.
            DebugLog.shared.log("session: resigned while End Session leaves the screen; no save, the shutdown follows")
            return
        }
        queue.send(.background(BackgroundTask(name: "save session")))
    }

    /// Returning with the process alive: "dirty", a new socket, and on from memory.
    func sceneDidBecomeActive() {
        isAppActive = true
        savePolicy.sceneBecameActive()
        activeSince = Date()
        guard let coordinator = queue.attached, !ended else { return }
        queue.send(.foreground)
        if startFailed {
            startFailed = false
            begin(coordinator)
        }
        // A size held while the app was not active.
        announceSize()
    }

    // MARK: Ending

    /// DESIGN.md 5.2: "…" (`ellipsis.circle`, identifier `sessionMenu`, label "Session"), a
    /// plain button with no `UIMenu` (decision D8: a `UIMenu` on the bar made the simulator
    /// lose the app's key commands now and then); a tap asks "End Session?" at once.
    private func installSessionMenu() {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .plain,
                                   target: self, action: #selector(confirmEndSession))
        item.accessibilityIdentifier = "sessionMenu"
        item.accessibilityLabel = "Session"
        navigationItem.rightBarButtonItem = item
    }

    @objc private func confirmEndSession() {
        // A question of the connect is up: it is answered first; "…" can be used after it.
        guard presentedViewController == nil else { return }
        let name = host?.host ?? queue.held?.meta.hostName ?? "the host"
        let alert = UIAlertController(
            title: "End Session?",
            message: "Ends the session on \(name): its shell and the programs in it stop.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.endConfirmationAnswered()
        })
        alert.addAction(UIAlertAction(title: "End Session", style: .destructive) { [weak self] _ in
            self?.endFromMenu()
            self?.endConfirmationAnswered()
        })
        endConfirmation = alert
        present(alert, animated: true)
    }

    /// The "End Session?" alert is gone (UIKit runs an action's handler after the dismissal):
    /// the prompts that waited for it go on. After "End Session" `endRequested` is set, so
    /// they return without asking; after Cancel they are shown.
    private func endConfirmationAnswered() {
        endConfirmation = nil
        let waiting = promptsWaitingForEndConfirmation
        promptsWaitingForEndConfirmation = []
        waiting.forEach { $0.resume() }
    }

    /// The confirmed "End Session": "last looked at" is cleared for the session this screen
    /// ends and for the old session of a fallback that is still connecting, before anything of
    /// the ending can be interrupted (DESIGN.md 2.5, 5.2); then the screen is left, and the
    /// leave ends the session (`leaveScreen`). Internal for the unit tests, which have no
    /// navigation controller and call `leaveScreen` after it.
    func endFromMenu() {
        // The slot's session, attached or not (a resumed one before `attach` too), as step 6
        // read it, and the old session of a fallback that is still connecting (E3).
        for id in LeaveAction.idsToClear(slot: queue.held?.id, old: oldSession) {
            SessionFiles.clearLastLookedAt(ifNamed: id)
        }
        endRequested = true
        // The process runs on until the leave has begun the end's own background task, also
        // when the scene resigns during the pop (ended in `leaveScreen`, or when this screen is
        // freed).
        endPopTask = BackgroundTask(name: "end session: the pop")
        DebugLog.shared.log("session: End Session from the … button")
        navigationController?.popViewController(animated: true)
    }

    /// Leaves the screen (DESIGN.md 5.3). First, in every case: nothing starts any more, the
    /// bootstrap is cancelled, the display link, timers and path watcher stop, and the scene no
    /// longer reaches this screen (`current`). Then one pure decision, `LeaveAction.decide`, says
    /// what becomes of the session. A leave ends a session only when "End Session" asked for it.
    ///
    /// - `park` (back, a coordinator in the slot, attached or not): `.park` at the end of the
    ///   queue, after everything sent before it, then the queue is finished; the slot is not
    ///   emptied here, the park empties it. The record counts as being saved until the queue's
    ///   consumer has ended (`SessionActivity.track`).
    /// - Every other action empties the slot first (`take()`), so that the queue's end never
    ///   parks or closes a coordinator handed to the ending code (a `close()` would cut a
    ///   shutdown short). Commands still queued then are dropped.
    /// - With nothing in the slot and a fallback still connecting (step 11b): back keeps the old
    ///   record and clears "last looked at" for it (`keepOldRecord`, B3); "End Session" stops its
    ///   server over SSH and forgets it only by `LeaveAction.afterStop` (`endDuringFallback`, E3).
    func leaveScreen() {
        guard !ended else { return }
        ended = true
        // After the action below has begun what it needs (the end's own background task).
        defer {
            endPopTask?.end()
            endPopTask = nil
        }
        // Nothing is left waiting for an alert that will not be answered here.
        endConfirmationAnswered()
        connectTask?.cancel()
        connectTask = nil
        displayLink?.invalidate()
        displayLink = nil
        resizeTimer?.invalidate()
        resizeTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
        pathWatcher?.stop()
        pathWatcher = nil
        if Self.current === self { Self.current = nil }
        let slotFilled = queue.held != nil
        let wasAttached = queue.isAttached
        let action = LeaveAction.decide(endRequested: endRequested, slotFilled: slotFilled, attached: wasAttached,
                                        serverEnded: serverEnded, fallbackInFlight: !slotFilled && oldSession != nil)
        DebugLog.shared.log("session: left the screen: \(action)")
        if wasAttached, let old = oldSession {
            // A fallback's new session was attached, and its `start()` may not have returned:
            // `sessionStarted`, which deletes the old record, may not run after the leave. The
            // old record is dirty and not wanted, as `sessionStarted` would find it (the
            // bootstrap has already tried the identity-checked kill of its server), and a kept
            // dirty record would start a session at the next launch: deleted here.
            if SessionFiles.forget(old) { oldSession = nil }
        }
        switch action {
        case .park:
            park()
        case .cancelStart:
            // Nothing in the slot and no old record (B2, E2): the bootstrap is cancelled above.
            queue.finish()
        case .keepOldRecord:
            // B3 (step 11b): back while a fallback was still connecting gives nothing up. The
            // attempt is cancelled above; the old record is kept as it is, dirty and closed (a
            // cold start's fallback holds no coordinator of it, a run-time fallback's `abandon()`
            // is a tracked release), and listed as "Could not be resumed": a later tap on it is
            // the fallback again (S4). Its server is not touched. "Last looked at" is cleared for
            // it, so that no later launch falls back into it by itself (reading 3, 10.3 item 4):
            // the launch opens only the session looked at last (step 11).
            queue.finish()
            guard let old = oldSession else { return }
            SessionFiles.clearLastLookedAt(ifNamed: old)
            DebugLog.shared.log("session: left during a fallback; the old record \(old) is kept")
        case .endDuringFallback:
            // E3 (step 11b): "End Session" while a fallback was still connecting. "Last looked
            // at" was cleared for the old session in the alert's action (`endFromMenu`). A
            // run-time fallback's `abandon()` (a tracked release) is awaited first, so the
            // record's lock is free; then the identity-checked kill of the old server, and the
            // record is forgotten only when `LeaveAction.afterStop` says so: a host that could
            // not be asked keeps it, with the pid that can stop its server later (R2 from its
            // row). Like every end, it runs in a background task of its own and the old record
            // reads "Ending…" until it returns (2.2, 3.5 W4).
            queue.finish()
            guard let old = oldSession else { return }
            let meta = oldMeta, host = self.host
            oldSession = nil
            let task = BackgroundTask(name: "end session: the old record of a fallback")
            SessionActivity.shared.beginEnd(old)
            Task {
                await SessionActivity.shared.settled()
                await Self.stopServerThenForgetIfStopped(old, meta: meta, host: host,
                                                         after: "End Session during a fallback")
                SessionActivity.shared.endFinished(old)
                task.end()
            }
        case .finishForget:
            // Already over on the server's word (the record is marked ended): there is no
            // shutdown to ask for, only the close and the delete, if the event task has not
            // done them yet (B4). A tracked release (G2, step 10).
            guard let coordinator = queue.take() else { return }
            queue.finish()
            SessionActivity.shared.track(release: coordinator.id) { await Self.finish(coordinator, .forget) }
        case .closeOnly:
            // "End Session" on a resumed screen before `attach`: nothing was started, and the
            // record stays as the cold start found it (C11). Only its lock is released, as a
            // tracked release. `shutdown()` would mark a clean session that never started
            // "ended" (RC:647-663).
            guard let coordinator = queue.take() else { return }
            queue.finish()
            SessionActivity.shared.track(release: coordinator.id) { await coordinator.close() }
        case .shutdown:
            guard let coordinator = queue.take() else { return }
            queue.finish()
            let host = self.host, id = coordinator.id
            // Today's `end`, in a background task of its own (DESIGN.md 3.5 W4); the row reads
            // "Ending…" until it returns (3.3 E1).
            let task = BackgroundTask(name: "end session")
            SessionActivity.shared.beginEnd(id)
            Task {
                await Self.end(coordinator, host: host)
                SessionActivity.shared.endFinished(id)
                task.end()
            }
        }
    }

    /// Ends the session as the leave did before step 9: a confirmed "End Session" (`endFromMenu`),
    /// then the leave. Called only by `TerminalScreenTests` (ScreenTests.swift), whose screen has
    /// no navigation controller; a plain `leaveScreen()` there would park its debug session and
    /// leave a resumable record in the app's session directory at every run.
    func endSession() {
        endFromMenu()
        leaveScreen()
    }

    /// DESIGN.md 2.3, on the main thread at once: a background task, `.park` at the end of the
    /// queue, the queue finished, and the record "being saved" until the queue's consumer ends.
    /// `attachedRestored` is known now: the slot's coordinator came from a cold start and
    /// `attach` has run for it.
    private func park() {
        guard let coordinator = queue.held else { return }
        let attachedRestored = queue.isAttached && coordinator.isRestored
        let task = BackgroundTask(name: "park session")
        if !queue.send(.park(task, attachedRestored: attachedRestored)) { task.end() }
        queue.finish()
        let consumer = queue.consumer
        SessionActivity.shared.track(release: coordinator.id) { _ = await consumer?.value }
    }

    /// A deliberate end: shutdown (mosh gives a shutdown 10 s). On `.shutdownFinished` the
    /// event task closes, and deletes only if the server acknowledged (`SessionEnding`); an
    /// unanswered one keeps the "ended" record, as here. Without it within 11 s the request may never have
    /// reached the server, which has no timeout of its own (docs/RESUME.md): the session is
    /// closed, and its "ended" record is kept, because it alone holds the pid and start time
    /// for the identity-checked kill at a later launch (`SessionLauncher.finishEnded`,
    /// review M6-4).
    private static func end(_ coordinator: ResumeCoordinator, host: SavedHost?) async {
        if await coordinator.shutdown() {
            try? await Task.sleep(nanoseconds: 11_000_000_000)
            await coordinator.close()
            if (try? SessionStore(root: SessionFiles.root, id: coordinator.id).exists) == true {
                DebugLog.shared.log("session: no end of the shutdown in 11 s; the ended record is kept for the next launch")
            }
        } else {
            // E4 (step 11b): the shutdown was refused. The record could not be made "not clean"
            // (docs/RESUME.md C7: nothing was sent, the server still runs), or the session was
            // already over. The session is closed; while its pid and start time are known the
            // server is stopped if the identity check passes, and the record is forgotten only
            // when `LeaveAction.afterStop` says so. Otherwise it is kept as its files say
            // (resumable, ended or dirty), without the dot (cleared in the alert's action), and
            // never resumed by itself: the launch opens only the session looked at last (step 11).
            DebugLog.shared.log("session: shutdown refused (the record cannot be written, or the session is over)")
            await coordinator.close()
            await stopServerThenForgetIfStopped(coordinator.id, meta: coordinator.meta, host: host,
                                                after: "refused shutdown")
        }
    }

    /// The end of a record that mosh's own shutdown could not end (E3, E4): the identity-checked
    /// kill of its server over SSH (`SessionLauncher.stopOldServer`), then the record, its key and
    /// its link forgotten only when `LeaveAction.afterStop` says so (DESIGN.md 5.3, review
    /// LC-14); otherwise it is kept as its files say. The one way these two ends reach
    /// `SessionFiles.forget`.
    private static func stopServerThenForgetIfStopped(_ id: SessionID, meta: SessionMeta?, host: SavedHost?,
                                                      after what: String) async {
        let outcome = await SessionLauncher.stopOldServer(meta: meta, host: host)
        switch LeaveAction.afterStop(outcome) {
        case .forget:
            DebugLog.shared.log("session: \(what); old server: \(outcome); the record of \(id) is forgotten")
            SessionFiles.forget(id)
        case .keep:
            DebugLog.shared.log("session: \(what); old server: \(outcome); the record of \(id) is kept for a later stop")
        }
    }

    /// The session is over: close it, and remove its record, key and link unless the server may
    /// still run (`SessionEnding`).
    private static func finish(_ coordinator: ResumeCoordinator, _ ending: SessionEnding) async {
        await coordinator.close()
        switch ending {
        case .forget:
            SessionFiles.forget(coordinator.id)
        case .keepEnded:
            DebugLog.shared.log("session: the shutdown was not answered; the ended record is kept for the identity-checked kill")
        }
    }

    // MARK: Font size keys

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + FontZoom.keyCommands(bigger: #selector(biggerFont(_:)),
                                                         smaller: #selector(smallerFont(_:)))
    }

    @objc private func biggerFont(_ sender: Any?) {
        fontZoom.step(by: 1)
    }

    @objc private func smallerFont(_ sender: Any?) {
        fontZoom.step(by: -1)
    }

    // MARK: Session

    private var viewSize: TerminalSize? {
        let columns = surface.columns, rows = surface.rows
        guard columns > 0, rows > 0, columns <= Int(UInt16.max), rows <= Int(UInt16.max) else { return nil }
        return TerminalSize(width: UInt16(columns), height: UInt16(rows))
    }

    /// Starts once the view has a size. A size change later (the keyboard coming up)
    /// is an ordinary Resize.
    private func startSessionIfNeeded() {
        guard !ended, !startRequested, let size = viewSize else { return }
        startRequested = true
        switch start {
        case .debug(let request):
            openSession(endpoint: request.endpoint, serverStartSize: request.serverStartSize,
                        clipboard: ClipboardPolicy(), serverPID: nil, serverStartTime: nil)
        case .host(let host):
            connectTask = Task { [weak self] in
                await self?.bootstrap(host, ptySize: size, replacing: nil)
            }
        case .resumed(let coordinator, _):
            DebugLog.shared.log("session: resumed \(coordinator.id)")
            attach(coordinator)
        case .fallback(let fallback, _, let debug):
            // docs/RESUME.md: show the message, bootstrap the new session, kill the old server
            // if the identity check passes, then delete the record.
            oldSession = fallback.id
            oldMeta = fallback.meta
            showStatus(ColdStartFallback.userMessage + "\n(" + fallback.reason + ")")
            startReplacement(for: SessionLauncher.serverIdentity(fallback.meta), size: size, debug: debug)
        }
    }

    /// The new session of a fallback: the debug fallback server, or a bootstrap of the saved
    /// host that kills the old server first if its identity check passes.
    private func startReplacement(for oldServer: ServerIdentity?, size: TerminalSize, debug: DebugLaunch.Request?) {
        if let debug {
            openSession(endpoint: debug.endpoint, serverStartSize: debug.serverStartSize,
                        clipboard: ClipboardPolicy(), serverPID: nil, serverStartTime: nil)
        } else if let host {
            connectTask = Task { [weak self] in
                await self?.bootstrap(host, ptySize: size, replacing: oldServer)
            }
        } else {
            // A debug session without fallback arguments: nothing to start it with.
            showStatus(ColdStartFallback.userMessage + "\nThere is no saved host for it; start a new one from the host list.")
            if let old = oldSession {
                SessionFiles.forget(old)
                oldSession = nil
            }
        }
    }

    /// The session cannot go on (the probe found its server gone, a lost base state, a halted
    /// transport): give it up through the coordinator (record "dirty", never resumed) and
    /// start a new one, as a cold start's fallback does.
    private func runtimeFallback(_ reason: String) {
        guard let old = queue.attached, !ended else { return }
        DebugLog.shared.log("session: fallback at run time: \(reason)")
        // The slot is emptied, as `coordinator = nil` did: `abandon()` below releases the old
        // session, and the replacement fills the slot again in `openSession` (DESIGN.md 5.3).
        queue.take()
        eventTask?.cancel()
        healthTimer?.invalidate()
        healthTimer = nil
        pathWatcher?.stop()
        pathWatcher = nil
        contactLabel.isHidden = true
        oldSession = old.id
        oldMeta = old.meta
        showStatus(ColdStartFallback.userMessage + "\n(" + reason + ")")
        let oldServer = SessionLauncher.serverIdentity(old.meta)
        let size = viewSize ?? announcedSize ?? TerminalRemoteState.defaultServerSize
        // A tracked release (G2, step 10), asked for now: an open after a back during it waits
        // until the old record is given up and closed. The replacement starts after it, as before.
        SessionActivity.shared.track(release: old.id) { [weak self] in
            await old.abandon()
            guard let self, !self.ended else { return }
            self.startReplacement(for: oldServer, size: size, debug: DebugLaunch.takeFallbackRequest())
        }
    }

    /// Design 4, steps 1 to 5: SSH with the device key, host key check, password if
    /// needed, the key install offer after a password login, (in a fallback) the old server
    /// killed if its identity check passes, `mosh-server new`, close.
    private func bootstrap(_ host: SavedHost, ptySize: TerminalSize, replacing oldServer: ServerIdentity?) async {
        showProgress("Connecting to \(host.user)@\(host.host)…")
        DebugLog.shared.log("bootstrap: \(host.host) port \(host.port)")
        do {
            let command = try host.serverCommand()
            let key: MoshKeys.StoredKey
            if host.keyName == DeviceKey.name {
                key = try DeviceKey.ensure(in: keyStore)
            } else if let stored = try keyStore.key(named: host.keyName) {
                key = stored
            } else {
                throw KeyStoreError.notFound(host.keyName)
            }
            let privateKey = try keyStore.loadPrivateKey(name: key.name)
            let interaction = SSHInteraction(
                confirmHostKey: { [weak self] prompt in
                    await self?.askToTrust(prompt) ?? false
                },
                password: { [weak self] prompt in
                    await self?.askPassword(prompt, key: key)
                })
            let connection = try await SSHConnection.connect(
                to: host.target, privateKey: privateKey, knownHosts: knownHosts, interaction: interaction)
            let result: BootstrapResult
            do {
                if connection.loginMethod == .password, !Task.isCancelled, await askToInstall(key, host: host) {
                    await install(key, over: connection)
                }
                showProgress("Starting mosh-server…")
                result = try await connection.startMoshServer(
                    command, columns: Int(ptySize.width), rows: Int(ptySize.height))
                if let oldServer {
                    // Plan section 3, "Fallback": in the same SSH connection, the old server is
                    // killed only if the identity check passes; and only now that the new one
                    // exists (docs/RESUME.md's order: bootstrap, kill, delete; review M6-8), so
                    // a start that fails does not leave the user with neither.
                    do {
                        try await connection.killServer(pid: oldServer.pid, expectedStartTime: oldServer.startTime)
                        DebugLog.shared.log("bootstrap: old mosh-server \(oldServer.pid) killed")
                    } catch BootstrapError.cancelled {
                        throw BootstrapError.cancelled
                    } catch {
                        DebugLog.shared.log("bootstrap: old mosh-server \(oldServer.pid) not killed: \(error)")
                    }
                }
                await connection.close()
            } catch {
                await connection.close()
                throw error
            }
            DebugLog.shared.log("bootstrap: MOSH CONNECT port \(result.udpPort) on \(result.remoteAddress), pid \(result.serverPID.map(String.init) ?? "?"), login \(result.loginMethod.rawValue)")
            guard !ended else {
                // Left during the bootstrap: the server gets no client and exits after 60 s.
                DebugLog.shared.log("bootstrap: screen left; the new server is not used")
                return
            }
            hideProgress()
            openSession(endpoint: try SessionEndpoint(bootstrap: result), serverStartSize: ptySize,
                        clipboard: ClipboardPolicy(isEnabled: host.allowClipboardWrite),
                        serverPID: result.serverPID, serverStartTime: result.serverStartTime)
            surface.focus()
        } catch {
            hideProgress()
            if ended { return }
            let text: String
            switch error {
            case let error as BootstrapError:
                if error == .cancelled { return }
                if case .serverStartFailed(_, let output) = error,
                   let full = PortRangeFull.message(output: output, host: host.displayName,
                                                    range: (try? host.serverCommand())?.portRange) {
                    // H3 (DESIGN.md 3.1, step 13): no free UDP port in the host's range. Nothing
                    // was made (no key, no link, no record). mosh's own lines stay below.
                    // In a fallback the old server still holds its port (it is killed only
                    // after the new one started), so the banner names that row.
                    text = full + (oldSession != nil ? " " + PortRangeFull.fallbackNote(host: host.displayName) : "")
                        + "\n" + output
                } else {
                    text = error.description
                }
            case let error as KeyStoreError:
                text = "The device key cannot be used: \(error)"
            default:
                text = "\(error)"
            }
            DebugLog.shared.log("bootstrap: failed: \(error)")
            showStatus(text)
        }
    }

    /// A new session and its record (plan section 4, step 6: the Keychain key, `meta` and the
    /// first counters reserve; only then the first datagram, at `start()`).
    private func openSession(endpoint: SessionEndpoint, serverStartSize: TerminalSize, clipboard: ClipboardPolicy,
                             serverPID: Int32?, serverStartTime: Date?) {
        // An empty slot, not "not attached": a coordinator in the slot that is not attached yet
        // must not get a new session beside it (DESIGN.md 2.3, rule 2; V-7).
        guard !ended, queue.held == nil, let size = viewSize else { return }
        let id = SessionID.random()
        // The key before the record: a crash in between leaves an orphan key (removed at the
        // next launch), never a record without its key.
        do {
            try SessionKeychain.shared.store(endpoint.key, for: id)
        } catch {
            showStatus("The session key could not be stored: \(error)")
            DebugLog.shared.log("session: key not stored: \(error)")
            return
        }
        SessionFiles.link(id, to: host?.id)
        let meta = SessionMeta(
            id: id,
            createdAt: UInt64(max(0, Date().timeIntervalSince1970)),
            hostName: host?.host ?? endpoint.host,
            address: endpoint.host,
            port: endpoint.port,
            user: host?.user ?? "",
            remoteCommand: host?.remoteCommand ?? "",
            serverStartSize: serverStartSize,
            serverPID: serverPID.flatMap { UInt32(exactly: $0) } ?? 0,
            // Seconds since 1970, as the identity check reads it back (it allows 2 s).
            serverStartTime: serverStartTime.map { UInt64(max(0, $0.timeIntervalSince1970.rounded())) } ?? 0)
        let coordinator: ResumeCoordinator
        do {
            coordinator = try ResumeCoordinator.create(
                root: SessionFiles.root, meta: meta, key: endpoint.key, storesKey: false, initialSize: size,
                options: SessionLauncher.options(address: endpoint.host, port: endpoint.port, clipboard: clipboard,
                                             localEcho: localEcho))
        } catch {
            SessionFiles.forget(id)
            showStatus("Could not start the session: \(error)")
            DebugLog.shared.log("session: record not made: \(error)")
            return
        }
        queue.hold(coordinator)
        announcedSize = size
        DebugLog.shared.log("session: new \(id) to \(endpoint.host) port \(endpoint.port) size \(size.width)x\(size.height)")
        attach(coordinator)
    }

    /// Takes a coordinator (new or resumed) as this screen's session and starts it.
    private func attach(_ coordinator: ResumeCoordinator) {
        queue.attach(coordinator)
        SessionFiles.setLastLookedAt(coordinator.id)
        frames.newSession()
        serverEnded = false
        lastContact = Date()
        activeSince = Date()
        nextProbeAt = .distantPast
        let events = coordinator.events
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                if let ending = SessionEnding.after(event) {
                    // Over: whether or not the screen is still there. A shutdown that timed out
                    // keeps its "ended" record (review M6-4). A tracked release (G2, step 10),
                    // awaited here: `handle` comes after the close and the delete (5.4).
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        SessionActivity.shared.track(release: coordinator.id) {
                            await Self.finish(coordinator, ending)
                            done.resume()
                        }
                    }
                }
                self?.handle(event, from: coordinator)
            }
        }
        if !endRequested, savePolicy.saveAtAttach(sceneInBackground: view.window?.windowScene?.activationState == .background) {
            // The scene is not active and its resign found no session (review M6-2): save
            // now, or a kill in the background leaves a dirty record. Queued before
            // `start()`; either order at the coordinator is safe (deferred start, C11). Not
            // while "End Session" leaves the screen (a bootstrap that finished during the pop):
            // the leave's shutdown follows, and a save would hold it back
            // (`sceneWillResignActive`).
            DebugLog.shared.log("session: attached while not active; saving")
            queue.send(.background(BackgroundTask(name: "save session")))
        }
        if case .resumed = start {
            // The cold start read the host's setting before this screen did: if it changed in
            // between, this screen's (the one it draws by) wins. Otherwise a no-op.
            queue.send(.prediction(localEcho.settings))
        }
        readSessionLocalEcho(coordinator)
        begin(coordinator)
        pathWatcher = PathWatcher { [weak self] path in
            guard let self, self.queue.isAttached else { return }
            DebugLog.shared.log("session: network path changed (\(path.interfaces.joined(separator: ","))), new socket")
            self.queue.send(.replaceSocket)
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        // The view may have changed size while the bootstrap ran.
        viewSizeChanged()
    }

    /// `start()`: for a resumed session the cold start's counters change and then the first
    /// datagram; its first screen is the stored one.
    private func begin(_ coordinator: ResumeCoordinator) {
        Task { @MainActor [weak self] in
            do {
                try await coordinator.start()
            } catch {
                DebugLog.shared.log("session: start failed: \(error)")
                guard let self, self.queue.attached === coordinator else { return }
                self.startFailed = true
                self.showStatus("The session could not be started now (\(error)). It is tried again when the app returns.")
                return
            }
            guard let self, self.queue.attached === coordinator else { return }
            self.sessionStarted(coordinator)
        }
    }

    private func sessionStarted(_ coordinator: ResumeCoordinator) {
        if let old = oldSession {
            // docs/RESUME.md: the record of a session that fell back is deleted once the new
            // session exists.
            if SessionFiles.forget(old) { oldSession = nil }
        }
        if let seconds = DebugLaunch.crashAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { DebugCrash.now() }
        }
    }

    private func handle(_ event: SessionEvent, from source: ResumeCoordinator) {
        guard source === queue.attached else { return }
        switch event {
        case .screen(let update):
            frames.take(screen: update.framebuffer)
            swipePaging.update(mouseMode: update.framebuffer.ds.mouseReportingMode)
            bell.observe(bellCount: update.framebuffer.bellCount, isLive: update.isLive,
                         session: ObjectIdentifier(source))
            if update.isLive { lastContact = Date() }
        case .contact:
            lastContact = Date()
        case .serverEnded:
            showStatus("Session ended")
            DebugLog.shared.log("session: server ended")
            sessionIsOver()
        case .noServerReply(let error):
            showStatus("\(error)")
            DebugLog.shared.log("session: no reply from the server")
        case .baseStateLost, .halted:
            DebugLog.shared.log("session: \(event)")
            runtimeFallback("the session cannot continue")
        case .networkProblem(let text):
            DebugLog.shared.log("session: network: \(text)")
        case .protocolProblem(let text):
            DebugLog.shared.log("session: \(text)")
        case .gateFailed(let text):
            // The record could not be written. One of these is a start that was put off
            // while in the background and failed at the return (C11; the normal path of a
            // session attached while not active): say so and ask again at the next return,
            // as for a `start()` that threw (review M6-7). `start()` does nothing for a
            // session that has started, so asking again is safe for the other gate failures.
            DebugLog.shared.log("session: \(text)")
            startFailed = true
            showStatus("The session's record could not be written (\(text)). It is tried again when the app returns.")
        case .clipboard(let decision):
            clipboardWriter.apply(decision)
        case .serverEndAcknowledged:
            sessionIsOver()
            returnToTheList()
        case .shutdownFinished, .instructionApplied:
            break
        case .display(let frame):
            frames.take(display: frame)
        }
    }

    /// The server ended the session: nothing watches it any more. Without this, 15 s of the
    /// silence that follows would probe, find no server and bootstrap a new session
    /// (review M6-3).
    private func sessionIsOver() {
        serverEnded = true
        healthTimer?.invalidate()
        healthTimer = nil
        pathWatcher?.stop()
        pathWatcher = nil
        contactLabel.isHidden = true
    }

    /// The server ended the session and has our acknowledgment (Ctrl-D, `exit`): the event task
    /// has closed and forgotten it already, so the screen goes back to the list by itself
    /// (DESIGN.md 5.4, 3.3 X1), if it has not been left and is the navigation's top. The leave
    /// that follows finds the server's end (`endSession`, `serverEnded`) and the record gone.
    /// An "End Session?" alert still up is taken down first: there is nothing left to end.
    private func returnToTheList() {
        let pop = { [weak self] in
            guard let self, !self.ended, let navigation = self.navigationController,
                  navigation.topViewController === self else { return }
            DebugLog.shared.log("session: the server ended the session; back to the list")
            navigation.popViewController(animated: true)
        }
        guard !ended, navigationController?.topViewController === self else { return }
        if presentedViewController != nil {
            dismiss(animated: false, completion: pop)
        } else {
            pop()
        }
    }

    // MARK: Health

    /// Every second: the "Last contact" banner (mosh's 6.5 s), and the SSH probe after 15 s
    /// without the server (plan section 4, "Session health"). Time spent in the background
    /// does not count.
    private func checkHealth() {
        let now = Date()
        let step = HealthPolicy.step(
            watching: queue.isAttached && isAppActive && !ended, serverEnded: serverEnded,
            silent: now.timeIntervalSince(max(lastContact, activeSince)), probing: probing,
            probeDue: now >= nextProbeAt)
        if step.showBanner {
            contactLabel.text = "Last contact \(Int(now.timeIntervalSince(lastContact))) s ago"
        }
        contactLabel.isHidden = !step.showBanner
        if step.probe {
            probe()
        }
    }

    private func probe() {
        guard !serverEnded, let coordinator = queue.attached, let host else {
            nextProbeAt = .distantFuture   // a debug session has no host to ask
            return
        }
        let meta = coordinator.meta
        guard let identity = SessionLauncher.serverIdentity(meta) else {
            DebugLog.shared.log("probe: the server's identity is not known; no probe")
            nextProbeAt = .distantFuture
            return
        }
        probing = true
        DebugLog.shared.log("probe: no contact for 15 s; asking \(host.host)")
        let keyStore = self.keyStore, knownHosts = self.knownHosts
        Task { @MainActor [weak self] in
            let privateKey = try? keyStore.loadPrivateKey(name: host.keyName)
            let result = await ServerProbe.probe(
                target: host.target, privateKey: privateKey,
                saved: ServerProbe.SavedSession(remoteAddress: meta.address, server: identity),
                knownHosts: knownHosts, interaction: .silent)
            DebugLog.shared.log("probe: \(result)")
            guard let self, self.queue.attached === coordinator else { return }
            self.probing = false
            // The server ended the session while the probe ran: its answer is not news.
            guard !self.serverEnded else { return }
            switch result.action {
            case .startNewSession:
                self.runtimeFallback(result.meaning)
            case .keepWaiting:
                self.nextProbeAt = Date().addingTimeInterval(15)
            case .informAndKeepSession:
                self.showStatus(result.meaning + (result.hint.map { "\n" + $0 } ?? ""))
                self.nextProbeAt = Date().addingTimeInterval(60)
            }
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }

    private func showProgress(_ text: String) {
        progressLabel.text = text
        progressLabel.isHidden = false
    }

    private func hideProgress() {
        progressLabel.isHidden = true
    }

    // MARK: Prompts (Design 4: host key on first contact, password, key install)

    /// One question of the connect. If "End Session?" from the "…" button is up, the question
    /// waits until it is answered (DESIGN.md 5.2, E2): after Cancel it is shown, after "End
    /// Session" it is not asked (nil), the screen is being left.
    private func ask<T>(_ alert: UIAlertController, build: (UIAlertController, @escaping (T) -> Void) -> Void) async -> T? {
        guard !ended, !endRequested, view.window != nil else { return nil }
        if endConfirmation != nil {
            DebugLog.shared.log("bootstrap: a question waits for the End Session alert")
            await withCheckedContinuation { promptsWaitingForEndConfirmation.append($0) }
            // Should the handler run before UIKit has finished taking the alert down.
            for _ in 0..<40 where presentedViewController?.isBeingDismissed == true && !ended {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !ended, !endRequested, view.window != nil else { return nil }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            var answered = false
            build(alert) { value in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: value)
            }
            present(alert, animated: true)
        }
    }

    private func askToTrust(_ prompt: HostKeyPrompt) async -> Bool {
        let alert = UIAlertController(
            title: "Unknown Host Key",
            message: "First connection to \(prompt.host) port \(prompt.port).\n\n\(prompt.keyType) key fingerprint:\n\(prompt.fingerprint)\n\nTrust it only if it is the host's own key (ssh-keygen -lf on the host).",
            preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "hostKeyAlert"
        let answer: Bool? = await ask(alert) { alert, answer in
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(false) })
            alert.addAction(UIAlertAction(title: "Trust", style: .default) { _ in answer(true) })
        }
        DebugLog.shared.log("bootstrap: host key \(prompt.fingerprint) \(answer == true ? "trusted" : "not trusted")")
        return answer ?? false
    }

    /// Asked for each login and never stored (Design 4, step 2). When the host rejected the
    /// key, the public key is shown with Copy (error table, "Key rejected").
    private func askPassword(_ prompt: PasswordPrompt, key: MoshKeys.StoredKey) async -> String? {
        var message = prompt.attempt > 1 ? "Wrong password. Try again." : ""
        if prompt.keyWasRejected {
            message += (message.isEmpty ? "" : "\n\n") + "The host rejected this device's key:\n\(key.authorizedKeysLine)"
        }
        let alert = UIAlertController(
            title: "Password for \(prompt.user)@\(prompt.host)", message: message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "passwordAlert"
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.textContentType = .password
            field.accessibilityIdentifier = "passwordField"
        }
        let answer: String?? = await ask(alert) { alert, answer in
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(nil) })
            if prompt.keyWasRejected {
                alert.addAction(UIAlertAction(title: "Copy Public Key", style: .default) { _ in
                    UIPasteboard.general.string = key.authorizedKeysLine
                    answer(nil)
                })
            }
            alert.addAction(UIAlertAction(title: "Log In", style: .default) { [weak alert] _ in
                answer(alert?.textFields?.first?.text ?? "")
            })
        }
        return answer ?? nil
    }

    /// "Install my key on this host" (Design 4), offered after a password login.
    private func askToInstall(_ key: MoshKeys.StoredKey, host: SavedHost) async -> Bool {
        let alert = UIAlertController(
            title: "Install My Key on This Host?",
            message: "You logged in with a password. Add this device's public key to ~/.ssh/authorized_keys on \(host.host), so the next login needs no password?\n\n\(key.fingerprint)",
            preferredStyle: .alert)
        let answer: Bool? = await ask(alert) { alert, answer in
            alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in answer(false) })
            alert.addAction(UIAlertAction(title: "Install My Key", style: .default) { _ in answer(true) })
        }
        return answer ?? false
    }

    private func install(_ key: MoshKeys.StoredKey, over connection: SSHConnection) async {
        let message: String
        do {
            let outcome = try await connection.installAuthorizedKey(key.publicKey)
            DebugLog.shared.log("bootstrap: key install: \(outcome)")
            message = outcome == .added
                ? "The key was added to ~/.ssh/authorized_keys."
                : "The key was already in ~/.ssh/authorized_keys."
        } catch {
            DebugLog.shared.log("bootstrap: key install failed: \(error)")
            message = "The key could not be installed: \(error)"
        }
        let alert = UIAlertController(title: "Install My Key", message: message, preferredStyle: .alert)
        let _: Bool? = await ask(alert) { alert, answer in
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in answer(true) })
        }
    }

    // MARK: Size

    /// SwiftTerm resized its grid: repaint fully at the next matching screen, and
    /// tell the server after 100 ms without another change.
    private func viewSizeChanged() {
        guard !ended else { return }
        shownSerial = nil
        resizeTimer?.invalidate()
        resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.announceSize()
        }
    }

    /// While the scene is not active the size is held (`SceneSavePolicy.announcesSize`) and
    /// announced at `sceneDidBecomeActive`.
    private func announceSize() {
        // Attached, not only held: a resumed screen's timer can fire before `attach`, and
        // `announcedSize` set then would keep `attach` from announcing the size (L2-S2).
        guard queue.isAttached, let size = viewSize, size != announcedSize else { return }
        guard savePolicy.announcesSize(sceneInBackground: view.window?.windowScene?.activationState == .background) else {
            DebugLog.shared.log("session: size \(size.width)x\(size.height) held until the app is active")
            let mark = BackgroundLayoutChange.heldMark(columns: Int(size.width), rows: Int(size.height))
            Task.detached { UITestMarks.send(mark) }
            return
        }
        announcedSize = size
        DebugLog.shared.log("session: resize \(size.width)x\(size.height)")
        queue.send(.resize(size))
    }

    // MARK: Local echo (M10)

    /// A saved host changed (`HostStore.upsert`). If it is this screen's host and its local
    /// echo changed, the open session follows at once: the frame to draw first (a switch to
    /// Never draws the server's screen), then `setPrediction` in the order of the commands.
    @objc private func hostSaved(_ notification: Notification) {
        guard let saved = notification.object as? SavedHost, saved.id == host?.id,
              saved.localEcho != localEcho, !ended else { return }
        DebugLog.shared.log("session: local echo now \(saved.localEcho.mode.rawValue)")
        localEcho = saved.localEcho
        host?.localEcho = saved.localEcho
        frames.setDisplay(localEcho.mode.display)
        queue.send(.prediction(localEcho.settings))
    }

    private func noteInput(_ count: Int) {
        guard UITestSupport.isUITesting else { return }
        inputSizes = Array((inputSizes + [count]).suffix(16))
    }

    /// UI tests: the setting as the session itself reports it.
    private func readSessionLocalEcho(_ coordinator: ResumeCoordinator) {
        guard UITestSupport.isUITesting else { return }
        Task { @MainActor [weak self] in
            let settings = await coordinator.predictionSettings()
            guard let self, self.queue.attached === coordinator else { return }
            self.sessionLocalEcho = settings.display.rawValue + (settings.overwrite ? "+overwrite" : "")
        }
    }

    // MARK: Drawing

    fileprivate func tick() {
        if let framebuffer = frames.framebuffer, frames.serial != shownSerial, surface.show(framebuffer) {
            shownSerial = frames.serial
            if !firstScreenShown {
                firstScreenShown = true
                if case .resumed = start {
                    // DESIGN.md risk 1: the cold start ran just before this screen was made.
                    let ms = Int(Date().timeIntervalSince(madeAt) * 1000)
                    DebugLog.shared.log("session: first screen of the resumed session shown \(ms) ms after its screen was made")
                }
            }
        }
        if UITestSupport.isUITesting {
            let drawn = surface.visibleText()
            screenText.update(rows: drawn)
            localEchoText.update(mode: localEcho.mode.rawValue, session: sessionLocalEcho,
                                 guesses: frames.hasPredictions, drawn: drawn,
                                 remote: frames.remote.map(LocalEchoElement.rows) ?? [], inputs: inputSizes)
            if Date().timeIntervalSince(appearanceShownAt) >= 1 {
                appearanceShownAt = Date()
                appearanceText.update(surface.appearanceDescription())
                let mode = traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
                barsText.update("system=\(mode) bars: " + (bars?.testDescription ?? "none"))
            }
        }
    }
}

/// The display link's target. `CADisplayLink` keeps its target strongly; this keeps the
/// controller weakly, so the link never keeps a left screen alive.
private final class DisplayLinkProxy: NSObject {
    weak var controller: TerminalViewController?

    init(_ controller: TerminalViewController) {
        self.controller = controller
    }

    @objc func tick() {
        controller?.tick()
    }
}

/// A `UIApplication` background task that is ended exactly once: when the work is done, or
/// when the system says the time is up.
final class BackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

    /// A task that nobody can end any more (a command dropped after its queue was finished)
    /// ends when it is freed (DESIGN.md 2.3, rule 3).
    deinit {
        end()
    }
}
