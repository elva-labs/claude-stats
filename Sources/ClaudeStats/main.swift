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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private var gauges: [Gauge] = []
    private var extraUsage: ExtraUsage?
    private var lastError: String?
    private var lastUpdated: Date?
    private var renewedLogin = false
    private var needsInteractiveLogin = false
    private var throttledUntil: Date?
    private var backoffStep = 0
    private var isFetching = false
    private var menuIsOpen = false
    private var lastAttempt: Date?
    private var unchangedPolls = 0
    private var lastSignature: String?
    private var displayAsleep = false
    private var screenLocked = false

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
        if let snapshot = Store.load() {
            gauges = Self.sorted(snapshot.limits)
            lastUpdated = snapshot.savedAt
            render()
        }

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

        if !gauges.isEmpty { repaint() }
        guard !isPaused, !isIdle else { return }

        let now = Date()

        // A quota coming back is worth knowing about promptly, whatever the cadence.
        if gauges.contains(where: { $0.resetsAt.map { $0 <= now } ?? false }) {
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
            "\(gauge.shortLabel)\(gauge.percent)@\(gauge.resetsAt?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    // MARK: Data

    private func refresh(force: Bool = false) {
        guard !isFetching, !isPaused else { return }
        // The usage endpoint rate-limits, so a backoff is binding even on a manual
        // refresh — hammering it while throttled only extends the throttle.
        if let until = throttledUntil, until > Date() { return }

        // Spacing is measured from the last *attempt*, not the last success: a failed
        // request costs the endpoint just as much as one that worked.
        let spacing = force ? manualSpacing : minimumSpacing
        if let last = lastAttempt, Date().timeIntervalSince(last) < spacing { return }

        lastAttempt = Date()
        isFetching = true

        Task {
            defer { isFetching = false }
            do {
                let result = try await UsageAPI.fetch()
                // Log transitions only — a line per successful poll would bury the
                // few events that actually explain a problem.
                if lastError != nil || throttledUntil != nil || lastUpdated == nil {
                    Log.write("ok — \(result.usage.limits.count) limits")
                }
                gauges = Self.sorted(result.usage.limits)
                Store.save(limits: result.usage.limits)

                let signature = Self.signature(of: gauges)
                if signature == lastSignature {
                    unchangedPolls += 1
                } else {
                    unchangedPolls = 0
                    lastSignature = signature
                }
                extraUsage = result.usage.extraUsage
                renewedLogin = result.renewedLogin
                lastError = nil
                needsInteractiveLogin = false
                throttledUntil = nil
                backoffStep = 0
                lastUpdated = Date()
            } catch UsageAPI.APIError.rateLimited(let retryAfter) {
                applyBackoff(retryAfter: retryAfter)
            } catch {
                lastError = error.localizedDescription
                // Only an auth failure is something a human can fix by signing in;
                // offering it for a network blip or a rate limit just misleads.
                needsInteractiveLogin = error is UsageAPI.APIError
                    && (error as? UsageAPI.APIError).map { if case .unauthorized = $0 { true } else { false } } == true
            }
            repaint()
        }
    }

    /// Exponential backoff, honouring `Retry-After` when the server sends one.
    /// Being throttled is a normal state to sit in, not an error to shout about, so
    /// the last known figures stay on screen while it waits.
    private func applyBackoff(retryAfter: TimeInterval?) {
        backoffStep = min(backoffStep + 1, 5)
        // The server has been seen sending `retry-after: 0`, which would mean no
        // backoff at all — treat its hint as a floor to respect, never a licence to
        // retry immediately.
        let exponential = min(baseInterval * pow(2, Double(backoffStep)), 1800)
        let delay = max(retryAfter ?? 0, exponential)
        throttledUntil = Date().addingTimeInterval(delay)
        lastError = nil
        Log.write("throttled for \(Int(delay))s (step \(backoffStep))")
    }

    private static func sorted(_ limits: [Limit]) -> [Gauge] {
        limits.map(Gauge.init(limit:))
            .sorted { ($0.sortKey, $0.longLabel) < ($1.sortKey, $1.longLabel) }
    }

    private var staleness: Staleness { Staleness(lastUpdated: lastUpdated) }

    private func repaint() {
        render()
        if menuIsOpen, let menu = statusItem.menu { rebuild(menu) }
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
        statusItem.button?.attributedTitle = Presentation.statusTitle(
            gauges: gauges,
            hasError: lastError != nil,
            isPaused: isPaused,
            staleness: staleness,
            lastUpdated: lastUpdated
        )
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

        if let lastError {
            menu.addItem(disabled(lastError, color: .systemRed))
            if needsInteractiveLogin, ClaudeCLI.executable != nil {
                let signIn = NSMenuItem(title: "Sign In to Claude Code…", action: #selector(signIn), keyEquivalent: "")
                signIn.target = self
                menu.addItem(signIn)
            }
            menu.addItem(.separator())
        }

        if let until = throttledUntil, until > Date() {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            menu.addItem(disabled(
                "Rate limited by the usage API · retrying \(f.string(from: until))",
                color: .secondaryLabelColor
            ))
            menu.addItem(.separator())
        }

        if isPaused, let until = pausedUntil {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            menu.addItem(disabled(
                "Paused · resumes \(f.string(from: until))",
                color: .secondaryLabelColor
            ))
            menu.addItem(.separator())
        }

        for gauge in gauges {
            let item = NSMenuItem(title: "", action: #selector(copyRow(_:)), keyEquivalent: "")
            item.target = self
            item.attributedTitle = Presentation.row(for: gauge)
            item.representedObject = "\(gauge.longLabel): \(gauge.percent)%"
                + (gauge.resetDescription().map { ", \($0)" } ?? "")
            menu.addItem(item)
        }

        if let extra = extraUsage, extra.isEnabled == true {
            menu.addItem(.separator())
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

        menu.addItem(.separator())

        if let lastUpdated {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            let note = renewedLogin ? " · renewed login" : ""
            let cadence = " · every \(Int(currentInterval / 60))m"
            let age = staleness.warrantsAgeLabel
                ? " (\(Staleness.compactAge(since: lastUpdated)) ago)"
                : ""
            menu.addItem(disabled(
                "Updated \(f.string(from: lastUpdated))\(age)\(cadence)\(note) · click a row to copy",
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

    // MARK: Actions

    @objc private func refreshNow() { refresh(force: throttledUntil == nil) }

    @objc private func signIn() { ClaudeCLI.openInteractiveLogin() }

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
