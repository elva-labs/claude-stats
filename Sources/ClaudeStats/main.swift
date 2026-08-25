import AppKit
import ServiceManagement

/// Cadence while the numbers are actually moving.
///
/// Deliberately slow, for two reasons. The endpoint throttles readily — 429s have
/// been observed both 57 seconds and 2 minutes after a success — and, more to the
/// point, opening the menu fetches on demand anyway. The background poll therefore
/// isn't what you see when you go looking; it only keeps the passive glance roughly
/// right, and roughly right within five minutes is plenty for that.
let baseInterval: TimeInterval = 300

/// Ceiling once nothing has changed for a while. Long idle stretches are the common
/// case, and polling through them is pure waste.
let maxInterval: TimeInterval = 600

/// Unchanged readings needed before the interval doubles again.
let unchangedPollsPerBackoff = 3

/// Floor between any two requests, whatever triggered them. The timer, a menu open
/// and a wake-from-sleep can otherwise land together and burst.
let minimumSpacing: TimeInterval = 60

/// A deliberate button press gets a shorter floor, but never bypasses a server
/// throttle — see `refresh(force:)`.
let manualSpacing: TimeInterval = 15

/// Everything one provider's endpoint has told us, plus how the conversation with
/// it is going. Kept per provider because the two endpoints fail independently —
/// Anthropic throttling us says nothing about OpenAI, and vice versa.
struct ProviderState {
    var gauges: [Gauge] = []
    var extraUsage: ExtraUsage?
    var footnote: String?
    var lastError: String?
    var lastUpdated: Date?
    var renewedLogin = false
    var needsInteractiveLogin = false
    var throttledUntil: Date?
    var backoffStep = 0
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    /// Claude always; Codex only when its CLI credentials exist on this machine,
    /// so people without Codex never see an OpenAI section erroring at them.
    /// Computed, not stored: a `codex login` or `codex logout` mid-run changes the
    /// answer, and freezing it at launch would show a section erroring forever
    /// (or never appearing) until the app is restarted.
    private var providers: [Provider] { [.claude] + (CodexAPI.isAvailable ? [.codex] : []) }
    private var states: [Provider: ProviderState] = [:]

    private var isFetching = false
    private var menuIsOpen = false
    private var lastAttempt: Date?
    private var unchangedPolls = 0
    private var lastSignature: String?
    private var displayAsleep = false
    private var screenLocked = false
    private let chart = ChartWindowController()

    private var allGauges: [Gauge] { providers.flatMap { states[$0]?.gauges ?? [] } }
    private func state(_ provider: Provider) -> ProviderState { states[provider] ?? ProviderState() }

    /// Nobody can see the menu bar right now, so nothing needs fetching for it.
    private var isIdle: Bool { displayAsleep || screenLocked }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CC …"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // One timer drives everything. It ticks faster than any poll interval so the
        // countdowns stay live, and decides on each tick whether a fetch is due —
        // which is what lets the poll interval vary without rescheduling anything.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
        timer?.tolerance = 5

        // Show the last known reading immediately. The first fetch may be seconds
        // away, or — if the network is down or the endpoint is throttling — never.
        for provider in providers {
            guard let snapshot = Store.load(provider) else { continue }
            var s = state(provider)
            s.gauges = Self.sorted(snapshot.limits, provider: provider)
            s.lastUpdated = snapshot.savedAt
            states[provider] = s
        }
        render()

        observeIdleState()
        refresh(force: true)
    }

    // MARK: Idle

    /// Polling while the display is asleep or the screen is locked spends requests
    /// nobody can see the result of — and overnight that is the majority of them.
    private func observeIdleState() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        func observe(_ center: NotificationCenter, _ name: NSNotification.Name, _ handler: @escaping () -> Void) {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated(handler)
            }
        }
        func observe(_ center: DistributedNotificationCenter, _ name: String, _ handler: @escaping () -> Void) {
            center.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated(handler)
            }
        }

        observe(workspace, NSWorkspace.screensDidSleepNotification) { self.displayAsleep = true }
        observe(workspace, NSWorkspace.willSleepNotification) { self.displayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { self.wake() }
        observe(workspace, NSWorkspace.didWakeNotification) { self.wake() }
        observe(distributed, "com.apple.screenIsLocked") { self.screenLocked = true }
        observe(distributed, "com.apple.screenIsUnlocked") { self.screenLocked = false; self.wake() }
    }

    /// Coming back to the machine is exactly when a current reading matters, so fetch
    /// straight away rather than waiting out the rest of the interval.
    private func wake() {
        displayAsleep = false
        repaint()
        refresh()
    }

    /// Repaint from what we already know, and go ask the server the moment a quota's
    /// reset time passes rather than waiting out the rest of the poll interval.
    private func tick() {
        // A pause that has run its course resumes itself.
        if let until = pausedUntil, until <= Date() {
            pausedUntil = nil
            repaint()
            refresh()
            return
        }

        if !allGauges.isEmpty { repaint() }
        guard !isPaused, !isIdle else { return }

        let now = Date()

        // A quota coming back is worth knowing about promptly, whatever the
        // cadence — but only for a provider that can actually be asked. A gauge
        // whose provider is throttled keeps its stale reset time for the whole
        // backoff, and letting it trip this fast path would hammer the *other*
        // provider once a minute for nothing.
        let askable = providers.filter { (state($0).throttledUntil ?? .distantPast) <= now }
        if askable.contains(where: { provider in
            state(provider).gauges.contains { $0.resetsAt.map { $0 <= now } ?? false }
        }) {
            refresh()
            return
        }

        if lastAttempt.map({ now.timeIntervalSince($0) >= currentInterval }) ?? true {
            refresh()
        }
    }

    // MARK: Cadence

    /// Doubles the gap after every few identical readings, capped, and snaps back to
    /// the busy cadence the moment a number moves. Long stretches of not using Claude
    /// are the normal case, and polling through them tells you nothing you don't
    /// already have on screen.
    private var currentInterval: TimeInterval {
        let doublings = unchangedPolls / unchangedPollsPerBackoff
        return min(baseInterval * pow(2, Double(doublings)), maxInterval)
    }

    /// What counts as "the same reading". Reset times are included so the start of a
    /// fresh window registers as a change even when the percentage lands identically.
    private static func signature(of gauges: [Gauge]) -> String {
        gauges.map { gauge in
            "\(gauge.id)\(gauge.percent)@\(gauge.resetsAt?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    // MARK: Data

    /// What one provider's poll produced, in the shape the display needs.
    private struct Fetched {
        let limits: [Limit]
        let extraUsage: ExtraUsage?
        let footnote: String?
        let renewedLogin: Bool
    }

    private func refresh(force: Bool = false) {
        guard !isFetching, !isPaused else { return }
        // The usage endpoints rate-limit, so a backoff is binding even on a manual
        // refresh — hammering one while throttled only extends the throttle. A
        // throttle on one provider never blocks the other.
        let now = Date()
        let due = providers.filter { (state($0).throttledUntil ?? .distantPast) <= now }
        guard !due.isEmpty else { return }

        // Spacing is measured from the last *attempt*, not the last success: a failed
        // request costs the endpoint just as much as one that worked.
        let spacing = force ? manualSpacing : minimumSpacing
        if let last = lastAttempt, now.timeIntervalSince(last) < spacing { return }

        lastAttempt = now
        isFetching = true

        Task {
            defer { isFetching = false }
            var anySucceeded = false
            await withTaskGroup(of: (Provider, Result<Fetched, Error>).self) { group in
                for provider in due {
                    group.addTask {
                        do {
                            switch provider {
                            case .claude:
                                let result = try await UsageAPI.fetch()
                                return (provider, .success(Fetched(
                                    limits: result.usage.limits,
                                    extraUsage: result.usage.extraUsage,
                                    footnote: nil,
                                    renewedLogin: result.renewedLogin
                                )))
                            case .codex:
                                let result = try await CodexAPI.fetch()
                                return (provider, .success(Fetched(
                                    limits: result.limits,
                                    extraUsage: nil,
                                    footnote: result.footnote,
                                    renewedLogin: result.renewedLogin
                                )))
                            }
                        } catch {
                            return (provider, .failure(error))
                        }
                    }
                }
                // Repaint as each provider lands rather than once at the end: a
                // stale Codex token can take ~90s of CLI renewals while Claude's
                // answer arrived in two, and fresh numbers shouldn't wait on the
                // straggler.
                for await (provider, outcome) in group {
                    anySucceeded = apply(outcome, to: provider) || anySucceeded
                    repaint()
                }
            }

            // The cadence backoff reads "unchanged" as "nothing is happening", which
            // only follows from a reading that actually arrived — a failed poll says
            // nothing about whether the numbers moved.
            if anySucceeded {
                let signature = Self.signature(of: allGauges)
                if signature == lastSignature {
                    unchangedPolls += 1
                } else {
                    unchangedPolls = 0
                    lastSignature = signature
                }
            }
        }
    }

    /// Returns whether this outcome was a successful reading.
    @discardableResult
    private func apply(_ outcome: Result<Fetched, Error>, to provider: Provider) -> Bool {
        var s = state(provider)
        switch outcome {
        case .success(let fetched):
            // Log transitions only — a line per successful poll would bury the
            // few events that actually explain a problem.
            if s.lastError != nil || s.throttledUntil != nil || s.lastUpdated == nil {
                Log.write("\(provider.rawValue) ok — \(fetched.limits.count) limits")
            }
            s.gauges = Self.sorted(fetched.limits, provider: provider)
            Store.save(limits: fetched.limits, for: provider)
            History.append(limits: fetched.limits, provider: provider)
            s.extraUsage = fetched.extraUsage
            s.footnote = fetched.footnote
            s.renewedLogin = fetched.renewedLogin
            s.lastError = nil
            s.needsInteractiveLogin = false
            s.throttledUntil = nil
            s.backoffStep = 0
            s.lastUpdated = Date()
            states[provider] = s
            return true
        case .failure(let error):
            switch Self.classify(error) {
            case .rateLimited(let retryAfter):
                // Exponential backoff, honouring `Retry-After` when the server sends
                // one. Being throttled is a normal state to sit in, not an error to
                // shout about, so the last known figures stay on screen while it
                // waits. The server has been seen sending `retry-after: 0`, so its
                // hint is a floor to respect, never a licence to retry immediately.
                s.backoffStep = min(s.backoffStep + 1, 5)
                let exponential = min(baseInterval * pow(2, Double(s.backoffStep)), 1800)
                let delay = max(retryAfter ?? 0, exponential)
                s.throttledUntil = Date().addingTimeInterval(delay)
                s.lastError = nil
                Log.write("\(provider.rawValue) throttled for \(Int(delay))s (step \(s.backoffStep))")
            case .auth:
                s.lastError = error.localizedDescription
                // Only an auth failure is something a human can fix by signing in;
                // offering it for a network blip or a rate limit just misleads.
                s.needsInteractiveLogin = true
            case .other:
                s.lastError = error.localizedDescription
                s.needsInteractiveLogin = false
            }
            states[provider] = s
            return false
        }
    }

    private enum FailureKind {
        case rateLimited(retryAfter: TimeInterval?)
        case auth
        case other
    }

    private static func classify(_ error: Error) -> FailureKind {
        switch error {
        case UsageAPI.APIError.rateLimited(let retryAfter),
             CodexAPI.APIError.rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case UsageAPI.APIError.unauthorized, CodexAPI.APIError.unauthorized,
             CodexAPI.APIError.notLoggedIn, Keychain.TokenError.notFound:
            // "Not logged in" belongs with "login expired": both are fixed by the
            // Sign In menu item, which only appears for auth-classified failures.
            return .auth
        default:
            return .other
        }
    }

    private static func sorted(_ limits: [Limit], provider: Provider) -> [Gauge] {
        limits.map { Gauge(limit: $0, provider: provider) }
            .sorted { ($0.sortKey, $0.longLabel) < ($1.sortKey, $1.longLabel) }
    }

    private func repaint() {
        render()
        if menuIsOpen, let menu = statusItem.menu { rebuild(menu) }
        // The chart outlives the menu that opened it, so it has to be fed separately.
        if chart.isVisible, let key = chart.shownKey,
           let gauge = allGauges.first(where: { $0.seriesKey == key }) {
            chart.update(gauge: gauge, samples: trend(for: gauge))
        }
    }

    // MARK: Pause

    private static let pauseKey = "pausedUntil"
    private static let pauseDuration: TimeInterval = 12 * 3600

    private var pausedUntil: Date? {
        get { UserDefaults.standard.object(forKey: Self.pauseKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.pauseKey) }
    }

    private var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }

    @objc private func togglePause() {
        if isPaused {
            pausedUntil = nil
            refresh()
        } else {
            pausedUntil = Date().addingTimeInterval(Self.pauseDuration)
        }
        repaint()
    }

    // MARK: Menu bar title

    private func render() {
        let groups = providers.map { provider -> Presentation.BarGroup in
            let s = state(provider)
            return Presentation.BarGroup(
                provider: provider,
                gauges: s.gauges.filter(BarSelection.shows),
                hasError: s.lastError != nil,
                hasData: !s.gauges.isEmpty,
                staleness: Staleness(lastUpdated: s.lastUpdated),
                lastUpdated: s.lastUpdated
            )
        }
        statusItem.button?.attributedTitle = Presentation.statusTitle(groups: groups, isPaused: isPaused)
    }

    // MARK: Dropdown

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuild(menu)
        refresh()  // lands while the menu is open; spacing keeps it from bursting
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        if isPaused, let until = pausedUntil {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            menu.addItem(disabled(
                "Paused · resumes \(f.string(from: until))",
                color: .secondaryLabelColor
            ))
            menu.addItem(.separator())
        }

        // One provider keeps the original flat list; two get labelled sections.
        let sectioned = providers.count > 1

        for (index, provider) in providers.enumerated() {
            let s = state(provider)

            if sectioned {
                if index > 0 { menu.addItem(.separator()) }
                menu.addItem(disabled(
                    provider.displayName.uppercased(),
                    color: .tertiaryLabelColor,
                    size: 10.5
                ))
            }

            if let error = s.lastError {
                menu.addItem(disabled(error, color: .systemRed))
                if s.needsInteractiveLogin, Self.canOpenLogin(provider) {
                    let title = provider == .claude ? "Sign In to Claude Code…" : "Sign In to Codex…"
                    let signIn = NSMenuItem(title: title, action: #selector(signIn(_:)), keyEquivalent: "")
                    signIn.target = self
                    signIn.representedObject = provider.rawValue
                    menu.addItem(signIn)
                }
            }

            if let until = s.throttledUntil, until > Date() {
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss"
                menu.addItem(disabled(
                    "Rate limited by the usage API · retrying \(f.string(from: until))",
                    color: .secondaryLabelColor
                ))
            }

            // A section that hasn't produced anything yet still deserves a body,
            // or the header floats over the next section's rows.
            if s.gauges.isEmpty, s.lastError == nil {
                menu.addItem(disabled("Waiting for first reading…", color: .tertiaryLabelColor))
            }

            for gauge in s.gauges {
                let title = Presentation.row(for: gauge, trend: trend(for: gauge))

                let item = NSMenuItem(title: "", action: #selector(openChart(_:)), keyEquivalent: "")
                item.target = self
                item.attributedTitle = title
                item.representedObject = gauge.seriesKey
                menu.addItem(item)

                // Same row, shown only while Option is held. An alternate has to
                // follow its primary directly and share its (empty) key equivalent.
                let copy = NSMenuItem(title: "", action: #selector(copyRow(_:)), keyEquivalent: "")
                copy.target = self
                copy.attributedTitle = title
                copy.isAlternate = true
                copy.keyEquivalentModifierMask = .option
                copy.representedObject = "\(gauge.longLabel): \(gauge.percent)%"
                    + (gauge.resetDescription().map { ", \($0)" } ?? "")
                menu.addItem(copy)
            }

            if let extra = s.extraUsage, extra.isEnabled == true {
                var text = "Extra usage"
                if let used = extra.usedCredits {
                    let symbol = extra.currency == "USD" ? "$" : ""
                    text += ": \(symbol)\(String(format: "%.2f", used))"
                    if let cap = extra.monthlyLimit {
                        text += " of \(symbol)\(String(format: "%.2f", cap))"
                    }
                } else if let pct = extra.utilization {
                    text += ": \(Int(pct.rounded()))%"
                }
                menu.addItem(disabled(text, color: .secondaryLabelColor))
            }

            if let footnote = s.footnote {
                menu.addItem(disabled(footnote, color: .secondaryLabelColor))
            }
        }

        menu.addItem(.separator())

        if !allGauges.isEmpty {
            let show = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for gauge in allGauges {
                let title = sectioned
                    ? "\(gauge.provider.displayName) · \(gauge.longLabel)"
                    : gauge.longLabel
                let item = NSMenuItem(title: title, action: #selector(toggleBarGauge(_:)), keyEquivalent: "")
                item.target = self
                item.state = BarSelection.shows(gauge) ? .on : .off
                item.representedObject = gauge.id
                submenu.addItem(item)
            }
            show.submenu = submenu
            menu.addItem(show)
        }

        // The *oldest* update across providers, so one healthy provider can't put
        // a fresh-looking timestamp over the other's hours-stale figures.
        if let lastUpdated = providers.compactMap({ state($0).lastUpdated }).min() {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            let note = providers.contains(where: { state($0).renewedLogin }) ? " · renewed login" : ""
            let cadence = " · every \(Int(currentInterval / 60))m"
            let staleness = Staleness(lastUpdated: lastUpdated)
            let age = staleness.warrantsAgeLabel
                ? " (\(Staleness.compactAge(since: lastUpdated)) ago)"
                : ""
            menu.addItem(disabled(
                "Updated \(f.string(from: lastUpdated))\(age)\(cadence)\(note) · click a row for its chart, ⌥click to copy",
                color: .tertiaryLabelColor,
                size: 11
            ))
        }

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isPaused
        menu.addItem(refreshItem)

        let pauseItem = NSMenuItem(
            title: isPaused ? "Resume Polling" : "Pause for 12 Hours",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Claude Stats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func disabled(_ text: String, color: NSColor, size: CGFloat = 12) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.menuFont(ofSize: size), .foregroundColor: color]
        )
        item.isEnabled = false
        return item
    }

    private static func canOpenLogin(_ provider: Provider) -> Bool {
        switch provider {
        case .claude: return ClaudeCLI.executable != nil
        case .codex: return CodexCLI.executable != nil
        }
    }

    // MARK: Actions

    @objc private func refreshNow() {
        let throttled = providers.allSatisfy { (state($0).throttledUntil ?? .distantPast) > Date() }
        refresh(force: !throttled)
    }

    private func trend(for gauge: Gauge) -> [History.Sample] {
        History.series(for: gauge.seriesKey, since: Date().addingTimeInterval(-gauge.trendWindow))
    }

    @objc private func openChart(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let gauge = allGauges.first(where: { $0.seriesKey == key }) else { return }
        chart.show(gauge: gauge, samples: trend(for: gauge))
    }

    @objc private func signIn(_ sender: NSMenuItem) {
        switch (sender.representedObject as? String).flatMap(Provider.init(rawValue:)) {
        case .claude: ClaudeCLI.openInteractiveLogin()
        case .codex: CodexCLI.openInteractiveLogin()
        case nil: break
        }
    }

    @objc private func toggleBarGauge(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let gauge = allGauges.first(where: { $0.id == id }) else { return }
        BarSelection.toggle(gauge)
        repaint()
    }

    @objc private func copyRow(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

nonisolated(unsafe) private var retainedDelegate: AnyObject?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
