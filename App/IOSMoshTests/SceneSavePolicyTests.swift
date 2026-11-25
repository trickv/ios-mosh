import XCTest
@testable import IOSMosh

/// Review M6-2: a session that starts while the app is not active must still be saved.
final class SceneSavePolicyTests: XCTestCase {
    func testAResignWithASessionSavesAtOnce() {
        var policy = SceneSavePolicy()
        XCTAssertTrue(policy.sceneResigned(hasSession: true))
    }

    func testASessionAttachedWhileActiveIsNotSaved() {
        let policy = SceneSavePolicy()
        XCTAssertFalse(policy.saveAtAttach(sceneInBackground: false))
    }

    /// Sequence A: Home during the bootstrap, then the bootstrap ends and the session starts.
    func testAResignDuringTheBootstrapSavesWhenTheSessionIsAttached() {
        var policy = SceneSavePolicy()
        XCTAssertFalse(policy.sceneResigned(hasSession: false), "nothing to save yet")
        XCTAssertTrue(policy.saveAtAttach(sceneInBackground: false))
        // Still not active: a later attach (sequence C, the replacement of a fallback) too.
        XCTAssertTrue(policy.saveAtAttach(sceneInBackground: true))
    }

    /// Sequence C: the session was saved at the resign, fell back in the background, and its
    /// replacement is attached before the scene is active again.
    func testTheReplacementOfAFallbackWhileNotActiveIsSaved() {
        var policy = SceneSavePolicy()
        XCTAssertTrue(policy.sceneResigned(hasSession: true))
        XCTAssertTrue(policy.saveAtAttach(sceneInBackground: true))
    }

    /// Sequence B: the scene went to the background before the resumed session's screen was
    /// the current one, so this screen saw no resign.
    func testAResumedSessionAttachedInTheBackgroundIsSaved() {
        let policy = SceneSavePolicy()
        XCTAssertTrue(policy.saveAtAttach(sceneInBackground: true))
    }

    func testBackInTheForegroundBeforeTheSessionStartsNeedsNoSave() {
        var policy = SceneSavePolicy()
        XCTAssertFalse(policy.sceneResigned(hasSession: false))
        policy.sceneBecameActive()
        XCTAssertFalse(policy.saveAtAttach(sceneInBackground: false))
        // And a later resign with the session is the ordinary save.
        XCTAssertTrue(policy.sceneResigned(hasSession: true))
    }

    /// The 2026-11-20 flake: a size change after the background save must not reach the
    /// session until the scene is active again.
    func testASizeChangeIsHeldWhileTheSceneIsNotActive() {
        var policy = SceneSavePolicy()
        XCTAssertTrue(policy.announcesSize(sceneInBackground: false), "active: at once")
        XCTAssertTrue(policy.sceneResigned(hasSession: true))
        XCTAssertFalse(policy.announcesSize(sceneInBackground: false), "resigned: held")
        XCTAssertFalse(policy.announcesSize(sceneInBackground: true), "in the background: held")
        policy.sceneBecameActive()
        XCTAssertTrue(policy.announcesSize(sceneInBackground: false), "active again: announced")
    }

    /// A screen that saw no resign but whose scene is in the background (sequence B) holds it
    /// too.
    func testASizeChangeIsHeldInTheBackgroundWithoutAResign() {
        let policy = SceneSavePolicy()
        XCTAssertFalse(policy.announcesSize(sceneInBackground: true))
    }
}
