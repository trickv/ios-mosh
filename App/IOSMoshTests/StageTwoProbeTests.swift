import Foundation
import XCTest
@testable import IOSMosh

/// Resume stage 2's phone figures (`StageTwoProbe`) and the write-kill-read-back record check
/// (`WriteKillProbe`). The kill itself and the figures are phone results; these tests check that
/// the measurements are taken and cleaned up, and that the check finds every kind of loss.
final class StageTwoProbeTests: XCTestCase {
    private func temporary(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true).path
    }

    func testTimingsAreTakenAndCleanedUp() throws {
        let directory = temporary("stage2-probe")
        let out = StageTwoProbe.timings(directory: directory)
        XCTAssertNil(out["error"])
        let append = try XCTUnwrap(out["append"] as? [String: Any])
        XCTAssertEqual(append["n"] as? Int, 1_000)
        XCTAssertEqual(append["failed"] as? Int, 0)
        XCTAssertEqual(append["fileBytes"] as? Int, 64_000)
        XCTAssertEqual((append["eachMs"] as? [String: Any])?["n"] as? Int, 1_000)
        XCTAssertNotNil(append["protection"] as? String)
        let checkpoint = try XCTUnwrap(out["checkpoint"] as? [String: Any])
        XCTAssertNil(checkpoint["error"], "\(checkpoint)")
        XCTAssertEqual((checkpoint["writeRenameMs"] as? [String: Any])?["n"] as? Int, 10)
        XCTAssertEqual((checkpoint["writeFullSyncRenameDirSyncMs"] as? [String: Any])?["n"] as? Int, 10)
        let codec = try XCTUnwrap(out["codec"] as? [String: Any])
        XCTAssertNil(codec["decodeError"])
        XCTAssertGreaterThan(codec["snapshotBytes"] as? Int ?? 0, 0)
        XCTAssertEqual(codec["actBytes"] as? Int, 3_000)
        XCTAssertEqual((codec["encodeMs"] as? [String: Any])?["n"] as? Int, 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }

    func testARecordIsSixtyFourBytesWithItsHash() {
        let record = WriteKillProbe.record(index: 7, runID: "0123456789ab", bootDigest: "00112233445566ff")
        XCTAssertEqual(record.count, 64)
        XCTAssertEqual(String(bytes: record.prefix(39), encoding: .ascii), "wk1 0123456789ab 0007 00112233445566ff ")
        let hash = WriteKillProbe.fnv32(Array(record.prefix(60)))
        XCTAssertEqual(Array(record.suffix(4)), [UInt8(hash & 0xff), UInt8((hash >> 8) & 0xff),
                                                 UInt8((hash >> 16) & 0xff), UInt8(hash >> 24)])
        // FNV-1a 32-bit test vectors.
        XCTAssertEqual(WriteKillProbe.fnv32([]), 0x811c_9dc5)
        XCTAssertEqual(WriteKillProbe.fnv32(Array("a".utf8)), 0xe40c_292c)
    }

    private func records(_ count: Int = WriteKillProbe.count, run: String = "0123456789ab",
                         boot: String = "00112233445566ff") -> [UInt8] {
        (0..<count).flatMap { WriteKillProbe.record(index: $0, runID: run, bootDigest: boot) }
    }

    func testAllRecordsInTheSameBootAreOK() {
        let out = WriteKillProbe.verify(records(), bootDigestNow: "00112233445566ff")
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(out["intact"] as? Int, 100)
        XCTAssertEqual(out["sameBoot"] as? Bool, true)
        XCTAssertEqual(out["runId"] as? String, "0123456789ab")
        XCTAssertEqual(out["verdict"] as? String, "ok: 100 of 100 records read back, same boot")
        let other = WriteKillProbe.verify(records(), bootDigestNow: nil)
        XCTAssertEqual(other["ok"] as? Bool, true)
        XCTAssertEqual(other["sameBoot"] as? Bool, false)
    }

    func testLossIsFound() {
        // A torn tail.
        var torn = records()
        torn.removeLast(10)
        var out = WriteKillProbe.verify(torn, bootDigestNow: nil)
        XCTAssertEqual(out["ok"] as? Bool, false)
        XCTAssertEqual(out["records"] as? Int, 99)
        XCTAssertEqual(out["tornBytes"] as? Int, 54)
        // Missing records at the end.
        out = WriteKillProbe.verify(records(60), bootDigestNow: nil)
        XCTAssertEqual(out["ok"] as? Bool, false)
        XCTAssertEqual(out["intact"] as? Int, 60)
        // One flipped byte.
        var flipped = records()
        flipped[64 * 40 + 20] ^= 0x01
        out = WriteKillProbe.verify(flipped, bootDigestNow: nil)
        XCTAssertEqual(out["ok"] as? Bool, false)
        XCTAssertEqual(out["intact"] as? Int, 99)
        // A record out of order (hash intact, index wrong).
        var swapped = records()
        let first = Array(swapped[0..<64])
        swapped.replaceSubrange(0..<64, with: swapped[64..<128])
        swapped.replaceSubrange(64..<128, with: first)
        out = WriteKillProbe.verify(swapped, bootDigestNow: nil)
        XCTAssertEqual(out["ok"] as? Bool, false)
        XCTAssertEqual(out["intact"] as? Int, 98)
        // Another run's record in the middle.
        var mixed = records()
        mixed.replaceSubrange(64 * 5..<64 * 6, with: WriteKillProbe.record(index: 5, runID: "ffffffffffff", bootDigest: "00112233445566ff"))
        XCTAssertEqual(WriteKillProbe.verify(mixed, bootDigestNow: nil)["intact"] as? Int, 99)
        // Nothing at all.
        out = WriteKillProbe.verify([], bootDigestNow: nil)
        XCTAssertEqual(out["ok"] as? Bool, false)
        XCTAssertEqual(out["intact"] as? Int, 0)
    }

    func testWriteThenReadBackOnceAndRemove() throws {
        let directory = temporary("write-kill")
        XCTAssertNil(WriteKillProbe.readBackIfPresent(directory: directory, bootDigestNow: nil))
        XCTAssertEqual(WriteKillProbe.write(directory: directory, runID: "abcdef012345", bootDigest: "0a0b0c0d0e0f1011"), 100)
        let out = try XCTUnwrap(WriteKillProbe.readBackIfPresent(directory: directory, bootDigestNow: "0a0b0c0d0e0f1011"))
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(out["sameBoot"] as? Bool, true)
        XCTAssertEqual(out["runId"] as? String, "abcdef012345")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
        XCTAssertNil(WriteKillProbe.readBackIfPresent(directory: directory, bootDigestNow: nil))
    }
}
