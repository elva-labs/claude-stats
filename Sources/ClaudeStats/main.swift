import AppKit
import ServiceManagement

let refreshInterval: TimeInterval = 60

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

        guard !gauges.isEmpty else { return }
        repaint()
        guard !isPaused else { return }

        let now = Date()
        if gauges.contains(where: { $0.resetsAt.map { $0 <= now } ?? false }) {
            refresh()
        }
    }

    // MARK: Data

    private func refresh() {
        guard !isFetching, !isPaused else { return }
        isFetching = true

        Task {
            defer { isFetching = false }
            do {
                let result = try await UsageAPI.fetch()
                gauges = result.usage.limits
                    .map(Gauge.init(limit:))
                    .sorted { ($0.sortKey, $0.longLabel) < ($1.sortKey, $1.longLabel) }
                extraUsage = result.usage.extraUsage
                renewedLogin = result.renewedLogin
                lastError = nil
                lastUpdated = Date()
            } catch {
                lastError = error.localizedDescription
            }
            repaint()
        }
    }

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
            isPaused: isPaused
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
            if ClaudeCLI.executable != nil {
                let signIn = NSMenuItem(title: "Sign In to Claude Code…", action: #selector(signIn), keyEquivalent: "")
                signIn.target = self
                menu.addItem(signIn)
            }
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
            menu.addItem(disabled(
                "Updated \(f.string(from: lastUpdated))\(note) · click a row to copy",
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

    @objc private func refreshNow() { refresh() }

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
