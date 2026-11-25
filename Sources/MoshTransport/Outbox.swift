import MoshCrypto
import MoshWire

/// A broken send-side invariant. The datagram was not built, nothing reached the server, and the
/// transport stops sending for good: the owner falls back to a new session.
///
/// N1 to N4 are the hard failures of docs/PLAN.md section 3.
public enum InvariantViolation: Error, Equatable, Sendable {
    /// N1: a sequence number that is not above the last one used.
    case sequenceNotIncreasing(last: UInt64, offered: UInt64)
    /// N1: a sequence number at or above the gate's durable limit, or above 63 bits.
    case sequenceNotReserved(offered: UInt64, limit: UInt64)
    /// N2: a new state number that is not above every number used before.
    case stateNumberNotIncreasing(last: UInt64, offered: UInt64)
    /// N2: a new state number that the gate did not hand out or that is not below its limit.
    case stateNumberNotReserved(offered: UInt64, limit: UInt64)
    /// N2: a state number sent before would go out again with other content.
    case stateContentChanged(number: UInt64)
    /// N2: a new state would carry less input than an earlier one.
    case stateInputShorter(number: UInt64)
    /// The base of a diff is not a state the server was given, or not with this content.
    case baseStateUnknown(number: UInt64)
    /// N3: `throwaway_num` above `old_num`.
    case throwawayAboveOld(throwaway: UInt64, old: UInt64)
    /// N4: a fragment id that is not above the last one used.
    case fragmentIDNotIncreasing(last: UInt64, offered: UInt64)
    /// N4: a fragment id at or above the gate's durable limit.
    case fragmentIDNotReserved(offered: UInt64, limit: UInt64)
    /// 2^64 - 1 (shutdown) where an ordinary state number is required.
    case reservedStateNumber
    /// The input between the two states is not held any more, or the range is reversed.
    case inputNotHeld(from: UInt64, to: UInt64)
    /// The instruction could not be encoded (for one: larger than mosh's 4 MiB buffer).
    case encodingFailed(String)
}

/// Why `Outbox.send` produced nothing.
enum OutboxError: Error {
    /// A checked invariant does not hold. Permanent.
    case violation(InvariantViolation)
    /// The gate could not make a reservation or the dirty flag durable. Try again later.
    case gate(String)
}

/// What the sender wants on the wire. The diff is not part of it: the choke point builds the diff
/// from the input log, so a state number and its content cannot drift apart.
struct OutgoingInstruction: Equatable, Sendable {
    /// `old_num`: the state the diff is based on, and the input that state contains.
    var oldNum: UInt64
    var oldEnd: UInt64
    /// `new_num`: the state the diff leads to, and the input that state contains.
    var newNum: UInt64
    var newEnd: UInt64
    var ackNum: UInt64
    var throwawayNum: UInt64
}

/// The one place where datagrams are made.
///
/// Every datagram of the client leaves through `send`. It takes the fragment id and the sequence
/// numbers from the gate, builds the diff, and checks before anything is encrypted that
///
/// - N1: sequence numbers strictly increase and are below the gate's durable limit;
/// - N2: a new state number is above every earlier one and was handed out by the gate; a state
///   number sent before goes out again only with the same content; a later state never contains
///   less input than an earlier one;
/// - N3: `throwaway_num <= old_num`, and `old_num` is a state the server was given;
/// - N4: fragment ids strictly increase (a fresh id for every instruction) and are below the limit.
///
/// A failed check throws; no datagram of that instruction is returned. The checks use only what
/// this type recorded itself about earlier sends, not what the sender believes. After an import
/// it has recorded nothing, so it starts from what the old process's Outbox recorded: the
/// snapshot's `usedCounters`. A gate that hands out a number below them is refused like a gate
/// that repeats itself.
struct Outbox {
    /// Test-only: ways to break an instruction on its way to the checks.
    struct TestHooks {
        var instruction: (@Sendable (inout OutgoingInstruction) -> Void)?
        var sequence: (@Sendable (UInt64) -> UInt64)?
        var fragmentID: (@Sendable (UInt64) -> UInt64)?
        var stateNumber: (@Sendable (UInt64) -> UInt64)?
    }

    let cipher: MoshCipher
    let gate: any DurabilityGate
    var hooks = TestHooks()

    /// The last sequence number used, also by datagrams that were built and then dropped. After
    /// an import: one below the first number the old process had not used.
    private(set) var lastSequence: UInt64?
    /// The last fragment id used. After an import as `lastSequence`.
    private(set) var lastFragmentID: UInt64?
    /// Every state number below this was used before this Outbox existed (an import), or is the
    /// base both sides started from.
    private let stateFloor: UInt64
    /// The highest state number handed out by `takeStateNumber`.
    private(set) var lastIssuedStateNumber: UInt64?
    /// The highest `ack_num` sent, ignoring the shutdown value.
    private(set) var highestAckSent: UInt64
    /// Number of datagrams produced.
    private(set) var datagramsSent: UInt64 = 0

    /// The states the server may hold, ascending by number, with the input each contains.
    /// The first entry is the base both sides started from (state 0, or the acknowledged state of
    /// an imported snapshot).
    private var known: [(num: UInt64, end: UInt64)]
    /// Input contained in the shutdown state, once that was sent.
    private var shutdownEnd: UInt64?

    /// - Parameter usedBefore: for an import, the snapshot's `usedCounters`: the first sequence
    ///   number, state number and fragment id the old process had not used. Nil for a new session.
    init(cipher: MoshCipher, gate: any DurabilityGate, baseNum: UInt64, baseEnd: UInt64, highestAckSent: UInt64, usedBefore: GateCounters? = nil) {
        self.cipher = cipher
        self.gate = gate
        self.known = [(num: baseNum, end: baseEnd)]
        self.highestAckSent = highestAckSent
        if let usedBefore {
            lastSequence = usedBefore.sequence > 0 ? usedBefore.sequence - 1 : nil
            lastFragmentID = usedBefore.fragmentID > 0 ? usedBefore.fragmentID - 1 : nil
        }
        self.stateFloor = max(usedBefore?.state ?? 0, baseNum == UInt64.max ? baseNum : baseNum + 1)
    }

    /// The first sequence number, state number and fragment id that have not been used: every
    /// number this Outbox (and, after an import, the one before it) put on the wire or took from
    /// the gate is below them. This is what a snapshot stores as `usedCounters`.
    var usedCounters: GateCounters {
        let lastState = max(lastIssuedStateNumber ?? 0, known[known.count - 1].num)
        return GateCounters(
            sequence: lastSequence.map { $0 + 1 } ?? 0,
            state: max(stateFloor, lastState == UInt64.max ? lastState : lastState + 1),
            fragmentID: lastFragmentID.map { $0 == UInt64.max ? $0 : $0 + 1 } ?? 0
        )
    }

    /// A number for a new client state, from the gate.
    mutating func takeStateNumber() throws -> UInt64 {
        var number: UInt64
        do {
            number = try gate.takeStateNumber()
        } catch {
            throw OutboxError.gate("state number: \(error)")
        }
        if let hook = hooks.stateNumber { number = hook(number) }
        let last = max(lastIssuedStateNumber ?? 0, known.last?.num ?? 0, stateFloor > 0 ? stateFloor - 1 : 0)
        guard number > last else {
            throw OutboxError.violation(.stateNumberNotIncreasing(last: last, offered: number))
        }
        let limit = gate.reservedLimits.state
        guard number < limit, number != Instruction.shutdownNum else {
            throw OutboxError.violation(.stateNumberNotReserved(offered: number, limit: limit))
        }
        lastIssuedStateNumber = number
        return number
    }

    /// The sender dropped this state from its list and will not use it as a base again.
    mutating func forget(stateNumber: UInt64) {
        guard known.count > 1, let index = known.firstIndex(where: { $0.num == stateNumber }), index > 0 else { return }
        known.remove(at: index)
    }

    /// Builds the datagrams of one instruction. All or nothing.
    ///
    /// - Parameters:
    ///   - timestampReply: goes on the first datagram only, as in mosh (`Connection::new_packet`
    ///     clears the saved timestamp once it has been echoed).
    mutating func send(
        _ wanted: OutgoingInstruction,
        log: InputLog,
        chaff: [UInt8],
        contentsBudget: Int,
        timestamp: UInt16,
        timestampReply: UInt16
    ) throws -> [[UInt8]] {
        var request = wanted
        hooks.instruction?(&request)

        // N3, and the base must be something the server was given.
        guard request.oldNum != Instruction.shutdownNum, request.throwawayNum != Instruction.shutdownNum else {
            throw OutboxError.violation(.reservedStateNumber)
        }
        guard request.throwawayNum <= request.oldNum else {
            throw OutboxError.violation(.throwawayAboveOld(throwaway: request.throwawayNum, old: request.oldNum))
        }
        guard let base = known.first(where: { $0.num == request.oldNum }), base.end == request.oldEnd else {
            throw OutboxError.violation(.baseStateUnknown(number: request.oldNum))
        }

        // N2.
        let newest = known[known.count - 1]
        var isNewState = false
        if request.newNum == Instruction.shutdownNum {
            if let shutdownEnd, shutdownEnd != request.newEnd {
                throw OutboxError.violation(.stateContentChanged(number: request.newNum))
            }
            guard request.newEnd >= newest.end else {
                throw OutboxError.violation(.stateInputShorter(number: request.newNum))
            }
        } else if let sent = known.first(where: { $0.num == request.newNum }) {
            guard sent.end == request.newEnd else {
                throw OutboxError.violation(.stateContentChanged(number: request.newNum))
            }
        } else {
            guard request.newNum > newest.num else {
                throw OutboxError.violation(.stateNumberNotIncreasing(last: newest.num, offered: request.newNum))
            }
            let limit = gate.reservedLimits.state
            guard let issued = lastIssuedStateNumber, request.newNum <= issued, request.newNum < limit else {
                throw OutboxError.violation(.stateNumberNotReserved(offered: request.newNum, limit: limit))
            }
            guard request.newEnd >= newest.end else {
                throw OutboxError.violation(.stateInputShorter(number: request.newNum))
            }
            isNewState = true
        }
        guard request.newNum >= request.oldNum, request.newEnd >= request.oldEnd,
              let diff = log.diff(from: request.oldEnd, to: request.newEnd) else {
            throw OutboxError.violation(.inputNotHeld(from: request.oldEnd, to: request.newEnd))
        }

        // N4: a fresh id for every instruction.
        var fragmentID: UInt64
        do {
            fragmentID = try gate.takeFragmentID()
        } catch {
            throw OutboxError.gate("fragment id: \(error)")
        }
        if let hook = hooks.fragmentID { fragmentID = hook(fragmentID) }
        if let last = lastFragmentID, fragmentID <= last {
            throw OutboxError.violation(.fragmentIDNotIncreasing(last: last, offered: fragmentID))
        }
        let fragmentLimit = gate.reservedLimits.fragmentID
        guard fragmentID < fragmentLimit else {
            throw OutboxError.violation(.fragmentIDNotReserved(offered: fragmentID, limit: fragmentLimit))
        }
        lastFragmentID = fragmentID

        let instruction = Instruction(
            oldNum: request.oldNum,
            newNum: request.newNum,
            ackNum: request.ackNum,
            throwawayNum: request.throwawayNum,
            diff: diff,
            chaff: chaff
        )
        let fragments: [Fragment]
        do {
            fragments = try Fragmenter.makeFragments(instruction: instruction, id: fragmentID, contentsBudget: contentsBudget)
        } catch {
            throw OutboxError.violation(.encodingFailed("\(error)"))
        }

        // N1: one new sequence number for every datagram.
        var datagrams: [[UInt8]] = []
        datagrams.reserveCapacity(fragments.count)
        for (index, fragment) in fragments.enumerated() {
            var sequence: UInt64
            do {
                sequence = try gate.takeSequenceNumber()
            } catch {
                throw OutboxError.gate("sequence number: \(error)")
            }
            if let hook = hooks.sequence { sequence = hook(sequence) }
            if let last = lastSequence, sequence <= last {
                throw OutboxError.violation(.sequenceNotIncreasing(last: last, offered: sequence))
            }
            let limit = gate.reservedLimits.sequence
            guard sequence < limit, sequence <= MoshCipher.maxSequence else {
                throw OutboxError.violation(.sequenceNotReserved(offered: sequence, limit: limit))
            }
            // Burnt from here on, whatever happens to the datagram.
            lastSequence = sequence
            do {
                try gate.willSendDatagram()
            } catch {
                throw OutboxError.gate("dirty flag: \(error)")
            }
            let packet = Packet(
                seq: sequence,
                direction: .toServer,
                timestamp: timestamp,
                timestampReply: index == 0 ? timestampReply : Timestamp16.none,
                payload: fragment.serialized()
            )
            do {
                datagrams.append(try packet.encrypted(with: cipher))
            } catch {
                throw OutboxError.violation(.encodingFailed("\(error)"))
            }
        }

        // The instruction goes out: remember what the server may now hold.
        if request.newNum == Instruction.shutdownNum {
            shutdownEnd = request.newEnd
        } else if isNewState {
            known.append((num: request.newNum, end: request.newEnd))
        }
        // The server forgets everything below throwaway_num, and so do we, except that the list
        // never becomes empty (throwaway_num <= old_num, and old_num is in the list).
        known.removeAll { $0.num < request.throwawayNum }
        if request.ackNum != Instruction.shutdownNum {
            highestAckSent = max(highestAckSent, request.ackNum)
        }
        datagramsSent += UInt64(datagrams.count)
        return datagrams
    }
}
