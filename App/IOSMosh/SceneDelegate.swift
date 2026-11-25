import MoshResume
import UIKit

/// The one scene. At launch it decides what a stored session becomes (docs/PLAN.md section
/// 3, "Cold start with a record"; `SessionLauncher.launch`: the session looked at last and no
/// other, docs/notes/multi-session/DESIGN.md 2.5), and it passes the scene's lifecycle to the
/// terminal screen that owns the live session: `sceneWillResignActive` saves it,
/// `sceneDidBecomeActive` continues it. When the launch's cold start said "try again later"
/// (device locked, record in use, storage error), the wait is in `SessionActivity` and the
/// launch asks again at the next activation (3.5 W6).
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        if UITestSupport.isUITesting, !UITestSupport.keepsAnimations {
            // XCUITest waits for animations to finish before every action. With the
            // keyboard and caret animating at launch it waits out a 60 s timeout. A test that
            // needs UIKit's own transitions passes `-uiTestingAnimations 1` (DESIGN.md step 9).
            UIView.setAnimationsEnabled(false)
            window.layer.speed = 100
        }
        AppFiles.resetForUITestsIfAsked()
        SessionFiles.resetForUITestsIfAsked()
        SessionFiles.applyCountersModeForUITestsIfAsked()
        window.rootViewController = makeRoot()
        window.makeKeyAndVisible()
        self.window = window
        if UITestSupport.isUITesting {
            LiveTerminalsElement().install(in: window)
        }

        #if DEBUG
        // Phone self-test: scripts/deploy.sh --smoke launches the app with SMOKE_* set.
        SmokeProbe.runIfRequested()
        #endif
    }

    func sceneWillResignActive(_ scene: UIScene) {
        TerminalViewController.current?.sceneWillResignActive()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        TerminalViewController.current?.sceneDidBecomeActive()
        retryColdStart()
    }

    // MARK: Start screen

    /// `-debugPlaceholder 1`: the M0 echo screen, nothing else. Otherwise the cold start of the
    /// launch target first (`SessionLauncher.launch`: the session looked at last, unless it is
    /// ended or gone; no other record is opened); when it opens nothing, a debug launch
    /// (`-debugMoshPort`, `-debugMoshKey`) opens that session over the host list, if no stored
    /// record names its server, and any other launch shows the host list.
    private func makeRoot() -> UIViewController {
        if DebugLaunch.placeholder {
            return PlaceholderViewController()
        }
        SessionFiles.removeOrphans()
        if UITestSupport.skipsColdStart {
            return AppNavigationController(rootViewController: SessionListViewController())
        }
        let firstRoot = Self.isFirstRootOfTheProcess()
        let launch = SessionLauncher.launch(last: SessionFiles.lastLookedAt(), ended: finishEndedSessions())
        if let terminal = terminal(for: launch.decision, target: launch.target) {
            return navigation(showing: terminal)
        }
        if case .nothing = launch.decision, firstRoot, let request = DebugLaunch.takeRequest() {
            return navigation(showing: TerminalViewController(start: .debug(request)))
        }
        return AppNavigationController(rootViewController: SessionListViewController())
    }

    /// The `-debugMosh*` request is read at the first root of the process only, as the fallback
    /// request is handed out once (`DebugLaunch.takeFallbackRequest`; review-steps-2-4.md
    /// R24-S4, read again by step 9's review). `makeRoot` runs at every connection of the scene,
    /// and iOS may disconnect a background scene and connect it again in the same process: a
    /// second read would make a second record under the same key from sequence 0 whenever the
    /// stored-record check does not see the first (its record forgotten while its server runs,
    /// or its `meta` unreadable). Debug builds only; a real host cannot repeat a key.
    private static var madeARoot = false

    private static func isFirstRootOfTheProcess() -> Bool {
        defer { madeARoot = true }
        if madeARoot { DebugLog.shared.log("launch: the scene connected again; no debug request is read") }
        return !madeARoot
    }

    /// The terminal screen the launch's decision for `target` opens, if any.
    private func terminal(for decision: LaunchDecision, target: SessionID?) -> TerminalViewController? {
        // The host list says that a session is waiting (review M6-6), and the launch asks again
        // at the next activation, until a later answer is something else or a tap, an end or a
        // forget drops the wait (DESIGN.md 2.2).
        if case .retryLater(let reason) = decision, let target {
            SessionActivity.shared.beginWait(for: target, reason: reason)
        } else {
            SessionActivity.shared.dropWait()
        }
        switch decision {
        case .nothing, .retryLater:
            return nil
        case .resumed(let coordinator):
            return TerminalViewController(start: .resumed(coordinator, host: SessionFiles.host(of: coordinator.id)))
        case .fallback(let fallback):
            let host = SessionFiles.host(of: fallback.id)
            guard fallback.wantsNewSession else {
                // Ended on purpose: no new session (docs/RESUME.md, `.fallback(.ended)`).
                Task { await SessionLauncher.finishEnded(fallback, host: host) }
                return nil
            }
            let debug = DebugLaunch.takeFallbackRequest()
            guard host != nil || debug != nil else {
                // Nothing to bootstrap a new session with (a debug session; a deleted host).
                SessionFiles.forget(fallback.id)
                DispatchQueue.main.async { [weak self] in
                    self?.alert(ColdStartFallback.plainMessage, fallback.reason)
                }
                return nil
            }
            return TerminalViewController(start: .fallback(fallback, host: host, debug: debug))
        }
    }

    /// Every session opens over the host list (back leaves it), also one without a saved host
    /// and a debug session (docs/notes/multi-session/DESIGN.md 5.1).
    private func navigation(showing terminal: TerminalViewController) -> UINavigationController {
        let navigation = AppNavigationController(rootViewController: SessionListViewController())
        navigation.pushViewController(terminal, animated: false)
        return navigation
    }

    /// DESIGN.md 3.5 W6: the launch said "try again later"; when the app becomes active it asks
    /// again for the launch target as it is then (`SessionLauncher.launch`). Only while it still
    /// waits and no open is in flight (`Busy.mayRetry`), and only when the host list is the top
    /// screen with nothing presented over it and no terminal screen is open; otherwise it keeps
    /// waiting, for the next activation (review M6-6: the wait is not dropped for the rest of the
    /// process). The retry runs as a tap's open does (`SessionListViewController.open`, 4.5),
    /// except that it does not drop the wait itself: "opening" is set, every release in flight
    /// has returned first (G2), the gate is asked after that (G3), and the decision and the push
    /// follow in the same main-actor turn, with the screen loaded before the push (2.3). A retry
    /// the gate drops keeps the wait.
    private func retryColdStart() {
        let activity = SessionActivity.shared
        guard activity.busy.mayRetry else { return }
        guard let navigation = window?.rootViewController as? UINavigationController,
              let list = navigation.topViewController as? SessionListViewController,
              list.presentedViewController == nil, TerminalViewController.current == nil else {
            DebugLog.shared.log("cold start: not tried again at activation (the list is not the top screen, or a session is open); asked again at the next activation")
            return
        }
        DebugLog.shared.log("cold start: tried again at activation for \(activity.busy.waiting?.description ?? "-")")
        SessionListViewController.open("the launch's retry", activity: activity, dropsTheWait: false, mayOpen: { [weak self, weak navigation, weak list] in
            guard let self, let navigation, let list else { return false }
            return OpenGate.mayOpen(sceneIsActive: self.window?.windowScene?.activationState == .foregroundActive,
                                    listIsOnTop: navigation.topViewController === list && list.presentedViewController == nil,
                                    terminalIsOpen: TerminalViewController.current != nil)
        }, action: { [weak self, weak navigation] in
            guard let self, let navigation else { return false }
            return self.retryNow(on: navigation)
        })
    }

    /// The retry's decision and push, after the settle and the gate, with no suspension. Nothing
    /// is opened when the wait was dropped meanwhile or the session looked at last is being ended
    /// (`SessionLauncher.retry`).
    private func retryNow(on navigation: UINavigationController) -> Bool {
        let waitedFor = SessionActivity.shared.busy.waiting
        guard let launch = SessionLauncher.retry(activity: .shared, last: SessionFiles.lastLookedAt(),
                                                 ended: { finishEndedSessions() }) else { return false }
        if launch.target != waitedFor {
            DebugLog.shared.log("cold start: the launch target is now \(launch.target?.description ?? "none"), it waited for \(waitedFor?.description ?? "none")")
        }
        guard let terminal = terminal(for: launch.decision, target: launch.target) else { return false }
        // Over the list, whether or not the session has a saved host (DESIGN.md 5.1); loaded
        // first, so that it is `TerminalViewController.current` before anything can start (2.3).
        terminal.loadViewIfNeeded()
        navigation.pushViewController(terminal, animated: true)
        return true
    }

    /// Every "ended" record, whatever its age (reviews M6-4, M6-5): in the background, one
    /// after the other, the old server is stopped if the identity check passes, and the
    /// record is deleted when nothing more can be done with it. None of them becomes a
    /// session, so the cold start skips them.
    private func finishEndedSessions() -> Set<SessionID> {
        let ended = SessionLauncher.endedRecords()
        guard !ended.isEmpty else { return [] }
        Task {
            for fallback in ended {
                await SessionLauncher.finishEnded(fallback, host: SessionFiles.host(of: fallback.id))
            }
        }
        return Set(ended.map(\.id))
    }

    private func alert(_ title: String, _ reason: String) {
        let alert = UIAlertController(title: title, message: reason, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        window?.rootViewController?.present(alert, animated: true)
    }
}

extension ColdStartFallback {
    /// The plan's message without "Starting a new one." for the case where nothing can be
    /// started.
    static let plainMessage = "Previous session could not be resumed."
}

/// The app's navigation controller: the status bar's style is the top screen's, so that the
/// terminal screen can have a light or dark status bar after its own colours (`TerminalBars`)
/// while the Hosts list and the other screens keep the system's (`.default`).
final class AppNavigationController: UINavigationController {
    override var childForStatusBarStyle: UIViewController? { topViewController }

    override func popViewController(animated: Bool) -> UIViewController? {
        defer { setNeedsStatusBarAppearanceUpdate() }
        return super.popViewController(animated: animated)
    }
}
