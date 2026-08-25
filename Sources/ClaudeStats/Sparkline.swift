import AppKit

/// The shape of a quota over its own window, drawn small enough to sit inside a menu
/// row next to the meter.
///
/// The meter answers "how much is left". This answers the question the meter can't:
/// whether the number got there over the whole window or in the last twenty minutes.
enum Sparkline {
    static let size = NSSize(width: 46, height: 12)

    /// Fixed 0–100 rather than scaled to the data. A weekly quota at 6% *should* read
    /// as a flat sliver along the bottom; auto-scaling would blow that up into a
    /// dramatic climb and make two rows with very different headroom look alike.
    private static let ceiling: Double = 100

    /// Renders the samples across `window`, or nil when there is nothing to draw yet.
    ///
    /// Time is the x axis, not sample index: polls slow down when nothing is moving
    /// and stop entirely while the display sleeps, so evenly spacing them would
    /// stretch a quiet night into the same width as a busy hour.
    static func image(
        samples: [History.Sample],
        window: ClosedRange<Date>,
        color: NSColor,
        size: NSSize = Sparkline.size
    ) -> NSImage? {
        guard !samples.isEmpty else { return nil }

        let start = window.lowerBound.timeIntervalSince1970
        let span = window.upperBound.timeIntervalSince1970 - start
        guard span > 0 else { return nil }

        // A break in the line is how a gap in the record reads. Proportional to the
        // window so an overnight sleep breaks a 5-hour trace but barely registers in
        // a weekly one, where it is a normal part of the shape.
        let gapLimit = span / 8

        let points: [(x: Double, y: Double, at: TimeInterval)] = samples.map { sample in
            let t = sample.at.timeIntervalSince1970
            let fraction = min(max((t - start) / span, 0), 1)
            let value = min(max(Double(sample.percent), 0), ceiling) / ceiling
            return (fraction, value, t)
        }

        return NSImage(size: size, flipped: false) { rect in
            // Room for the line's own width, so 0%, 100% and the head dot at "now"
            // all sit inside the image instead of being clipped by it.
            let plot = rect.insetBy(dx: 1.5, dy: 1.5)

            func place(_ p: (x: Double, y: Double, at: TimeInterval)) -> NSPoint {
                NSPoint(
                    x: plot.minX + CGFloat(p.x) * plot.width,
                    y: plot.minY + CGFloat(p.y) * plot.height
                )
            }

            // The floor, so a quota sitting near zero still reads as a line along the
            // bottom of *something* rather than a stray mark in empty space.
            NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setStroke()
            let base = NSBezierPath()
            base.lineWidth = 0.5
            base.move(to: NSPoint(x: rect.minX, y: plot.minY))
            base.line(to: NSPoint(x: rect.maxX, y: plot.minY))
            base.stroke()

            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.3
            path.lineJoinStyle = .round
            path.lineCapStyle = .round

            var previous: TimeInterval?
            for point in points {
                let position = place(point)
                if let previous, point.at - previous <= gapLimit {
                    path.line(to: position)
                } else {
                    path.move(to: position)
                }
                previous = point.at
            }
            path.stroke()

            // The head of the trace, so a single reading is still visible and the
            // eye lands on "now" rather than the middle of the line.
            if let last = points.last {
                let head = place(last)
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: head.x - 1.4, y: head.y - 1.4, width: 2.8, height: 2.8)).fill()
            }
            return true
        }
    }
}
