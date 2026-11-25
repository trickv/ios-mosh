/// When the terminal screen queues the background save (`enterBackground()`: quiesce,
/// snapshot, clean mark; docs/RESUME.md, "The app").
///
/// The scene's resign saves a session that exists then. A session that is attached while the
/// scene is not active (the bootstrap ended after Home, the replacement of a fallback, a
/// resumed session whose first layout came after the resign) gets no resign any more, so the
/// save is queued when it is attached (review M6-2). Queued before `start()`, either order at
/// the coordinator is safe: background first makes `start()` a deferred start (C11), start
/// first is followed by a normal save.
struct SceneSavePolicy {
    /// The scene resigned and has not become active since.
    private(set) var resigned = false

    /// `sceneWillResignActive`. Returns whether the save is queued now.
    mutating func sceneResigned(hasSession: Bool) -> Bool {
        resigned = true
        return hasSession
    }

    /// `sceneDidBecomeActive`.
    mutating func sceneBecameActive() {
        resigned = false
    }

    /// A coordinator becomes the screen's session. Returns whether the save is queued at once.
    /// `sceneInBackground`: the scene's own state says background (a resign this screen did
    /// not get, because it was not the current screen yet).
    func saveAtAttach(sceneInBackground: Bool) -> Bool {
        resigned || sceneInBackground
    }

    /// Whether a new view size goes to the session now. Not while the scene is not active
    /// (resigned, or in the background without a resign this screen saw): the session is saved
    /// for a process death then, and a resize that reached it would make the record dirty until
    /// the coordinator saved it again, so a kill in between ends in the fallback (the
    /// 2026-11-20 flake: iOS lays the view out again 0.8 s after the save). The size is
    /// announced at `sceneDidBecomeActive`.
    func announcesSize(sceneInBackground: Bool) -> Bool {
        !(resigned || sceneInBackground)
    }
}
