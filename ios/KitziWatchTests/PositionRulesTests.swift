import XCTest

/// The rules that decide where a book is on the watch. Progress must never move
/// backwards or be lost, so each case here is one way it could.
final class PositionRulesTests: XCTestCase {
    typealias S = PositionRules.Saved

    // MARK: start

    func testNewerWatchPositionWins() {
        XCTAssertEqual(PositionRules.start(local: S(sec: 500, at: 2000), server: S(sec: 300, at: 1000), fallback: 0, fallbackAt: 0), 500)
    }

    func testNewerServerPositionWins() {
        XCTAssertEqual(PositionRules.start(local: S(sec: 500, at: 1000), server: S(sec: 900, at: 2000), fallback: 0, fallbackAt: 0), 900)
    }

    /// The server didn't answer in time: the shelf's newer position beats an old one on the watch.
    func testSlowServerShelfBeatsOldWatchPosition() {
        XCTAssertEqual(PositionRules.start(local: S(sec: 3600, at: 1000), server: nil, fallback: 18000, fallbackAt: 5000), 18000)
    }

    func testSlowServerNewerWatchPositionStillWins() {
        XCTAssertEqual(PositionRules.start(local: S(sec: 700, at: 9000), server: nil, fallback: 600, fallbackAt: 5000), 700)
    }

    /// When the server did answer, the shelf (an older copy of the server's) doesn't count.
    func testShelfIgnoredWhenServerAnswers() {
        XCTAssertEqual(PositionRules.start(local: nil, server: S(sec: 100, at: 3000), fallback: 999, fallbackAt: 9000), 100)
    }

    func testNothingKnownUsesFallback() {
        XCTAssertEqual(PositionRules.start(local: nil, server: nil, fallback: 42, fallbackAt: 0), 42)
    }

    func testFinishedBookStartsFromTheTop() {
        XCTAssertEqual(PositionRules.startOrTop(997, total: 1000), 0)
        XCTAssertEqual(PositionRules.startOrTop(990, total: 1000), 990)
    }

    // MARK: resume

    func testResumeIgnoresSmallDifferences() {
        XCTAssertFalse(PositionRules.shouldJump(to: 102, from: 100, total: 1000))
        XCTAssertTrue(PositionRules.shouldJump(to: 200, from: 100, total: 1000))
    }

    func testResumeNeverJumpsToTheEnd() {
        XCTAssertFalse(PositionRules.shouldJump(to: 998, from: 100, total: 1000))
    }

    // MARK: offline positions

    func testServerKeepsItsNewerPosition() {
        XCTAssertTrue(PositionRules.serverKeeps(serverAt: 2000, localAt: 1000))
        XCTAssertFalse(PositionRules.serverKeeps(serverAt: 1000, localAt: 2000))
        XCTAssertFalse(PositionRules.serverKeeps(serverAt: 1000, localAt: 1000))
    }

    // MARK: tracks

    func testLocateAcrossTracks() {
        let d: [Double] = [100, 200, 300]
        XCTAssertTrue(PositionRules.locate(50, durations: d) == (0, 50))
        XCTAssertTrue(PositionRules.locate(100, durations: d) == (1, 0))
        XCTAssertTrue(PositionRules.locate(350, durations: d) == (2, 50))
        // Past the end stays in the last track.
        XCTAssertTrue(PositionRules.locate(700, durations: d) == (2, 400))
        XCTAssertTrue(PositionRules.locate(-5, durations: d) == (0, 0))
    }

    // MARK: stream recovery

    func testStallLimitsThenGiveUp() {
        XCTAssertEqual(PositionRules.stallLimit(attempt: 0), 15)
        XCTAssertEqual(PositionRules.stallLimit(attempt: 2), 60)
        XCTAssertNil(PositionRules.stallLimit(attempt: 3))
    }

    // MARK: chapters

    func testChapterProgress() {
        let c = PositionRules.chapterProgress(position: 150, start: 100, end: 300)
        XCTAssertEqual(c.elapsed, 50)
        XCTAssertEqual(c.left, 150)
        XCTAssertEqual(c.fraction, 0.25, accuracy: 0.0001)
        // Outside the chapter: clamped.
        XCTAssertEqual(PositionRules.chapterProgress(position: 50, start: 100, end: 300).elapsed, 0)
    }
}
