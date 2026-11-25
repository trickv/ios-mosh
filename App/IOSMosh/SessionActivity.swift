import Foundation
import MoshResume

/// What this process is doing to sessions besides the one on screen, and the order of the
/// releases of records (docs/notes/multi-session/DESIGN.md 2.2, 2.4 G2, section 7).
///
/// - A release (a park, and from step 10 the close after the server's end, the `abandon()` of a
///   run-time fallback, the close of a resumed coordinator that was not pushed) is tracked from
///   the moment it is asked for until it has returned: `track(release:until:)`. Meanwhile its
///   record counts as being saved (`parking`). `settled()` returns once every release asked for
///   before it has returned; from step 10 every open waits for it (G2), so that a record is clean
///   and closed before it is opened again. The record's lock (G1) stays the backstop: a second
///   open is refused, never a second writer.
/// - "Ending": a shutdown this process started, from the terminal or from a row, is in flight
///   (`beginEnd`, `endFinished`). Its row reads "Ending…" and takes no tap and no swipe.
/// - "Opening": a tap was accepted and has not produced a screen yet (`beginOpen`,
///   `openFinished`; used from step 10).
/// - "Waiting" (step 11; 2.2, 3.5 L5, W6): the launch asked for its target, the session looked at
///   last, and the answer was "try again later"; it asks again when the app next becomes active
///   (`SceneDelegate`). Set by the launch only (`beginWait`); dropped when a tap is accepted (4.5),
///   when that session's end begins or it is forgotten from its row, and when the launch's next
///   answer is not "try again later" (`dropWait`). The list shows its reason in the line "A
///   session is waiting: …".
/// - `onChange` is called after each of these changes; the host list reads the records again at
///   once (4.4).
///
/// Only the main thread uses it.
@MainActor
final class SessionActivity {
    static let shared = SessionActivity()

    /// The facts the host list and the launch's retry decide by (DESIGN.md 2.2, 3.1 H4, 3.2 S2,
    /// S8, 3.4 R6, 3.5 W6). Pure: the answers depend on these four values only. What the files
    /// say (live, ended) is the list's to ask besides.
    struct Busy: Equatable {
        /// Records whose release is in flight ("Saving…").
        var parking: Set<SessionID> = []
        /// Records whose shutdown this process started is in flight ("Ending…").
        var ending: Set<SessionID> = []
        /// A tap was accepted and has not produced a screen yet.
        var opening = false
        /// The launch's "try again later": the session it asks for again when the app becomes
        /// active (`beginWait`, `dropWait`).
        var waiting: SessionID? = nil

        /// A tap on a session row. A row being saved takes it (the open waits for the save, S2);
        /// one being ended does not (S8); while an open is in flight nothing does.
        func mayTap(session id: SessionID) -> Bool {
            !opening && !ending.contains(id)
        }

        /// A tap on a host row: a new session, also while a session of that host is being saved
        /// or ended (H2; step 8: a host tap ignores "ending"); not while an open is in flight (H4).
        var mayTapHost: Bool { !opening }

        /// "End Session" and "Forget" on a session row: not while it is being saved or ended,
        /// and not while an open is in flight (R6).
        func maySwipe(session id: SessionID) -> Bool {
            !opening && !ending.contains(id) && !parking.contains(id)
        }

        /// The launch asks again for the session it waits for (W6): only when it waits for one,
        /// and not while an open is in flight.
        var mayRetry: Bool { waiting != nil && !opening }
    }

    private(set) var busy = Busy()

    /// Why the launch waits (the cold start's "try again later"), for the list's waiting line;
    /// nil when it waits for nothing. Set and dropped with `busy.waiting`.
    private(set) var waitingReason: String?

    /// Called after every change of `busy` (DESIGN.md 4.4: the list reads the records again).
    var onChange: (@MainActor () -> Void)?

    /// How many releases of each record are in flight.
    private var releases: [SessionID: Int] = [:]
    /// How many shutdowns of each record are in flight.
    private var ends: [SessionID: Int] = [:]
    /// Ends when every release tracked so far has returned.
    private var tail: Task<Void, Never>?

    init() {}

    /// A release of `id` is in flight until `work` returns. `work` starts at once; the tail
    /// that `settled()` waits for now ends only after it, and after every release before it.
    func track(release id: SessionID, until work: @escaping @MainActor () async -> Void) {
        releases[id, default: 0] += 1
        busy.parking.insert(id)
        let previous = tail
        let release = Task { @MainActor [weak self] in
            await work()
            self?.released(id)
        }
        tail = Task { @MainActor in
            await previous?.value
            await release.value
        }
        changed()
    }

    /// Returns once every release tracked before this call has returned. No timeout, on purpose
    /// (risk 4): a timeout would open a record whose save is still running.
    func settled() async {
        await tail?.value
    }

    /// A shutdown of `id` begins. The record reads "ending" until every shutdown begun for it
    /// has finished: each `beginEnd` is matched by one `endFinished`, counted per record as the
    /// releases are (two enders of one record: a row's end over SSH still running when the
    /// same record is resumed and ended from the terminal). Whoever must not begin a second
    /// one asks `busy.ending` first.
    func beginEnd(_ id: SessionID) {
        ends[id, default: 0] += 1
        busy.ending.insert(id)
        changed()
    }

    /// One shutdown of `id` has finished; the record stops reading "ending" with the last one.
    func endFinished(_ id: SessionID) {
        guard let count = ends[id] else { return }
        if count > 1 {
            ends[id] = count - 1
        } else {
            ends[id] = nil
            busy.ending.remove(id)
        }
        changed()
    }

    /// A tap is accepted. False if an open is already in flight.
    @discardableResult
    func beginOpen() -> Bool {
        guard !busy.opening else { return false }
        busy.opening = true
        changed()
        return true
    }

    func openFinished() {
        guard busy.opening else { return }
        busy.opening = false
        changed()
    }

    /// The launch's cold start of `id`, its target, said "try again later" for `reason`: the app
    /// asks again for the launch target when it next becomes active (W6). Only the launch calls
    /// this.
    func beginWait(for id: SessionID, reason: String) {
        busy.waiting = id
        waitingReason = reason
        changed()
    }

    /// The launch waits for nothing any more: a tap was accepted, or its next answer was not
    /// "try again later".
    func dropWait() {
        guard busy.waiting != nil || waitingReason != nil else { return }
        busy.waiting = nil
        waitingReason = nil
        changed()
    }

    /// Drops the wait if it is for `id` (that session's end began, or it was forgotten).
    func dropWait(for id: SessionID) {
        guard busy.waiting == id else { return }
        dropWait()
    }

    private func released(_ id: SessionID) {
        let left = (releases[id] ?? 1) - 1
        if left > 0 {
            releases[id] = left
        } else {
            releases[id] = nil
            busy.parking.remove(id)
        }
        changed()
    }

    private func changed() {
        onChange?()
    }
}
