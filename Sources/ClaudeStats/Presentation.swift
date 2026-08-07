import AppKit

/// Everything that decides how a `Gauge` looks, kept out of the app delegate so it
/// can be rendered and inspected without launching the menu bar item.
enum Presentation {
    static let meterWidth: CGFloat = 54

    private static let markerFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let unitFont = NSFont.systemFont(ofSize: 9, weight: .medium)

    // MARK: Menu bar

    static func statusTitle(gauges: [Gauge], hasError: Bool, isPaused: Bool = false) -> NSAttributedString {
        guard !gauges.isEmpty else {
            return NSAttributedString(
                string: hasError ? "CC ⚠︎" : "CC …",
                attributes: [
                    .font: numberFont,
                    .foregroundColor: hasError ? NSColor.systemRed : NSColor.secondaryLabelColor,
                ]
            )
        }

        let title = NSMutableAttributedString()

        // While paused the numbers are last-known rather than current, so the whole
        // readout goes grey — the grade would otherwise imply it was still live.
        if isPaused {
            title.append(NSAttributedString(
                string: "⏸ ",
                attributes: [.font: markerFont, .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }
        func tint(_ live: NSColor) -> NSColor { isPaused ? .tertiaryLabelColor : live }

        for (index, gauge) in gauges.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(
                    string: " · ",
                    attributes: [.font: markerFont, .foregroundColor: NSColor.tertiaryLabelColor]
                ))
            }

            // The marker recedes and the number leads: the letter says *which* quota,
            // the colour and weight of the number say how much of it is gone.
            title.append(NSAttributedString(
                string: gauge.shortLabel,
                attributes: [
                    .font: markerFont,
                    .foregroundColor: tint(.secondaryLabelColor),
                    .baselineOffset: 0.5,
                ]
            ))
            // Once a quota is spent, "100%" tells you nothing you can act on — the
            // only useful number left is how long until it comes back.
            if gauge.isExhausted, let eta = gauge.eta() {
                title.append(NSAttributedString(
                    string: "\u{2009}\(eta)",
                    attributes: [.font: numberFont, .foregroundColor: tint(gauge.color)]
                ))
            } else {
                title.append(NSAttributedString(
                    string: "\u{2009}\(gauge.percent)",
                    attributes: [.font: numberFont, .foregroundColor: tint(gauge.color)]
                ))
                title.append(NSAttributedString(
                    string: "%",
                    attributes: [
                        .font: unitFont,
                        .foregroundColor: tint(Grade.color(percent: gauge.percent, severity: gauge.severity, alpha: 0.6)),
                        .baselineOffset: 0.5,
                    ]
                ))
            }
        }

        // A stale reading is worth flagging, but not worth hiding the numbers for.
        if hasError {
            title.append(NSAttributedString(
                string: " ⚠︎",
                attributes: [.font: markerFont, .foregroundColor: NSColor.systemRed]
            ))
        }
        return title
    }

    // MARK: Dropdown

    /// `S ⇥ Weekly · Fable ⇥ [meter] ⇥ 12% ⇥ resets Tue 08:00`, on tab stops so the
    /// meters and percentages line up into columns however long the labels run.
    static func row(for gauge: Gauge) -> NSAttributedString {
        let line = NSMutableAttributedString()

        line.append(NSAttributedString(
            string: gauge.shortLabel + "\t",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        ))
        line.append(NSAttributedString(
            string: gauge.longLabel + "\t",
            attributes: [
                .font: NSFont.menuFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
        ))

        let meter = NSTextAttachment()
        meter.image = Grade.bar(percent: gauge.percent, color: gauge.color)
        meter.bounds = CGRect(x: 0, y: 0, width: meterWidth, height: 6)
        line.append(NSAttributedString(attachment: meter))

        line.append(NSAttributedString(
            string: "\t\(gauge.percent)%\t",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: gauge.color,
            ]
        ))
        // The dropdown has room to keep the percentage *and* spell out the wait.
        let trailing = gauge.isExhausted
            ? "at limit · back in \(gauge.eta() ?? "—")"
            : (gauge.resetDescription() ?? "")
        line.append(NSAttributedString(
            string: trailing,
            attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: gauge.isExhausted ? gauge.color : NSColor.secondaryLabelColor,
            ]
        ))

        let style = NSMutableParagraphStyle()
        style.tabStops = [
            NSTextTab(textAlignment: .left, location: 18),    // label
            NSTextTab(textAlignment: .left, location: 172),   // meter
            NSTextTab(textAlignment: .right, location: 272),  // percentage
            NSTextTab(textAlignment: .left, location: 284),   // reset countdown
        ]
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }
}
