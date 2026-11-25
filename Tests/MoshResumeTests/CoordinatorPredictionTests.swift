import Foundation
import MoshCrypto
import MoshSession
import MoshTerminal
import MoshTransport
import XCTest
@testable import MoshResume

/// Local echo through the coordinator (docs/notes/m10/DESIGN.md 5 item 1, step 7): the
/// setting in `Options.prediction` reaches every session the coordinator makes, new or
/// resumed, `setPrediction` changes the live one, and the setting is never part of the
/// record (the app passes it again at every `create` and `coldStart`).
final class CoordinatorPredictionTests: XCTestCase {
    private let size = TerminalSize(width: 80, height: 24)

    /// Sends nowhere, hears nothing.
    private final class Silent: DatagramTransport, @unchecked Sendable {
        func start(handler: @escaping @Sendable (DatagramTransportEvent) -> Void) {}
        func send(_ datagram: [UInt8]) {}
        func close() {}
    }

    private func options(_ prediction: PredictionSettings? = nil) -> ResumeCoordinator.Options {
        var options = ResumeCoordinator.Options()
        options.blocks = GateCounters(sequence: 4, state: 2, fragmentID: 2)
        options.noReplyTimeout = nil
        options.makeTransport = { Silent() }
        if let prediction { options.prediction = prediction }
        return options
    }

    func testTheDefaultIsOff() {
        XCTAssertEqual(ResumeCoordinator.Options().prediction, .off)
    }

    func testANewSessionGetsTheSettingAndSetPredictionChangesIt() async throws {
        let root = try scratchRoot("prediction")
        let wanted = PredictionSettings(display: .adaptive, overwrite: true)
        let coordinator = try ResumeCoordinator.create(root: root, meta: Fixtures.meta(id: .random()), key: Fixtures.key,
                                                       initialSize: size, options: options(wanted))
        var settings = await coordinator.predictionSettings()
        XCTAssertEqual(settings, wanted)
        try await coordinator.start()
        await coordinator.setPrediction(PredictionSettings(display: .experimental))
        settings = await coordinator.predictionSettings()
        XCTAssertEqual(settings, PredictionSettings(display: .experimental))
        // Experimental draws a guess at once (terminaloverlay.cc:657-659); the coordinator
        // forwards the `.display` it causes.
        let events = coordinator.events
        let seen = Task { () -> Bool in
            for await event in events {
                if case .display(let frame) = event, frame.hasPredictions { return true }
            }
            return false
        }
        _ = await coordinator.type(Array("a".utf8))
        let timeout = Task { try await Task.sleep(nanoseconds: 3_000_000_000); seen.cancel() }
        let predicted = await seen.value
        timeout.cancel()
        await coordinator.close()
        XCTAssertTrue(predicted, "no .display with the guess came through the coordinator")
    }

    /// A resumed session takes the setting from the options of its cold start, not from the
    /// record: a session saved with `always` and continued without a setting is `never`.
    func testAColdStartTakesTheSettingFromItsOptionsNotFromTheRecord() async throws {
        let root = try scratchRoot("prediction")
        let first = try ResumeCoordinator.create(root: root, meta: Fixtures.meta(id: .random()), key: Fixtures.key,
                                                 initialSize: size, options: options(PredictionSettings(display: .always)))
        let id = first.id
        try await first.start()
        _ = await first.type(Array("ls\r".utf8))
        await first.setPrediction(PredictionSettings(display: .experimental, overwrite: true))
        let saved = await first.enterBackground()
        XCTAssertEqual(saved, .clean)
        await first.close()

        guard case .resumed(let plain) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile,
                                                                     currentSize: size, options: options()) else {
            return XCTFail("not resumed")
        }
        var settings = await plain.predictionSettings()
        XCTAssertEqual(settings, .off, "the setting came back from the record")
        await plain.close()   // never started: the record stays clean

        let wanted = PredictionSettings(display: .adaptive)
        guard case .resumed(let second) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile,
                                                                      currentSize: size, options: options(wanted)) else {
            return XCTFail("not resumed")
        }
        settings = await second.predictionSettings()
        XCTAssertEqual(settings, wanted)
        try await second.start()
        await second.close()

        // That life died in the foreground: the fallback. The new session the app makes with
        // the same options has the setting too.
        guard case .fallback(let dead) = ResumeCoordinator.coldStart(root: root, id: id, key: .recordFile,
                                                                     currentSize: size, options: options(wanted)) else {
            return XCTFail("not a fallback")
        }
        let meta = try XCTUnwrap(dead.meta)
        try ResumeCoordinator.deleteRecord(root: root, id: id)
        let replacement = try ResumeCoordinator.create(root: root, meta: Fixtures.meta(id: .random()), key: Fixtures.key,
                                                       initialSize: size, options: options(wanted))
        XCTAssertEqual(meta.id, id)
        settings = await replacement.predictionSettings()
        XCTAssertEqual(settings, wanted)
        await replacement.close()
    }
}
