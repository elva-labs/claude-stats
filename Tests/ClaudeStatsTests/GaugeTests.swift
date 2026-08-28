import XCTest
@testable import ClaudeStats

final class GaugeTests: XCTestCase {
    private func limit(
        kind: String,
        group: String? = nil,
        percent: Double,
        severity: String? = nil,
        resetsAt: Date? = nil,
        model: String? = nil
    ) -> Limit {
        Limit(
            kind: kind,
            group: group,
            percent: percent,
            severity: severity,
            resetsAt: resetsAt,
            scope: model.map { Limit.Scope(model: .init(id: nil, displayName: $0), surface: nil) },
            isActive: nil
        )
    }

    func testLabelsForClaudeKinds() {
        XCTAssertEqual(Gauge(limit: limit(kind: "session", group: "session", percent: 1)).longLabel, "Session (5h)")
        XCTAssertEqual(Gauge(limit: limit(kind: "weekly_all", percent: 1)).longLabel, "Weekly · all models")
        let scoped = Gauge(limit: limit(kind: "weekly_scoped", percent: 1, model: "Fable"))
        XCTAssertEqual(scoped.longLabel, "Weekly · Fable")
        XCTAssertEqual(scoped.shortLabel, "F")
    }

    func testCodexWeeklyDropsAllModelsQualifier() {
        let gauge = Gauge(limit: limit(kind: "weekly_all", percent: 1), provider: .codex)
        XCTAssertEqual(gauge.longLabel, "Weekly")
        XCTAssertEqual(gauge.shortLabel, "W")
    }

    func testUnknownKindIsPrettified() {
        XCTAssertEqual(Gauge(limit: limit(kind: "monthly", percent: 1)).longLabel, "Monthly")
    }

    func testSeverityNeverShowsGreenForARedNumber() {
        XCTAssertEqual(Gauge(limit: limit(kind: "session", percent: 96, severity: "normal")).severity, .critical)
        XCTAssertEqual(Gauge(limit: limit(kind: "session", percent: 81, severity: "normal")).severity, .warning)
        XCTAssertEqual(Gauge(limit: limit(kind: "session", percent: 10, severity: "critical")).severity, .critical)
        XCTAssertEqual(Gauge(limit: limit(kind: "session", percent: 10)).severity, .normal)
    }

    func testExhaustion() {
        XCTAssertTrue(Gauge(limit: limit(kind: "session", percent: 100)).isExhausted)
        XCTAssertTrue(Gauge(limit: limit(kind: "session", percent: 90, severity: "blocked")).isExhausted)
        XCTAssertFalse(Gauge(limit: limit(kind: "session", percent: 99)).isExhausted)
    }

    func testSortOrderSessionThenWeeklyAllThenScoped() {
        XCTAssertEqual(Gauge(limit: limit(kind: "session", group: "session", percent: 0)).sortKey, 0)
        XCTAssertEqual(Gauge(limit: limit(kind: "weekly_all", percent: 0)).sortKey, 1)
        XCTAssertEqual(Gauge(limit: limit(kind: "weekly_scoped", percent: 0, model: "Fable")).sortKey, 2)
    }

    func testIdentityIsStableAcrossReadingsAndDistinctPerProvider() {
        let a = Gauge(limit: limit(kind: "session", percent: 10, resetsAt: Date()))
        let b = Gauge(limit: limit(kind: "session", percent: 90, resetsAt: Date().addingTimeInterval(3600)))
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, Gauge(limit: limit(kind: "session", percent: 10), provider: .codex).id)
    }

    func testSeriesKeysKeepClaudeUnprefixedAndQualifyOthers() {
        let plain = limit(kind: "session", percent: 0)
        XCTAssertEqual(plain.seriesKey(for: .claude), "session")
        XCTAssertEqual(plain.seriesKey(for: .codex), "codex:session")
        let scoped = limit(kind: "weekly_scoped", percent: 0, model: "Fable")
        XCTAssertEqual(scoped.seriesKey(for: .claude), "weekly_scoped:Fable")
    }

    func testEtaIsTerse() {
        let now = Date()
        let gauge = Gauge(limit: limit(kind: "session", percent: 100, resetsAt: now.addingTimeInterval(2 * 86_400 + 4 * 3600)))
        XCTAssertEqual(gauge.eta(now: now), "2d4h")
        XCTAssertEqual(Gauge(limit: limit(kind: "session", percent: 100, resetsAt: now.addingTimeInterval(72 * 60 + 30))).eta(now: now), "1h12m")
        XCTAssertEqual(Gauge(limit: limit(kind: "session", percent: 100, resetsAt: now.addingTimeInterval(20))).eta(now: now), "<1m")
        XCTAssertEqual(Gauge(limit: limit(kind: "session", percent: 100, resetsAt: now.addingTimeInterval(-5))).eta(now: now), "soon")
        XCTAssertNil(Gauge(limit: limit(kind: "session", percent: 100)).eta(now: now))
    }

    func testResetDescription() {
        let now = Date()
        XCTAssertEqual(
            Gauge(limit: limit(kind: "session", percent: 1, resetsAt: now.addingTimeInterval(3600 + 60))).resetDescription(now: now),
            "resets in 1h 1m"
        )
        XCTAssertEqual(
            Gauge(limit: limit(kind: "session", percent: 1, resetsAt: now.addingTimeInterval(-1))).resetDescription(now: now),
            "resetting…"
        )
        XCTAssertTrue(
            Gauge(limit: limit(kind: "session", percent: 1, resetsAt: now.addingTimeInterval(3 * 86_400)))
                .resetDescription(now: now)!.hasPrefix("resets ")
        )
    }
}
