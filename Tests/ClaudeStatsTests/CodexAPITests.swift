import XCTest
@testable import ClaudeStats

final class CodexAPITests: XCTestCase {
    private func parse(_ json: String) throws -> CodexAPI.Result {
        try CodexAPI.parse(Data(json.utf8))
    }

    /// The shape a Plus account actually returns: one window, and it is weekly.
    func testSingleWeeklyWindowIsClassifiedByLengthNotPosition() throws {
        let result = try parse("""
        {"plan_type": "plus",
         "rate_limit": {"primary_window": {"used_percent": 3, "limit_window_seconds": 604800, "reset_at": 1787900751},
                        "secondary_window": null},
         "credits": {"has_credits": false, "unlimited": false, "balance": "0"}}
        """)
        XCTAssertEqual(result.limits.count, 1)
        XCTAssertEqual(result.limits[0].kind, "weekly_all")
        XCTAssertEqual(result.limits[0].percent, 3)
        XCTAssertEqual(result.limits[0].resetsAt?.timeIntervalSince1970, 1_787_900_751)
        XCTAssertEqual(result.footnote, "Plus plan")
    }

    func testSessionAndWeeklyWindows() throws {
        let result = try parse("""
        {"plan_type": "pro",
         "rate_limit": {"primary_window": {"used_percent": 15, "limit_window_seconds": 18000, "reset_at": 1},
                        "secondary_window": {"used_percent": 5, "limit_window_seconds": 604800, "reset_at": 2}},
         "credits": {"has_credits": true, "unlimited": false, "balance": 150.0}}
        """)
        XCTAssertEqual(result.limits.map(\.kind), ["session", "weekly_all"])
        XCTAssertEqual(result.footnote, "Pro plan · 150 credits")
    }

    func testMissingWindowLengthFallsBackToPosition() throws {
        let result = try parse("""
        {"rate_limit": {"primary_window": {"used_percent": 1, "reset_after_seconds": 100},
                        "secondary_window": {"used_percent": 2, "reset_after_seconds": 100}}}
        """)
        XCTAssertEqual(result.limits.map(\.kind), ["session", "weekly_all"], "must not collide both windows onto 'session'")
        XCTAssertNotNil(result.limits[0].resetsAt, "reset_after_seconds is an acceptable substitute for reset_at")
    }

    func testAdditionalRateLimitsBecomeScopedGauges() throws {
        let result = try parse("""
        {"rate_limit": {"primary_window": {"used_percent": 0, "limit_window_seconds": 18000}},
         "additional_rate_limits": [{"limit_name": "GPT-5.3-Codex-Spark",
            "rate_limit": {"primary_window": {"used_percent": 30, "limit_window_seconds": 18000},
                           "secondary_window": {"used_percent": 100, "limit_window_seconds": 604800}}}]}
        """)
        XCTAssertEqual(result.limits.count, 3)
        XCTAssertEqual(result.limits[2].kind, "weekly_scoped")
        XCTAssertEqual(result.limits[2].scope?.model?.displayName, "GPT-5.3-Codex-Spark")
    }

    func testAbsurdBalancesDoNotTrap() throws {
        XCTAssertEqual(try parse(#"{"credits": {"has_credits": true, "balance": 1e20}}"#).footnote, "100000000000000000000.00 credits")
        XCTAssertNil(try parse(#"{"credits": {"has_credits": true, "balance": "Infinity"}}"#).footnote)
        XCTAssertEqual(try parse(#"{"credits": {"has_credits": true, "unlimited": true}}"#).footnote, "unlimited credits")
    }

    func testEmptyBodyYieldsNoLimits() throws {
        let result = try parse("{}")
        XCTAssertTrue(result.limits.isEmpty)
        XCTAssertNil(result.footnote)
    }
}
