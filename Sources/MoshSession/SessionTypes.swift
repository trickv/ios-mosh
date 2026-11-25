import MoshBootstrap
import MoshCrypto
import MoshTerminal
import MoshTransport

/// Where a session's datagrams go: what `MOSH CONNECT` and the SSH connection said.
public struct SessionEndpoint: Equatable, Sendable {
    /// A numeric IPv4 or IPv6 address (no name lookup happens later).
    public var host: String
    public var port: UInt16
    public var key: Base64Key

    public init(host: String, port: UInt16, key: Base64Key) {
        self.host = host
        self.port = port
        self.key = key
    }

    /// From a bootstrap: the address the SSH connection used, the server's UDP port and key.
    public init(bootstrap result: BootstrapResult) throws {
        guard (1...Int(UInt16.max)).contains(result.udpPort) else {
            throw SessionError.invalidPort(result.udpPort)
        }
        self.init(host: result.remoteAddress, port: UInt16(result.udpPort),
                  key: try Base64Key(printable: result.sessionKey))
    }

    /// IPv6 if the address has a colon (numeric addresses only), which sets the datagram size.
    public var family: AddressFamily {
        host.contains(":") ? .ipv6 : .ipv4
    }
}

public enum SessionError: Error, Equatable, Sendable {
    case invalidPort(Int)
}

/// One screen to show.
public struct ScreenUpdate: Equatable, Sendable {
    /// The remote state's number.
    public var number: UInt64
    /// The terminal: `state.framebuffer` is the screen, `state.echoAck` the echo ack.
    public var state: TerminalState
    /// False for a state shown again without having just arrived (the first screen of a
    /// restored session). The surface feed draws it as a full repaint anyway. Whether its
    /// clipboard is written is the policy's decision, reported as a `.clipboard` event.
    public var isLive: Bool

    public init(number: UInt64, state: TerminalState, isLive: Bool) {
        self.number = number
        self.state = state
        self.isLive = isLive
    }

    public var framebuffer: Framebuffer { state.framebuffer }
}

/// What a `MoshSession` tells the app, in order.
public enum SessionEvent: Equatable, Sendable {
    /// A newer screen. Intermediate states may be skipped: only the newest matters.
    case screen(ScreenUpdate)
    /// An authentic datagram arrived; the ages at that moment. For a banner that counts seconds
    /// between datagrams, ask `MoshSession.contactAges()`.
    case contact(ContactAges)
    /// `ClipboardPolicy` said to write (`.write`) or to warn (`.invalid`). Other decisions are
    /// not reported.
    case clipboard(ClipboardPolicy.Decision)
    /// The server ended the session (the shell exited, or the server was told to stop). The
    /// final screen, if the last instruction could be applied. Nothing more is sent after the
    /// acknowledgment; the session is over.
    case serverEnded(TerminalState?)
    /// The shutdown this client asked for (`MoshSession.shutdown()`) finished: acknowledged by
    /// the server, or given up after 16 sends or 10 s.
    case shutdownFinished(acknowledged: Bool)
    /// The server builds on a state this client does not hold: the screen can never change
    /// again. The app falls back to a new session.
    case baseStateLost(serverBase: UInt64)
    /// The transport stopped for good because a send-side invariant (N1 to N4) did not hold.
    /// Nothing was sent that broke it. The app falls back to a new session.
    case halted(String)
    /// The durability gate failed; the send is retried in a second.
    case gateFailed(String)
    /// A socket or send error. The transport keeps trying.
    case networkProblem(String)
    /// The server sent an authentic instruction a correct server would not; it was dropped.
    case protocolProblem(String)
    /// No state came from the server within the no-reply timeout (15 s) after `start()`, although
    /// `MOSH CONNECT` was seen: the row "`MOSH CONNECT` seen, no UDP reply in 15 s" of the plan's
    /// error table. Always `BootstrapError.udpBlocked(port:)`. mosh's client shows "Timed out
    /// waiting for server..." in that case and starts a shutdown (stmclient.cc:532-538); the
    /// facade only reports it, once, and keeps the session: the app shows the error and closes
    /// it. Never reported for a restored session.
    case noServerReply(BootstrapError)
    /// Only with `TransportConfiguration.reportsInstructions` (test tools such as `moshcli
    /// --record`): a server instruction was applied, in arrival order. Comes before the
    /// `.screen` that includes it.
    case instructionApplied(AppliedInstruction)
    /// Our acknowledgment of the server's end of the session (`.serverEnded`) has been handed to
    /// the socket: the server can exit now, and the session may be closed.
    case serverEndAcknowledged
    /// Local echo (M10): the frame to draw, the remote framebuffer with the prediction engine's
    /// guesses drawn on it (mosh's `local_framebuffer`, stmclient.cc:267-287). Sent only while
    /// the prediction display mode is not `never`: after every new remote state (after its
    /// `.screen`), and whenever the drawn guesses change. One more follows a switch to `never`,
    /// holding the remote frame. A prediction is never part of `.screen`, `screen()` or a snapshot.
    case display(DisplayFrame)
}

/// One frame to draw while local echo is on (`SessionEvent.display`).
public struct DisplayFrame: Equatable, Sendable {
    /// 1, 2, 3 ... per session, one per `.display` event.
    public let serial: UInt64
    /// The remote state the frame is drawn on.
    public let number: UInt64
    /// The remote framebuffer with the predictions drawn.
    public let framebuffer: Framebuffer
    /// Whether `framebuffer` differs from the remote state's framebuffer.
    public let hasPredictions: Bool

    public init(serial: UInt64, number: UInt64, framebuffer: Framebuffer, hasPredictions: Bool) {
        self.serial = serial
        self.number = number
        self.framebuffer = framebuffer
        self.hasPredictions = hasPredictions
    }
}

/// Everything needed to continue a session in another `MoshSession` (another process, after
/// M6 stores it): the transport's snapshot and the clipboard policy's memory. Plain data;
/// its storage format is M6's (`MoshResume`).
///
/// Valid only as long as no datagram was sent after it was taken: the gate's dirty rule
/// (docs/PLAN.md section 3) decides whether it may be used.
public struct SessionSnapshot: Equatable, Sendable {
    public var transport: TransportSnapshot<TerminalRemoteState>
    public var clipboard: ClipboardPolicy

    public init(transport: TransportSnapshot<TerminalRemoteState>, clipboard: ClipboardPolicy) {
        self.transport = transport
        self.clipboard = clipboard
    }
}

/// What `MoshSession.exportState()` returns: the snapshot to store and the token for its clean
/// mark (`DurabilityGate.markClean(_:)`), taken at the same moment. The token is not stored.
public struct SessionExport: Equatable, Sendable {
    public var snapshot: SessionSnapshot
    public var cleanToken: CleanToken

    public init(snapshot: SessionSnapshot, cleanToken: CleanToken) {
        self.snapshot = snapshot
        self.cleanToken = cleanToken
    }
}
