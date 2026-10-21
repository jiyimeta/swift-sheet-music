#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

// MARK: - Syllables either side of a barline

/// The last syllable of a bar and the first of the next, in the same voice, are a pair like any two in one bar, but
/// no bar's own spacing sees both: `aggregatedTickWeights` walks one measure. So the pair across a barline gets its
/// room here, from the two bars' aggregates, and only where the second bar follows the first on the same line.
///
/// MuseScore spaces a line segment by segment against every earlier segment on it, across barlines
/// (`HorizontalSpacing::spaceAgainstPreviousSegments`). A syllable may run across a barline (`doComputeKerningType`:
/// barline → lyrics is `ALLOW_COLLISION`) but not into the next syllable of its verse (`computeLyricsKerningType`:
/// `NON_KERNING`). The room a collision asks for is shared out over the gaps after the earlier syllable's segment, so
/// it lands in the first bar, before the barline; and justification treats it as the pre-tension of those gaps'
/// springs (`justifySystem`), which is what a floor is here (`TickAggregate.contentWidth(atStretch:)`).
extension LayoutEngine {
    /// What bar `previous`'s gaps must hold when bar `next` follows it on the same line: for every voice whose last
    /// syllable in `previous` meets a first one in `next`, the span from that syllable's column to the bar's end and
    /// the width it must reach for the two to stand `lyricsPairWidth` apart. Empty where they already do.
    ///
    /// The rest of the distance is counted as what it is however the line stretches: the clef `previous` draws before
    /// its barline, `next`'s header (`nextContentStartX`) and leading gap, and `next`'s gaps up to its first syllable
    /// at their least.
    static func lyricJoinDemands(
        previous: TickAggregate, next: TickAggregate, nextContentStartX: CGFloat, metrics: StaffMetrics,
    ) -> [(startTick: Int, endTick: Int, width: CGFloat)] {
        previous.voiceSyllables.compactMap { last in
            guard let first = next.voiceSyllables.first(where: { $0.staff == last.staff && $0.voice == last.voice })
            else { return nil }
            let needed = lyricsPairWidth(
                currentWidth: last.lastWidth, nextWidth: first.firstWidth, dashed: last.lastDashed, metrics: metrics,
            )
            let beyondBar = previous.trailingClefWidth + nextContentStartX + next.leadingGap(sp: metrics.sp)
                + next.minimumWidth(ofGapsBefore: first.firstTick)
            let width = needed - beyondBar
            return width > 0 ? (last.lastTick, previous.measureEnd, width) : nil
        }
    }

    /// Every bar's aggregate as it is spaced when the next bar follows it on its line — `lyricJoinDemands` raised into
    /// its floors — or `nil` where that changes nothing: the last bar, a bar beside one with no aggregate, and most
    /// others.
    ///
    /// The next bar's header is the one it draws mid-line, without the naturals a key change cancels with: the
    /// narrowest it can be there, so the room is never short of what the pair needs.
    static func lyricJoinedAggregates(
        _ aggregates: [TickAggregate?], staves: [Staff], metrics: StaffMetrics,
    ) -> [TickAggregate?] {
        aggregates.indices.map { i in
            guard i + 1 < aggregates.count, let previous = aggregates[i], let next = aggregates[i + 1],
                  !previous.voiceSyllables.isEmpty, !next.voiceSyllables.isEmpty
            else { return nil }
            let header = computeHeaderSchedule(
                measureIdx: i + 1, staves: staves, metrics: metrics,
                synthesizeClefForAllStaves: false, synthesizeKeySigForAllStaves: false,
                leadingClefDrawnBefore: leadingClefDrawnBefore(measureIdx: i + 1, staves: staves, plan: nil),
            )
            let demands = lyricJoinDemands(
                previous: previous, next: next, nextContentStartX: header.contentStartX, metrics: metrics,
            )
            guard !demands.isEmpty else { return nil }
            let joined = previous.raisingFloors(to: demands)
            return joined == previous ? nil : joined
        }
    }
}
