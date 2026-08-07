import AppKit
import ServiceManagement

/// Quota percentages move slowly, and the endpoint throttles more readily than the
/// numbers change, so the background poll is deliberately unhurried. Opening the menu
/// fetches on demand anyway, which is when freshness actually matters.
let refreshInterval: TimeInterval = 120

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var displayTimer: Timer?

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

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CC …"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        timer?.tolerance = 10

        // A countdown that only moves when the network answers looks broken, so the
        // display re-renders from cached data on its own cadence.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
        displayTimer?.tolerance = 5

        // Show the last known reading immediately. The first fetch may be seconds
        // away, or — if the network is down or the endpoint is throttling — never.
        if let snapshot = Store.load() {
            gauges = Self.sorted(snapshot.limits)
            lastUpdated = snapshot.savedAt
            render()
        }

        refresh(force: true)
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

        guard !gauges.isEmpty else { return }
        repaint()
        guard !isPaused else { return }

        let now = Date()
        if gauges.contains(where: { $0.resetsAt.map { $0 <= now } ?? false }) {
            refresh()
        }
    }

    // MARK: Data

    private func refresh(force: Bool = false) {
        guard !isFetching, !isPaused else { return }
        // The usage endpoint rate-limits, so a backoff is binding even on a manual
        // refresh — hammering it while throttled only extends the throttle.
        if let until = throttledUntil, until > Date(), !force { return }
        if let last = lastUpdated, Date().timeIntervalSince(last) < 10, !force { return }

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
        let exponential = min(refreshInterval * pow(2, Double(backoffStep)), 1800)
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
        refresh()  // repaints the menu when it lands, even while open
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
            let age = staleness.warrantsAgeLabel
                ? " (\(Staleness.compactAge(since: lastUpdated)) ago)"
                : ""
            menu.addItem(disabled(
                "Updated \(f.string(from: lastUpdated))\(age)\(note) · click a row to copy",
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
