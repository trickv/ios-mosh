import MoshWire

/// mosh's round-trip estimator (`Connection::recv_one`, `Connection::timeout`,
/// `TransportSender::send_interval`): RFC 6298 smoothing over the 16-bit timestamp echoes.
public struct RTTEstimator: Equatable, Sendable {
    /// mosh: `MIN_RTO`.
    public static let minimumRTO: UInt64 = 50
    /// mosh: `MAX_RTO`.
    public static let maximumRTO: UInt64 = 1000
    /// mosh: `SEND_INTERVAL_MIN`.
    public static let minimumSendInterval: UInt64 = 20
    /// mosh: `SEND_INTERVAL_MAX`.
    public static let maximumSendInterval: UInt64 = 250
    /// Samples of this many milliseconds or more are ignored ("e.g. server was Ctrl-Zed").
    public static let sampleLimit: UInt16 = 5000

    /// Smoothed round-trip time in milliseconds. Starts at 1000.
    public private(set) var srtt: Double = 1000
    /// Round-trip time variation in milliseconds. Starts at 500.
    public private(set) var rttvar: Double = 500
    /// Whether a sample has been taken (mosh: `RTT_hit`).
    public private(set) var hasSample = false

    public init() {}

    /// Takes the echo of one of our timestamps. `now` is the 16-bit time at which it came back.
    /// Returns false when the sample was ignored.
    @discardableResult
    public mutating func addSample(now: UInt16, timestampReply: UInt16) -> Bool {
        let sample = Timestamp16.difference(now, timestampReply)
        guard sample < Self.sampleLimit else { return false }
        let r = Double(sample)
        if !hasSample {
            srtt = r
            rttvar = r / 2
            hasSample = true
        } else {
            let alpha = 1.0 / 8.0
            let beta = 1.0 / 4.0
            rttvar = (1 - beta) * rttvar + beta * abs(srtt - r)
            srtt = (1 - alpha) * srtt + alpha * r
        }
        return true
    }

    /// The retransmission timeout: `ceil(SRTT + 4 * RTTVAR)`, within 50...1000 ms.
    public var timeout: UInt64 {
        let rto = UInt64((srtt + 4 * rttvar).rounded(.up))
        return min(max(rto, Self.minimumRTO), Self.maximumRTO)
    }

    /// The time between frames: `ceil(SRTT / 2)`, within 20...250 ms ("roughly two frames per
    /// RTT").
    public var sendInterval: UInt64 {
        let interval = UInt64((srtt / 2).rounded(.up))
        return min(max(interval, Self.minimumSendInterval), Self.maximumSendInterval)
    }
}
