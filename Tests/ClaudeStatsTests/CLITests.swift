import XCTest
@testable import ClaudeStats

final class CLIOptionsTests: XCTestCase {
    func testDefaultsToUsageFromTheCache() throws {
        let options = try CLI.parse([])
        XCTAssertEqual(options.command, .usage)
        XCTAssertFalse(options.json)
        XCTAssertNil(options.providers, "nil means Claude plus Codex-if-logged-in, decided at run time")
        XCTAssertEqual(options.maxAge, CLI.defaultMaxAge)
    }

    func testFreshnessFlags() throws {
        XCTAssertEqual(try CLI.parse(["usage", "--cached"]).maxAge, .infinity)
        XCTAssertEqual(try CLI.parse(["--fresh"]).maxAge, 0)
        XCTAssertEqual(try CLI.parse(["--max-age", "30"]).maxAge, 30)
        XCTAssertThrowsError(try CLI.parse(["--cached", "--fresh"]))
        XCTAssertThrowsError(try CLI.parse(["--max-age", "soon"]))
        XCTAssertThrowsError(try CLI.parse(["--max-age", "-1"]))
        XCTAssertThrowsError(try CLI.parse(["--max-age"]))
    }

    func testProviders() throws {
        XCTAssertEqual(try CLI.parse(["--provider", "codex"]).providers, [.codex])
        XCTAssertEqual(try CLI.parse(["--provider", "codex,claude"]).providers, [.codex, .claude])
        XCTAssertEqual(try CLI.parse(["--provider", "claude", "--provider", "claude"]).providers, [.claude])
        XCTAssertEqual(try CLI.parse(["--provider", "all"]).providers, Provider.allCases)
        XCTAssertThrowsError(try CLI.parse(["--provider", "gemini"]))
    }

    func testHelpVersionAndUnknown() throws {
        XCTAssertEqual(try CLI.parse(["--help"]).command, .help)
        XCTAssertEqual(try CLI.parse(["-V"]).command, .version)
        XCTAssertEqual(try CLI.parse(["usage", "--json"]).json, true)
        XCTAssertThrowsError(try CLI.parse(["--bogus"])) { error in
            XCTAssertEqual(error as? CLI.UsageError, .unknownArgument("--bogus"))
        }
    }
}

final class CLIReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func limit(_ kind: String, percent: Double, resetsIn: TimeInterval, model: String? = nil) -> Limit {
        Limit(
            kind: kind, group: kind == "session" ? "session" : "weekly", percent: percent,
            severity: nil, resetsAt: now.addingTimeInterval(resetsIn),
            scope: model.map { Limit.Scope(model: .init(id: nil, displayName: $0), surface: nil) },
            isActive: nil
        )
    }

    private func decode(_ report: CLI.Report) throws -> [String: Any] {
        let data = Data(report.json().utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testJSONShape() throws {
        let reading = CLI.Reading(
            source: .cache, at: now.addingTimeInterval(-90),
            limits: [
                limit("weekly_scoped", percent: 12.4, resetsIn: 86_400 * 3, model: "Fable"),
                limit("session", percent: 46.6, resetsIn: 3_600),
            ],
            extraUsage: nil, footnote: nil
        )
        let report = CLI.Report(providers: [.claude], outcomes: [.claude: CLI.Outcome(reading: reading)], now: now)
        let root = try decode(report)
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let claude = try XCTUnwrap(providers["claude"] as? [String: Any])

        XCTAssertEqual(claude["source"] as? String, "cache")
        XCTAssertEqual(claude["age_seconds"] as? Int, 90)
        XCTAssertTrue(claude["error"] is NSNull, "absent keys make scripts guess; null does not")
        XCTAssertTrue(claude["note"] is NSNull)

        let limits = try XCTUnwrap(claude["limits"] as? [[String: Any]])
        XCTAssertEqual(limits.map { $0["kind"] as? String }, ["session", "weekly_scoped"], "session first, like the dropdown")
        XCTAssertEqual(limits[0]["percent"] as? Int, 47)
        XCTAssertEqual(limits[0]["remaining_percent"] as? Int, 53)
        XCTAssertEqual(limits[0]["resets_in_seconds"] as? Int, 3_600)
        XCTAssertEqual(limits[0]["severity"] as? String, "normal")
        XCTAssertEqual(limits[0]["exhausted"] as? Bool, false)
        XCTAssertTrue(limits[0]["model"] is NSNull)
        XCTAssertEqual(limits[1]["model"] as? String, "Fable")
        XCTAssertEqual(limits[1]["id"] as? String, "claude:weekly_scoped:Fable")
        XCTAssertEqual(report.exitStatus, 0)
    }

    func testFailedFetchKeepsTheCacheAndTheError() throws {
        let reading = CLI.Reading(source: .cache, at: now.addingTimeInterval(-3_600), limits: [limit("session", percent: 100, resetsIn: 600)], extraUsage: nil, footnote: nil)
        let outcome = CLI.Outcome(reading: reading, error: "Rate limited by the usage API — backing off.")
        let report = CLI.Report(providers: [.claude], outcomes: [.claude: outcome], now: now)
        let claude = try XCTUnwrap(try decode(report)["providers"] as? [String: [String: Any]])["claude"]!

        XCTAssertEqual(claude["source"] as? String, "cache")
        XCTAssertEqual(claude["error"] as? String, "Rate limited by the usage API — backing off.")
        XCTAssertEqual((claude["limits"] as? [[String: Any]])?.first?["exhausted"] as? Bool, true)
        XCTAssertEqual(report.exitStatus, 0, "a stale number is still a number")
        XCTAssertTrue(report.text().contains("! Rate limited"))
    }

    func testNoReadingAtAllIsAFailure() throws {
        let outcome = CLI.Outcome(reading: nil, error: "No Codex login found.")
        let report = CLI.Report(providers: [.claude, .codex], outcomes: [
            .claude: CLI.Outcome(reading: CLI.Reading(source: .live, at: now, limits: [limit("session", percent: 1, resetsIn: 60)], extraUsage: nil, footnote: nil)),
            .codex: outcome,
        ], now: now)
        let codex = try XCTUnwrap(try decode(report)["providers"] as? [String: [String: Any]])["codex"]!
        XCTAssertTrue(codex["source"] is NSNull)
        XCTAssertEqual((codex["limits"] as? [Any])?.count, 0)
        XCTAssertEqual(report.exitStatus, 1)
    }

    func testTextRendering() {
        let reading = CLI.Reading(
            source: .live, at: now,
            limits: [limit("session", percent: 46, resetsIn: 3_600 * 3 + 120), limit("weekly_all", percent: 2, resetsIn: 86_400 * 6)],
            extraUsage: ExtraUsage(isEnabled: true, utilization: nil, usedCredits: 12.5, monthlyLimit: 50, currency: "USD"),
            footnote: nil
        )
        let single = CLI.Report(providers: [.claude], outcomes: [.claude: CLI.Outcome(reading: reading)], now: now).text()
        XCTAssertTrue(single.contains("Session (5h)          46%  resets in 3h 2m"), single)
        XCTAssertTrue(single.contains("Extra usage: $12.50 of $50.00"), single)
        XCTAssertTrue(single.hasSuffix("Source: live, 0s ago"), single)
        XCTAssertFalse(single.contains("Claude\n"), "one provider gets no section header, like the dropdown")

        let both = CLI.Report(providers: [.claude, .codex], outcomes: [.claude: CLI.Outcome(reading: reading)], now: now).text()
        XCTAssertTrue(both.hasPrefix("Claude  (live, 0s ago)\n  Session"), both)
        XCTAssertTrue(both.hasSuffix("\nOpenAI"), both)
    }

    func testCompactAge() {
        XCTAssertEqual(CLI.Report.age(5), "5s")
        XCTAssertEqual(CLI.Report.age(59), "59s")
        XCTAssertEqual(CLI.Report.age(60), "1m")
        XCTAssertEqual(CLI.Report.age(3_599), "59m")
        XCTAssertEqual(CLI.Report.age(7_200), "2h")
        XCTAssertEqual(CLI.Report.age(172_800), "2d")
    }
}
