import AppKit

/// Turns a usage percentage into colour.
///
/// The scale is continuous rather than stepped, so a quota creeping up reads as a
/// gradual shift (calm green → amber → orange → red) instead of snapping between
/// three states. Saturation also climbs with the number: a barely-touched quota is a
/// muted grey-green that doesn't compete for attention in the menu bar, while a
/// nearly-spent one is fully saturated.
enum Grade {
    /// Stops along "fine → careful → nearly gone".
    ///
    /// Brightness is per-stop rather than global because hues do not carry equal
    /// weight against a background: yellow has to be pushed much darker than red
    /// before it is legible on white, and the reverse holds on black.
    private struct Stop {
        let percent: Double
        let hue: CGFloat
        let light: CGFloat  // brightness on a light menu bar
        let dark: CGFloat   // brightness on a dark one
    }

    private static let stops = [
        Stop(percent: 0,   hue: 0.35, light: 0.54, dark: 0.90),  // green
        Stop(percent: 55,  hue: 0.14, light: 0.46, dark: 0.92),  // amber
        Stop(percent: 80,  hue: 0.07, light: 0.62, dark: 1.00),  // orange
        Stop(percent: 100, hue: 0.00, light: 0.74, dark: 1.00),  // red
    ]

    static func color(percent: Int, severity: Gauge.Severity, alpha: CGFloat = 1) -> NSColor {
        // The server gets the last word: if it says critical, show red regardless.
        let p = severity == .critical ? 100.0 : Double(min(max(percent, 0), 100))

        let upper = stops.firstIndex { p <= $0.percent } ?? stops.count - 1
        let lower = max(upper - 1, 0)
        let a = stops[lower], b = stops[upper]
        let t = a.percent == b.percent ? 0 : (p - a.percent) / (b.percent - a.percent)

        let hue = lerp(a.hue, b.hue, t)
        let light = lerp(a.light, b.light, t)
        let dark = lerp(a.dark, b.dark, t)
        // Barely-touched quotas stay muted so they don't compete for attention.
        let intensity = lerp(CGFloat(0.55), CGFloat(1.0), min(1, p / 70))

        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(
                hue: hue,
                saturation: (isDark ? 0.76 : 0.98) * intensity,
                brightness: isDark ? dark : light,
                alpha: alpha
            )
        }
    }

    /// A small rounded meter. Drawn lazily so it picks up the current appearance.
    static func bar(percent: Int, color: NSColor, width: CGFloat = 54, height: CGFloat = 6) -> NSImage {
        let fraction = CGFloat(min(max(percent, 0), 100)) / 100

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let radius = rect.height / 2

            NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

            guard fraction > 0 else { return true }
            // Keep a sliver visible for small values so 2% never looks like 0%.
            let filled = max(rect.width * fraction, rect.height)
            color.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: filled, height: rect.height),
                xRadius: radius,
                yRadius: radius
            ).fill()
            return true
        }
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(min(max(t, 0), 1))
    }
}
