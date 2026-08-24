import AppKit

/// The full-size view of one quota's history.
///
/// The row sparkline is a preview: 43 points wide, no axes, no numbers. This is the
/// same data with room to actually read it — gridlines, a time axis, where each
/// window began, and the two figures the shape implies but can't state, which are how
/// fast the quota is going and when it runs out at that rate.
final class ChartView: NSView {
    var gauge: Gauge?
    var samples: [History.Sample] = []

    /// Breaks in the trace mean the app wasn't watching — asleep, locked or paused.
    /// The busiest cadence is 5 minutes and the idlest 10, so anything past 20 is a
    /// genuine gap rather than the poll interval stretching.
    private let gapLimit: TimeInterval = 20 * 60

    private let padding = NSEdgeInsets(top: 62, left: 46, bottom: 32, right: 20)
    private let gridValues = [0, 25, 50, 75, 100]

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        guard let gauge else { return }
        drawHeader(gauge)

        let plot = NSRect(
            x: padding.left,
            y: padding.bottom,
            width: bounds.width - padding.left - padding.right,
            height: bounds.height - padding.top - padding.bottom
        )
        guard plot.width > 40, plot.height > 20 else { return }

        let now = Date()
        let start = now.addingTimeInterval(-gauge.trendWindow)
        drawGrid(in: plot)
        drawTimeAxis(in: plot, from: start, to: now)

        guard samples.count > 1 else {
            drawPlaceholder(in: plot)
            return
        }
        drawResetMarks(in: plot, from: start, to: now)
        drawTrace(in: plot, from: start, to: now, color: gauge.color)
    }

    // MARK: Header

    private func drawHeader(_ gauge: Gauge) {
        let top = bounds.height

        draw(gauge.longLabel, at: NSPoint(x: padding.left, y: top - 26),
             font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)

        let reading = gauge.isExhausted
            ? "at limit"
            : "\(gauge.percent)%"
        draw(reading, at: NSPoint(x: padding.left, y: top - 52),
             font: .monospacedDigitSystemFont(ofSize: 22, weight: .semibold), color: gauge.color)

        // Right-hand side: the rate, and what it implies. Both are derived from the
        // samples on screen, so they can't disagree with the line above them.
        var notes: [String] = []
        if let rate = burnRate() { notes.append(rate.label) }
        if let outlook = outlook(gauge) { notes.append(outlook) }
        guard !notes.isEmpty else { return }

        let text = notes.joined(separator: "  ·  ")
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        draw(text, at: NSPoint(x: bounds.width - padding.right - width, y: top - 30),
             font: font, color: .secondaryLabelColor)
    }

    /// Change over the most recent stretch of the window, in the unit that suits it:
    /// percent per hour reads as noise on a quota that runs for a week.
    private func burnRate() -> (perSecond: Double, label: String)? {
        guard let gauge else { return nil }
        let hourly = gauge.trendWindow <= 6 * 3_600
        let lookback: TimeInterval = hourly ? 3_600 : 86_400
        let cutoff = Date().addingTimeInterval(-lookback)

        let recent = samples.filter { $0.at >= cutoff }
        guard let first = recent.first, let last = recent.last else { return nil }
        let seconds = last.at.timeIntervalSince(first.at)
        guard seconds > 300 else { return nil }

        // A reset inside the lookback makes the arithmetic meaningless: the drop to
        // zero would read as a large negative rate.
        guard first.resetsAt == last.resetsAt else { return nil }

        let delta = Double(last.percent - first.percent)
        let perSecond = delta / seconds
        let shown = perSecond * (hourly ? 3_600 : 86_400)
        guard abs(shown) >= 0.5 else { return (perSecond, "steady") }
        let sign = shown > 0 ? "+" : "−"
        return (perSecond, "\(sign)\(Int(abs(shown).rounded()))% / \(hourly ? "hr" : "day")")
    }

    /// When the quota runs out at the current rate, but only when that lands before
    /// the reset — otherwise the window turns over first and the figure is noise.
    private func outlook(_ gauge: Gauge) -> String? {
        if gauge.isExhausted { return gauge.eta().map { "back in \($0)" } }
        guard let rate = burnRate(), rate.perSecond > 0 else {
            return gauge.resetDescription()
        }
        let remaining = Double(100 - gauge.percent) / rate.perSecond
        let spent = Date().addingTimeInterval(remaining)
        guard let resetsAt = gauge.resetsAt, spent < resetsAt else {
            return gauge.resetDescription()
        }
        let f = DateFormatter()
        f.dateFormat = remaining < 86_400 ? "HH:mm" : "EEE HH:mm"
        return "spent by \(f.string(from: spent)) at this rate"
    }

    // MARK: Axes

    private func drawGrid(in plot: NSRect) {
        for value in gridValues {
            let y = plot.minY + plot.height * CGFloat(value) / 100
            let line = NSBezierPath()
            line.lineWidth = 0.5
            // The floor carries a little more weight than the rest, so the trace has
            // something to sit on rather than floating between lines.
            (value == 0 ? NSColor.separatorColor : NSColor.separatorColor.withAlphaComponent(0.5)).setStroke()
            line.move(to: NSPoint(x: plot.minX, y: y.rounded() + 0.25))
            line.line(to: NSPoint(x: plot.maxX, y: y.rounded() + 0.25))
            line.stroke()

            let label = "\(value)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            draw(label, at: NSPoint(x: plot.minX - 10 - width, y: y - 5),
                 font: font, color: .tertiaryLabelColor)
        }
    }

    private func drawTimeAxis(in plot: NSRect, from start: Date, to end: Date) {
        let span = end.timeIntervalSince(start)
        let steps: [TimeInterval] = [900, 1_800, 3_600, 2 * 3_600, 3 * 3_600, 6 * 3_600,
                                     12 * 3_600, 86_400, 2 * 86_400]
        let step = steps.first { span / $0 <= 8 } ?? 7 * 86_400

        let f = DateFormatter()
        f.dateFormat = step < 86_400 ? "HH:mm" : "EEE"
        let font = NSFont.systemFont(ofSize: 10, weight: .regular)

        // Ticks land on wall-clock boundaries rather than on "now minus a multiple",
        // so they read as times of day instead of arbitrary offsets.
        let offset = TimeInterval(TimeZone.current.secondsFromGMT())
        var t = (((start.timeIntervalSince1970 + offset) / step).rounded(.up) * step) - offset

        while t <= end.timeIntervalSince1970 {
            let date = Date(timeIntervalSince1970: t)
            let x = plot.minX + plot.width * CGFloat(date.timeIntervalSince(start) / span)
            defer { t += step }

            let tick = NSBezierPath()
            tick.lineWidth = 0.5
            NSColor.separatorColor.setStroke()
            tick.move(to: NSPoint(x: x.rounded() + 0.25, y: plot.minY))
            tick.line(to: NSPoint(x: x.rounded() + 0.25, y: plot.minY - 4))
            tick.stroke()

            let label = f.string(from: date)
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            draw(label, at: NSPoint(x: x - width / 2, y: plot.minY - 19),
                 font: font, color: .tertiaryLabelColor)
        }
    }

    // MARK: Trace

    /// Where one window ended and the next began, taken from the samples themselves
    /// rather than guessed from a window length: a reset is exactly the moment the
    /// reported reset time changes.
    private func drawResetMarks(in plot: NSRect, from start: Date, to end: Date) {
        let span = end.timeIntervalSince(start)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.5).setStroke()

        for (previous, sample) in zip(samples, samples.dropFirst())
        where previous.resetsAt != sample.resetsAt {
            let x = plot.minX + plot.width * CGFloat(sample.at.timeIntervalSince(start) / span)
            let line = NSBezierPath()
            line.lineWidth = 1
            line.setLineDash([2, 3], count: 2, phase: 0)
            line.move(to: NSPoint(x: x.rounded() + 0.5, y: plot.minY))
            line.line(to: NSPoint(x: x.rounded() + 0.5, y: plot.maxY))
            line.stroke()
        }
    }

    private func drawTrace(in plot: NSRect, from start: Date, to end: Date, color: NSColor) {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return }

        func place(_ sample: History.Sample) -> NSPoint {
            let fraction = min(max(sample.at.timeIntervalSince(start) / span, 0), 1)
            let value = min(max(Double(sample.percent), 0), 100) / 100
            return NSPoint(
                x: plot.minX + plot.width * CGFloat(fraction),
                y: plot.minY + plot.height * CGFloat(value)
            )
        }

        // Each unbroken run is drawn on its own so a gap stays a gap: bridging it
        // would draw a straight line through hours nobody measured.
        //
        // A reset breaks the run too. Joining the old window's last reading to the
        // new window's first would draw a vertical cliff between two quantities that
        // aren't the same series, and the dashed marker already says what happened.
        var runs: [[History.Sample]] = []
        var run: [History.Sample] = []
        for sample in samples {
            if let last = run.last,
               sample.at.timeIntervalSince(last.at) > gapLimit || sample.resetsAt != last.resetsAt {
                runs.append(run)
                run = []
            }
            run.append(sample)
        }
        runs.append(run)

        for run in runs where !run.isEmpty {
            let points = run.map(place)

            if points.count > 1 {
                let area = NSBezierPath()
                area.move(to: NSPoint(x: points[0].x, y: plot.minY))
                for point in points { area.line(to: point) }
                area.line(to: NSPoint(x: points[points.count - 1].x, y: plot.minY))
                area.close()
                color.withAlphaComponent(0.12).setFill()
                area.fill()
            }

            let line = NSBezierPath()
            line.lineWidth = 1.6
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            line.move(to: points[0])
            for point in points.dropFirst() { line.line(to: point) }
            color.setStroke()
            if points.count > 1 { line.stroke() }
        }

        if let head = samples.last.map(place) {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: head.x - 3, y: head.y - 3, width: 6, height: 6)).fill()
        }
    }

    private func drawPlaceholder(in plot: NSRect) {
        let text = "No history yet. It fills in as the app polls."
        let font = NSFont.systemFont(ofSize: 12)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let origin = NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2)

        // Clear the gridline behind it, which would otherwise strike the text through.
        NSColor.controlBackgroundColor.setFill()
        NSRect(origin: origin, size: size).insetBy(dx: -8, dy: -3).fill()
        draw(text, at: origin, font: font, color: .tertiaryLabelColor)
    }

    private func draw(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}

/// Holds the one chart window. Clicking a different row retargets it rather than
/// opening a second one — a window per quota would be three windows to close.
@MainActor
final class ChartWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let view = ChartView()

    /// Which quota is on screen, so live updates can keep feeding the right one.
    private(set) var shownKey: String?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(gauge: Gauge, samples: [History.Sample]) {
        // Retarget before updating: `update` ignores quotas that aren't the one on
        // screen, so setting the new key second would leave the old one drawn.
        shownKey = gauge.seriesKey
        update(gauge: gauge, samples: samples)

        let window = window ?? makeWindow()
        window.title = gauge.longLabel
        window.makeKeyAndOrderFront(nil)
        // An accessory app has no Dock icon to click, so nothing brings the window
        // forward on its own.
        NSApp.activate()
    }

    /// Refresh in place, ignoring quotas that aren't the one being shown.
    func update(gauge: Gauge, samples: [History.Sample]) {
        guard shownKey == nil || shownKey == gauge.seriesKey else { return }
        view.gauge = gauge
        view.samples = samples
        view.needsDisplay = true
        window?.title = gauge.longLabel
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Without this the window is deallocated on close and reopening it crashes.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 420, height: 240)
        view.autoresizingMask = [.width, .height]
        view.frame = window.contentLayoutRect
        window.contentView = view
        window.setFrameAutosaveName("ClaudeStatsChart")
        if window.frame.origin == .zero { window.center() }
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        shownKey = nil
    }
}
