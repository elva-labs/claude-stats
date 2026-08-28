import XCTest
@testable import ClaudeStats

final class ISO8601Tests: XCTestCase {
    func testParsesTheShapesTheAPIsSend() {
        XCTAssertNotNil(ISO8601.parse("2026-08-25T08:00:00Z"))
        XCTAssertNotNil(ISO8601.parse("2026-08-25T08:00:00.914Z"))
        XCTAssertNotNil(ISO8601.parse("2026-08-25T08:00:00.914770+00:00"), "microseconds must be clamped, not rejected")
        XCTAssertNil(ISO8601.parse("yesterday"))
    }

    func testClampedMicrosecondsKeepTheInstant() {
        let a = ISO8601.parse("2026-08-25T08:00:00.914770+00:00")!
        let b = ISO8601.parse("2026-08-25T08:00:00.914Z")!
        XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: 0.001)
    }
}

final class StalenessTests: XCTestCase {
    func testLadder() {
        XCTAssertEqual(Staleness(age: 0), .fresh)
        XCTAssertEqual(Staleness(age: 299), .fresh)
        XCTAssertEqual(Staleness(age: 300), .aging)
        XCTAssertEqual(Staleness(age: 1_799), .aging)
        XCTAssertEqual(Staleness(age: 1_800), .stale)
        XCTAssertEqual(Staleness(age: 21_599), .stale)
        XCTAssertEqual(Staleness(age: 21_600), .ancient)
        XCTAssertEqual(Staleness(lastUpdated: nil), .ancient)
    }

    func testOnlyOldReadingsGetAnAgeLabel() {
        XCTAssertFalse(Staleness.fresh.warrantsAgeLabel)
        XCTAssertFalse(Staleness.aging.warrantsAgeLabel)
        XCTAssertTrue(Staleness.stale.warrantsAgeLabel)
        XCTAssertTrue(Staleness.ancient.warrantsAgeLabel)
    }

    func testOpacityRecedesMonotonically() {
        XCTAssertGreaterThan(Staleness.fresh.opacity, Staleness.aging.opacity)
        XCTAssertGreaterThan(Staleness.aging.opacity, Staleness.stale.opacity)
        XCTAssertGreaterThan(Staleness.stale.opacity, Staleness.ancient.opacity)
    }

    func testCompactAge() {
        let now = Date()
        XCTAssertEqual(Staleness.compactAge(since: now.addingTimeInterval(-10), now: now), "1m")
        XCTAssertEqual(Staleness.compactAge(since: now.addingTimeInterval(-7 * 60), now: now), "7m")
        XCTAssertEqual(Staleness.compactAge(since: now.addingTimeInterval(-3 * 3600), now: now), "3h")
        XCTAssertEqual(Staleness.compactAge(since: now.addingTimeInterval(-2 * 86_400), now: now), "2d")
    }
}
