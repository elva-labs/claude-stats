import AppKit

/// Everything that decides how a `Gauge` looks, kept out of the app delegate so it
/// can be rendered and inspected without launching the menu bar item.
enum Presentation {
    static let meterWidth: CGFloat = 54

    private static let markerFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let unitFont = NSFont.systemFont(ofSize: 9, weight: .medium)

    // MARK: Menu bar

    /// One provider's contribution to the menu bar: its visible gauges plus the
    /// trust signals (staleness, error) that are tracked per provider, since one
    /// endpoint failing says nothing about the other.
    struct BarGroup {
        let provider: Provider
        let gauges: [Gauge]      // the ones chosen for the bar; the dropdown shows all
        let hasError: Bool
        /// Whether the provider has any reading at all, shown in the bar or not —
        /// what separates "everything unchecked" from "nothing fetched yet".
        let hasData: Bool
        let staleness: Staleness
        let lastUpdated: Date?

        init(
            provider: Provider,
            gauges: [Gauge],
            hasError: Bool,
            hasData: Bool = false,
            staleness: Staleness = .fresh,
            lastUpdated: Date? = nil
        ) {
            self.provider = provider
            self.gauges = gauges
            self.hasError = hasError
            self.hasData = hasData || !gauges.isEmpty
            self.staleness = staleness
            self.lastUpdated = lastUpdated
        }
    }

    static func statusTitle(groups: [BarGroup], isPaused: Bool = false) -> NSAttributedString {
        let populated = groups.filter { !$0.gauges.isEmpty }
        // A provider kept out of the bar can still be failing — that gets a compact
        // tagged flag rather than silence, because "quietly hidden" and "quietly
        // broken" must not look the same.
        let errorOnly = groups.filter { $0.gauges.isEmpty && $0.hasError }

        func errorFlags(into title: NSMutableAttributedString) {
            for group in errorOnly {
                title.append(NSAttributedString(
                    string: " \(group.provider.barTag)",
                    attributes: [
                        .font: markerFont,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .baselineOffset: 0.5,
                    ]
                ))
                title.append(NSAttributedString(
                    string: "⚠︎",
                    attributes: [.font: markerFont, .foregroundColor: NSColor.systemRed]
                ))
            }
        }

        guard !populated.isEmpty else {
            // Data exists but the user unchecked every gauge: a bare identity, not
            // the loading ellipsis, which would claim something is still coming.
            if groups.contains(where: \.hasData) {
                let title = NSMutableAttributedString(
                    string: "CC",
                    attributes: [.font: numberFont, .foregroundColor: NSColor.secondaryLabelColor]
                )
                errorFlags(into: title)
                return title
            }
            let hasError = groups.contains(where: \.hasError)
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

        // Both providers have a session and a weekly quota, so once two groups are
        // visible the letters alone stop identifying anything — each group then
        // carries its provider tag. A single group keeps the original untagged look.
        let needsTags = populated.count > 1

        for (groupIndex, group) in populated.enumerated() {
            // Paused means "deliberately not updating"; stale means "couldn't
            // update". Both stop short of hiding the numbers, but they read
            // differently: paused is flat grey, stale keeps the grade and recedes.
            let fade = isPaused ? 1 : group.staleness.opacity
            func tint(_ live: NSColor) -> NSColor {
                let base = isPaused ? NSColor.tertiaryLabelColor : live
                return fade < 1 ? base.withAlphaComponent(fade) : base
            }

            if groupIndex > 0 {
                title.append(NSAttributedString(
                    string: "   ",
                    attributes: [.font: markerFont]
                ))
            }
            if needsTags {
                title.append(NSAttributedString(
                    string: "\(group.provider.barTag) ",
                    attributes: [
                        .font: markerFont,
                        .foregroundColor: tint(.tertiaryLabelColor),
                        .baselineOffset: 0.5,
                    ]
                ))
            }

            for (index, gauge) in group.gauges.enumerated() {
                if index > 0 {
                    title.append(NSAttributedString(
                        string: " · ",
                        attributes: [.font: markerFont, .foregroundColor: NSColor.tertiaryLabelColor]
                    ))
                }

                // The marker recedes and the number leads: the letter says *which*
                // quota, the colour and weight of the number say how much is gone.
                title.append(NSAttributedString(
                    string: gauge.shortLabel,
                    attributes: [
                        .font: markerFont,
                        .foregroundColor: tint(.secondaryLabelColor),
                        .baselineOffset: 0.5,
                    ]
                ))
                // Once a quota is spent, "100%" tells you nothing you can act on —
                // the only useful number left is how long until it comes back.
                if gauge.isExhausted, let eta = gauge.eta() {
                    title.append(NSAttributedString(
                        string: "\u{2009}\(eta)",
                        attributes: [.font: numberFont, .foregroundColor: tint(gauge.color(alpha: fade))]
                    ))
                } else {
                    title.append(NSAttributedString(
                        string: "\u{2009}\(gauge.percent)",
                        attributes: [.font: numberFont, .foregroundColor: tint(gauge.color(alpha: fade))]
                    ))
                    title.append(NSAttributedString(
                        string: "%",
                        attributes: [
                            .font: unitFont,
                            .foregroundColor: tint(Grade.color(percent: gauge.percent, severity: gauge.severity, alpha: 0.6 * fade)),
                            .baselineOffset: 0.5,
                        ]
                    ))
                }
            }

            if group.staleness.warrantsAgeLabel, let lastUpdated = group.lastUpdated, !isPaused {
                title.append(NSAttributedString(
                    string: " \u{2009}\(Staleness.compactAge(since: lastUpdated))",
                    attributes: [
                        .font: markerFont,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .baselineOffset: 0.5,
                    ]
                ))
            }

            // A failing provider is worth flagging, but not worth hiding numbers for.
            if group.hasError {
                title.append(NSAttributedString(
                    string: " ⚠︎",
                    attributes: [.font: markerFont, .foregroundColor: NSColor.systemRed]
                ))
            }
        }
        errorFlags(into: title)
        return title
    }

    // MARK: Dropdown

    /// `S ⇥ Weekly · Fable ⇥ [meter] ⇥ 12% ⇥ [trend] ⇥ resets Tue 08:00`, on tab stops
    /// so the meters and percentages line up into columns however long the labels run.
    ///
    /// `trend` is the recorded history for this quota, and is simply left out when
    /// there is none yet — a fresh install shows the row it always showed.
    static func row(for gauge: Gauge, trend: [History.Sample] = []) -> NSAttributedString {
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

        let now = Date()
        if let spark = Sparkline.image(
            samples: trend,
            window: now.addingTimeInterval(-gauge.trendWindow)...now,
            color: gauge.color
        ) {
            let attachment = NSTextAttachment()
            attachment.image = spark
            // Sunk below the baseline so the trace sits centred against the text
            // rather than riding on top of it.
            attachment.bounds = CGRect(
                x: 0, y: -3, width: Sparkline.size.width, height: Sparkline.size.height
            )
            line.append(NSAttributedString(attachment: attachment))
        }
        line.append(NSAttributedString(string: "\t"))
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
            NSTextTab(textAlignment: .left, location: 284),   // trend
            NSTextTab(textAlignment: .left, location: 340),   // reset countdown
        ]
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }
}
