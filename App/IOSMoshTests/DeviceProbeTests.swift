import Foundation
import MoshResume
import MoshSession
import MoshTransport
import Security
import XCTest
@testable import IOSMosh

/// The phone self-test's device part (`DeviceProbe`). The simulator reports no file protection
/// class, so these tests check the pieces and that a run cleans up after itself; the classes
/// themselves are read on the phone.
final class DeviceProbeTests: XCTestCase {
    func testSummaryUsesNearestRank() {
        let summary = DeviceProbe.summary([5, 1, 4, 2, 3, 10, 9, 8, 7, 6])
        XCTAssertEqual(summary["n"] as? Int, 10)
        XCTAssertEqual(summary["min"] as? Double, 1)
        XCTAssertEqual(summary["median"] as? Double, 5)
        XCTAssertEqual(summary["p90"] as? Double, 9)
        XCTAssertEqual(summary["max"] as? Double, 10)
        XCTAssertEqual(DeviceProbe.summary([])["n"] as? Int, 0)
        XCTAssertEqual(DeviceProbe.summary([2.5])["median"] as? Double, 2.5)
    }

    func testNames() {
        XCTAssertEqual(DeviceProbe.protectionName(nil), "none")
        XCTAssertEqual(DeviceProbe.protectionName(.completeUntilFirstUserAuthentication),
                       "completeUntilFirstUserAuthentication")
        XCTAssertEqual(DeviceProbe.protectionName(.complete), "complete")
        XCTAssertEqual(DeviceProbe.accessibleName(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
                       "AfterFirstUnlockThisDeviceOnly")
        XCTAssertEqual(DeviceProbe.accessibleName(kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
                       "WhenUnlockedThisDeviceOnly")
        XCTAssertEqual(DeviceProbe.accessibleName(nil), "missing")
    }

    /// OK only when every class is the plan's: a class of "none" (the simulator) is not OK.
    func testOKNeedsThePlansClasses() {
        func result(_ protection: String) -> [String: Any] {
            let classes = ["directory", "meta", "counters", "lock", "snapshot"].reduce(into: [String: String]()) {
                $0[$1] = protection
            }
            return [
                "record": ["protection": classes, "excludedFromBackup": true, "verify": true, "saves": 3,
                           "cleanSaves": 3, "deleted": true] as [String: Any],
                "keychain": ["probeItemMatches": true, "probeItemRemoved": true] as [String: Any],
            ]
        }
        XCTAssertTrue(DeviceProbe.isOK(result("completeUntilFirstUserAuthentication")))
        XCTAssertFalse(DeviceProbe.isOK(result("none")))
        XCTAssertFalse(DeviceProbe.isOK(result("complete")))
        var unclean = result("completeUntilFirstUserAuthentication")
        var record = unclean["record"] as! [String: Any]
        record["cleanSaves"] = 2
        unclean["record"] = record
        XCTAssertFalse(DeviceProbe.isOK(unclean))
    }

    /// A whole run in the app's process: every save ends clean, the record is excluded from
    /// backups, the Keychain item has the plan's class, and nothing is left behind.
    func testARunMeasuresAndCleansUp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-probe-\(UUID().uuidString)", isDirectory: true).path
        let service = "us.v9n.ios-mosh.tests.smoke-probe.\(UUID().uuidString)"
        let result = DeviceProbe.run(root: root, saves: 5, keychainService: service)
        let stage2 = try XCTUnwrap(result["stage2"] as? [String: Any])
        XCTAssertNil(stage2["error"])
        XCTAssertNotNil(stage2["append"] as? [String: Any])

        let record = try XCTUnwrap(result["record"] as? [String: Any])
        XCTAssertNil(record["error"])
        XCTAssertEqual(record["saves"] as? Int, 5)
        XCTAssertEqual(record["cleanSaves"] as? Int, 5)
        XCTAssertEqual((record["saveMs"] as? [String: Any])?["n"] as? Int, 5)
        XCTAssertEqual((record["firstDatagramAfterSaveMs"] as? [String: Any])?["n"] as? Int, 5)
        XCTAssertEqual(record["excludedFromBackup"] as? Bool, true)
        XCTAssertEqual(record["verify"] as? Bool, true)
        XCTAssertGreaterThan(record["snapshotBytes"] as? Int ?? 0, 0)
        XCTAssertEqual(record["deleted"] as? Bool, true)
        XCTAssertEqual((record["protection"] as? [String: String])?.count, 5)

        let keychain = try XCTUnwrap(result["keychain"] as? [String: Any])
        XCTAssertNil(keychain["error"])
        XCTAssertEqual(keychain["probeItem"] as? String, "AfterFirstUnlockThisDeviceOnly")
        XCTAssertEqual(keychain["probeItemMatches"] as? Bool, true)
        XCTAssertEqual(keychain["probeKeyReadsBack"] as? Bool, true)
        XCTAssertEqual(keychain["probeItemRemoved"] as? Bool, true)
        XCTAssertEqual(try SessionKeychain(service: service).sessionIDs(), [])

        XCTAssertEqual((result["lstatMissing"] as? [String: Any])?["isENOENT"] as? Bool, true)
        let boot = try XCTUnwrap(result["bootIdentifier"] as? [String: Any], "the boot identifier is published")
        XCTAssertEqual(boot["name"] as? String, "kern.bootsessionuuid")
        XCTAssertNotNil(boot["status"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root), "the probe's root is removed")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result), "it goes into smoke.json")
    }

    // MARK: Locked pass verdict

    private func lockedResult(available: Bool, readable: Bool, availableAfter: Bool? = nil,
                              readableAfter: Bool? = nil) -> [String: Any] {
        ["protectedDataAvailable": available, "controlCompleteReadable": readable,
         "protectedDataAvailableAfter": availableAfter ?? available,
         "controlCompleteReadableAfter": readableAfter ?? readable,
         "saveClean": true, "saveMs": 12.5, "reopen": "clean", "reopenSnapshotLoads": true,
         "createWhileLocked": true, "keychainReadable": true]
    }

    func testLockedNeedsBothSigns() {
        XCTAssertTrue(DeviceProbe.isLocked(protectedDataAvailable: false, controlReadable: false))
        XCTAssertFalse(DeviceProbe.isLocked(protectedDataAvailable: true, controlReadable: false))
        XCTAssertFalse(DeviceProbe.isLocked(protectedDataAvailable: false, controlReadable: true))
        XCTAssertFalse(DeviceProbe.isLocked(protectedDataAvailable: nil, controlReadable: false))
        XCTAssertFalse(DeviceProbe.isLocked(protectedDataAvailable: false, controlReadable: nil))
    }

    func testAPassThatRanLockedWithEveryCheckPassingIsOK() {
        XCTAssertEqual(DeviceProbe.lockedVerdict(lockedResult(available: false, readable: false)), .ok)
        XCTAssertEqual(DeviceProbe.LockedVerdict.ok.rawValue, "ok")
    }

    /// Run 556618dab8ac (build 117): every check passed, but protected data was available and
    /// the control file readable, so it proves nothing.
    func testTheSecondPhoneRunIsInvalid() {
        let run2: [String: Any] = [
            "ok": false, "protectedDataAvailable": true, "controlCompleteReadable": true,
            "secondsAfterLaunch": 39, "saveClean": true, "saveMs": 39.598, "createWhileLocked": true,
            "keychainReadable": true, "reopen": "dirty", "firstDatagramAfterSaveMs": 8.423,
        ]
        XCTAssertEqual(DeviceProbe.lockedVerdict(run2), .invalid)
        XCTAssertEqual(DeviceProbe.LockedVerdict.invalid.rawValue, "not locked - invalid")
    }

    func testOneSignOfTheLockIsNotEnough() {
        XCTAssertEqual(DeviceProbe.lockedVerdict(lockedResult(available: false, readable: true)), .invalid)
        XCTAssertEqual(DeviceProbe.lockedVerdict(lockedResult(available: true, readable: false)), .invalid)
    }

    /// Unlocked while the checks ran (or before the "after" look): invalid, not a failure.
    func testUnlockedDuringTheChecksIsInvalid() {
        XCTAssertEqual(DeviceProbe.lockedVerdict(lockedResult(available: false, readable: false,
                                                              availableAfter: true)), .invalid)
        XCTAssertEqual(DeviceProbe.lockedVerdict(lockedResult(available: false, readable: false,
                                                              readableAfter: true)), .invalid)
    }

    func testAPassThatEndedWithoutChecksIsInvalid() {
        XCTAssertEqual(DeviceProbe.lockedVerdict(["error": "no lock within 600 s"]), .invalid)
        XCTAssertEqual(DeviceProbe.lockedVerdict([:]), .invalid)
    }

    func testAFailedCheckWhileLockedIsAFailureNotInvalid() {
        for (key, value) in [("saveClean", false as Any), ("reopen", "dirty"), ("reopenSnapshotLoads", false),
                             ("createWhileLocked", false), ("keychainReadable", false), ("saveError", "io")] {
            var result = lockedResult(available: false, readable: false)
            result[key] = value
            XCTAssertEqual(DeviceProbe.lockedVerdict(result), .failed, key)
        }
        var noReopen = lockedResult(available: false, readable: false)
        noReopen["reopen"] = nil
        XCTAssertEqual(DeviceProbe.lockedVerdict(noReopen), .failed)
    }

    func testTheNotLockedMessageNamesWhatWasSeen() {
        let message = DeviceProbe.notLockedMessage(reason: "background time nearly over (4 s left)", observed: [
            "lastProtectedDataAvailable": true, "lastControlReadable": true, "backgroundAt": 37,
            "willBecomeUnavailableAt": 37,
        ])
        XCTAssertTrue(message.hasPrefix("background time nearly over (4 s left); not locked"), message)
        XCTAssertTrue(message.contains("last isProtectedDataAvailable true"), message)
        XCTAssertTrue(message.contains("last control file readable true"), message)
        XCTAssertTrue(message.contains("background at 37 s"), message)
        XCTAssertTrue(message.contains("protectedDataWillBecomeUnavailable at 37 s"), message)
        XCTAssertTrue(message.contains("protected data first unavailable at never"), message)
        XCTAssertTrue(message.contains("control file first unreadable at never"), message)
    }

    // MARK: Boot identifier (docs/notes/stage2/DESIGN.md section 8; section 12, step 0)

    private let uuid = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"

    private func fake(_ reads: [DeviceProbe.BootIdentifierRead]) -> [String: Any] {
        var left = reads
        return DeviceProbe.bootIdentifierCheck { left.removeFirst() }
    }

    private func bytes(_ text: String, nul: Bool = true) -> DeviceProbe.BootIdentifierRead {
        .bytes(Array(text.utf8) + (nul ? [0] : []))
    }

    /// The simulator reads the Mac's own value through the same call: a valid UUID, twice the same.
    func testTheBootIdentifierReadsHere() throws {
        guard case .bytes(let raw) = DeviceProbe.readBootIdentifier() else {
            return XCTFail("kern.bootsessionuuid could not be read here")
        }
        XCTAssertEqual(raw.last, 0, "sysctl hands the string with its NUL")
        let check = DeviceProbe.bootIdentifierCheck()
        XCTAssertEqual(check["valid"] as? Bool, true, "\(check)")
        XCTAssertEqual(check["status"] as? String, "ok: a well-formed UUID, not zero, the same in two reads")
        let value = try XCTUnwrap(check["value"] as? String)
        XCTAssertTrue(DeviceProbe.isUUIDText(value), value)
        XCTAssertEqual((check["digest"] as? String)?.count, 16)
        XCTAssertEqual((check["reads"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(check))
    }

    func testAWellFormedIdentifierIsValidAndTrimmed() throws {
        let check = fake([bytes(" \(uuid.uppercased())\n"), bytes(uuid)])
        XCTAssertEqual(check["valid"] as? Bool, true, "\(check)")
        XCTAssertEqual(check["readsEqual"] as? Bool, true, "the case does not count")
        XCTAssertEqual(check["value"] as? String, uuid.uppercased())
        XCTAssertEqual(check["digest"] as? String,
                       String(format: "%016llx", DeviceProbe.bootDigest(uuid)), "taken over the lower-case form")
        let reads = try XCTUnwrap(check["reads"] as? [[String: Any]])
        XCTAssertEqual(reads[0]["bytes"] as? Int, 39)
        XCTAssertEqual(reads[1]["bytes"] as? Int, 37)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(check))
    }

    /// 64-bit FNV-1a: the published offset basis and the vector for "a".
    func testTheDigestIsFNV1a() {
        XCTAssertEqual(DeviceProbe.bootDigest(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(DeviceProbe.bootDigest("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(DeviceProbe.bootDigest("A"), DeviceProbe.bootDigest("a"))
    }

    func testARefusedReadIsSaidAndNoValueIsMadeUp() throws {
        let check = fake([.failed(errno: EPERM, step: "size"), .failed(errno: EPERM, step: "size")])
        XCTAssertEqual(check["readable"] as? Bool, false)
        XCTAssertEqual(check["valid"] as? Bool, false)
        XCTAssertNil(check["value"])
        XCTAssertNil(check["digest"])
        let status = try XCTUnwrap(check["status"] as? String)
        XCTAssertTrue(status.hasPrefix("read refused: errno \(EPERM) ("), status)
        XCTAssertTrue(status.hasSuffix("at the size step"), status)
        let reads = try XCTUnwrap(check["reads"] as? [[String: Any]])
        XCTAssertEqual(reads[0]["errno"] as? Int, Int(EPERM))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(check))
    }

    func testAMissingNameIsSaid() throws {
        let check = fake([.failed(errno: ENOENT, step: "size"), .failed(errno: ENOENT, step: "size")])
        XCTAssertEqual(check["valid"] as? Bool, false)
        XCTAssertNil(check["value"])
        XCTAssertTrue((check["status"] as? String)?.hasPrefix("not there: errno \(ENOENT) (") == true, "\(check)")
    }

    func testOneFailedReadOfTwoIsNotValid() {
        let check = fake([bytes(uuid), .failed(errno: EIO, step: "read")])
        XCTAssertEqual(check["valid"] as? Bool, false)
        XCTAssertEqual(check["value"] as? String, uuid, "what the first read gave is shown")
        XCTAssertNil(check["digest"])
        XCTAssertTrue((check["status"] as? String)?.hasPrefix("read refused: errno \(EIO)") == true, "\(check)")
    }

    func testEmptyOrZeroIdentifierIsNotValid() {
        let cases: [([DeviceProbe.BootIdentifierRead], String)] = [
            ([.bytes([]), .bytes([])], "empty"),
            ([bytes(""), bytes("")], "empty"),
            ([bytes("  \n"), bytes("  \n")], "empty"),
            ([bytes("00000000-0000-0000-0000-000000000000"), bytes("00000000-0000-0000-0000-000000000000")],
             "the nil UUID"),
        ]
        for (reads, status) in cases {
            let check = fake(reads)
            XCTAssertEqual(check["valid"] as? Bool, false, status)
            XCTAssertEqual(check["status"] as? String, status, "\(check)")
            XCTAssertNil(check["digest"], status)
        }
    }

    func testAValueOfAnotherShapeIsNotAUUID() {
        let shapes = [
            String(uuid.dropLast()),                       // 35 characters
            uuid + "0",                                    // 37 characters
            uuid.replacingOccurrences(of: "-", with: ""),  // no hyphens
            "1b4e28ba2-fa1-11d2-883f-0016d3cca427",        // a hyphen out of place
            "1b4e28ba-2fa1-11d2-883f-0016d3cca42g",        // not hexadecimal
            "1b4e28ba-2fa1-11d2-883f-0016d3cc\u{0}427",    // a NUL inside
            "12345",
        ]
        for shape in shapes {
            let check = fake([bytes(shape), bytes(shape)])
            XCTAssertEqual(check["wellFormed"] as? Bool, false, shape)
            XCTAssertEqual(check["valid"] as? Bool, false, shape)
            XCTAssertEqual(check["status"] as? String, "not a UUID", shape)
        }
        XCTAssertTrue(DeviceProbe.isUUIDText(uuid))
        XCTAssertTrue(DeviceProbe.isUUIDText(uuid.uppercased()))
    }

    func testTwoReadsThatDifferAreNotValid() {
        let check = fake([bytes(uuid), bytes("2b4e28ba-2fa1-11d2-883f-0016d3cca427")])
        XCTAssertEqual(check["wellFormed"] as? Bool, true)
        XCTAssertEqual(check["notZero"] as? Bool, true)
        XCTAssertEqual(check["readsEqual"] as? Bool, false)
        XCTAssertEqual(check["valid"] as? Bool, false)
        XCTAssertEqual(check["status"] as? String, "two reads differ")
        XCTAssertNil(check["digest"])
    }

    // MARK: Record states

    /// The two states the verdicts look for print as before; every other state prints itself.
    /// Stage 1's other state (dirty) comes from a record that was only created, so that no test
    /// names a case resume stage 2 renames.
    func testStateNames() throws {
        XCTAssertEqual(DeviceProbe.stateName(.clean(snapshotID: 3)), "clean")
        XCTAssertEqual(DeviceProbe.stateName(.ended), "ended")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-probe-state-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let record = try SessionRecord.create(root: root, meta: DeviceProbe.meta(), key: nil)
        defer { try? record.delete() }
        let name = DeviceProbe.stateName(record.state)
        XCTAssertEqual(name, "\(record.state)")
        XCTAssertEqual(name, "dirty", "as the probe printed it before (stage 1)")
    }

    // MARK: Sample snapshot

    /// The locked pass saves `sampleSnapshot()` into a record, closes it, reopens it and loads
    /// the snapshot. Saving does not apply the format's rules; loading does. Build 182 found a
    /// sample the format refuses only on the phone ("used state counter is not above A"): this
    /// does the same round trip here, so a sample the codec refuses fails on the simulator.
    func testTheSampleSnapshotLoadsBackFromARecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-probe-sample-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sample = DeviceProbe.sampleSnapshot()
        let record = try SessionRecord.create(root: root, meta: DeviceProbe.meta(), key: nil)
        let id = record.id
        XCTAssertTrue(try record.save(SessionExport(snapshot: sample,
                                                    cleanToken: CleanToken(datagramsPassed: record.gate.datagramsPassed))))
        record.close()
        let reopened = try SessionRecord.open(root: root, id: id)
        defer { try? reopened.delete() }
        XCTAssertEqual(DeviceProbe.stateName(reopened.state), "clean")
        let loaded: SessionSnapshot
        do {
            loaded = try reopened.loadSnapshot()
        } catch {
            return XCTFail("the probe's sample does not load back: \(error)")
        }
        XCTAssertEqual(loaded.transport.usedCounters, sample.transport.usedCounters)
        XCTAssertEqual(loaded.transport.acknowledgedStateNumber, sample.transport.acknowledgedStateNumber)
        // As a real session's: everything up to state A was sent, so the first unused numbers
        // are above what a new session starts with.
        let used = sample.transport.usedCounters
        let start = GateCounters.sessionStart
        XCTAssertGreaterThan(used.state, sample.transport.acknowledgedStateNumber)
        XCTAssertGreaterThan(used.sequence, start.sequence)
        XCTAssertGreaterThan(used.fragmentID, start.fragmentID)
    }
}
