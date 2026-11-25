import Foundation
import Network

/// What the app keeps of one `NWPath` update: enough to tell whether the network the
/// session's datagrams leave by has changed.
struct PathSnapshot: Equatable {
    /// `NWPath.status == .satisfied`.
    var isSatisfied: Bool
    /// The available interfaces in the system's order of preference (name and type, for
    /// example "en0/wifi"). The first one is the preferred interface.
    var interfaces: [String]

    var preferredInterface: String? { interfaces.first }
}

extension PathSnapshot {
    init(_ path: NWPath) {
        isSatisfied = path.status == .satisfied
        interfaces = path.availableInterfaces.map { "\($0.name)/\(Self.typeName($0.type))" }
    }

    private static func typeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wired"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }
}

/// Decides when a run of path updates is worth a new socket (docs/PLAN.md Design 1: "on a
/// better path, and on a non-viable or failed path, the connection opens a new one"). Pure,
/// so that it is tested without a network (`PathChangeFilterTests`).
///
/// - The first update after the monitor starts is the current state, not a change.
/// - A change is: the path becomes satisfied after it was not, or, while satisfied, the set
///   of available interfaces or the preferred interface changes. A path that becomes
///   unsatisfied is not one: there is nothing to open a socket on; the change that follows
///   (satisfied again) is.
/// - Bursts are debounced: `observe` says when to (re)start the timer, `timerFired` says
///   whether to replace the socket now. One network change, however many updates it makes
///   within the debounce interval, gives one replacement, and only on a satisfied path.
/// - The debounce has an upper bound: updates that keep coming less than the interval apart
///   do not put the new socket off for more than `maximumWait` after the change
///   (`timerDelay`, review M6-9).
struct PathChangeFilter {
    /// The debounce interval.
    static let debounce: TimeInterval = 0.3
    /// The longest time from a change to its timer, however many updates follow.
    static let maximumWait: TimeInterval = 2

    private(set) var last: PathSnapshot?
    private(set) var changePending = false
    /// When the pending change was first seen.
    private(set) var pendingSince: Date?

    /// Is `current` a change worth a new socket, compared to `previous`?
    static func isChange(from previous: PathSnapshot?, to current: PathSnapshot) -> Bool {
        guard let previous else { return false }
        guard current.isSatisfied else { return false }
        if !previous.isSatisfied { return true }
        return previous.interfaces != current.interfaces
            || previous.preferredInterface != current.preferredInterface
    }

    /// One path update. Returns true if the debounce timer is to be (re)started.
    mutating func observe(_ snapshot: PathSnapshot, at now: Date = Date()) -> Bool {
        let first = last == nil
        if Self.isChange(from: last, to: snapshot) {
            if !changePending { pendingSince = now }
            changePending = true
        }
        last = snapshot
        // Every update after a change restarts the timer, so a burst ends before it fires.
        return !first && changePending
    }

    /// The delay of the timer that `observe` asked for: the debounce interval, cut so that it
    /// fires no later than `maximumWait` after the pending change was first seen.
    func timerDelay(at now: Date = Date()) -> TimeInterval {
        guard let pendingSince else { return Self.debounce }
        let left = Self.maximumWait - now.timeIntervalSince(pendingSince)
        return min(Self.debounce, max(0, left))
    }

    /// The debounce timer fired. Returns true if the socket is to be replaced now.
    mutating func timerFired() -> Bool {
        guard changePending else { return false }
        guard last?.isSatisfied == true else { return false }   // wait for a usable path
        changePending = false
        pendingSince = nil
        return true
    }
}

/// Watches the network path for the screen that owns a session and calls `onChange` (on the
/// main queue) once per change that `PathChangeFilter` counts. The transport and
/// `MoshConnection` do not watch the path themselves; the owner answers `onChange` with the
/// session's `replaceSocket()`, the same call a return to the foreground makes.
final class PathWatcher {
    private let monitor = NWPathMonitor()
    private var filter = PathChangeFilter()
    private var timer: Timer?
    private let onChange: (PathSnapshot) -> Void

    init(onChange: @escaping (PathSnapshot) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = PathSnapshot(path)
            DispatchQueue.main.async { self?.update(snapshot) }
        }
        monitor.start(queue: DispatchQueue(label: "ios-mosh.path"))
    }

    deinit {
        stop()
    }

    func stop() {
        monitor.cancel()
        timer?.invalidate()
        timer = nil
    }

    private func update(_ snapshot: PathSnapshot) {
        DebugLog.shared.log("path: \(snapshot.isSatisfied ? "satisfied" : "unsatisfied") \(snapshot.interfaces.joined(separator: ","))")
        guard filter.observe(snapshot) else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: filter.timerDelay(), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil
            if self.filter.timerFired(), let path = self.filter.last {
                self.onChange(path)
            }
        }
    }
}
