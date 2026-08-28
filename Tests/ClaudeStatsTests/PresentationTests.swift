import XCTest
@testable import ClaudeStats

final class PresentationTests: XCTestCase {
    private func gauge(_ kind: String, _ percent: Double, provider: Provider = .claude, resetsAt: Date? = nil) -> Gauge {
        Gauge(
            limit: Limit(kind: kind, group: nil, percent: percent, severity: nil, resetsAt: resetsAt, scope: nil, isActive: nil),
            provider: provider
        )
    }

    private func title(_ groups: [Presentation.BarGroup], paused: Bool = false) -> String {
        Presentation.statusTitle(groups: groups, isPaused: paused).string
    }

    func testNothingYetShowsPlaceholder() {
        XCTAssertEqual(title([.init(provider: .claude, gauges: [], hasError: false)]), "CC …")
        XCTAssertEqual(title([.init(provider: .claude, gauges: [], hasError: true)]), "CC ⚠︎")
    }

    func testEverythingUncheckedShowsIdentityNotLoading() {
        XCTAssertEqual(title([.init(provider: .claude, gauges: [], hasError: false, hasData: true)]), "CC")
    }

    func testSingleProviderIsUntagged() {
        let s = title([.init(provider: .claude, gauges: [gauge("session", 49), gauge("weekly_all", 6)], hasError: false)])
        XCTAssertEqual(s, "S\u{2009}49% · W\u{2009}6%")
    }

    func testTwoProvidersAreTagged() {
        let s = title([
            .init(provider: .claude, gauges: [gauge("session", 5)], hasError: false),
            .init(provider: .codex, gauges: [gauge("weekly_all", 0, provider: .codex)], hasError: false),
        ])
        XCTAssertTrue(s.hasPrefix("CC S\u{2009}5%"), s)
        XCTAssertTrue(s.hasSuffix("GPT W\u{2009}0%"), s)
    }

    func testHiddenProviderStillFlagsItsError() {
        let s = title([
            .init(provider: .claude, gauges: [gauge("session", 5)], hasError: false),
            .init(provider: .codex, gauges: [], hasError: true, hasData: true),
        ])
        XCTAssertEqual(s, "S\u{2009}5% GPT⚠︎")
    }

    func testVisibleProviderErrorIsInline() {
        XCTAssertEqual(title([.init(provider: .claude, gauges: [gauge("session", 5)], hasError: true)]), "S\u{2009}5% ⚠︎")
    }

    func testSpentQuotaShowsTheWait() {
        let s = title([.init(provider: .claude, gauges: [gauge("session", 100, resetsAt: Date().addingTimeInterval(2 * 3600 + 5 * 60))], hasError: false)])
        XCTAssertTrue(s.hasPrefix("S\u{2009}2h"), s)
        XCTAssertFalse(s.contains("%"))
    }

    func testPausedPrefix() {
        XCTAssertTrue(title([.init(provider: .claude, gauges: [gauge("session", 5)], hasError: false)], paused: true).hasPrefix("⏸ "))
    }

    func testStaleReadingCarriesItsAge() {
        let s = title([.init(
            provider: .claude, gauges: [gauge("session", 5)], hasError: false,
            staleness: .stale, lastUpdated: Date().addingTimeInterval(-3 * 3600)
        )])
        XCTAssertTrue(s.hasSuffix("3h"), s)
    }
}
