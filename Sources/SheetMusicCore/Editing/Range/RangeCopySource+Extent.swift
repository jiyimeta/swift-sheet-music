import SheetMusicFoundation

/// The one resolution every range copy funnels through, and the region description that makes it expressible.
///
/// Split out of `RangeCopySource.swift` rather than added to it: that file sits at its 400-line ceiling. The seam
/// is a real one — this is where a copy's EXTENT is decided, while the main file is about turning the elements
/// that extent selects into streams.
extension RangeCopySource {
    /// The region a copy reads, stated outright instead of inferred from two slots.
    ///
    /// `Score.voiceElements(in:)` reads a `VoiceElementRange`'s staff span off the two bounds' staves and its
    /// tick span off those same two bounds' onsets and ends. Two slots therefore cannot state "every staff, over
    /// this whole tick span" in general: whenever no single staff stands at both temporal extremes, one of the
    /// four facts (two staff addresses, two exact ticks) has to be given up, and every choice of which to give up
    /// silently drops material. A clipboard payload wants exactly that region — every staff it carries, over its
    /// own whole length — so it states the four facts here rather than hunting for a pair of slots that happens
    /// to encode them.
    ///
    /// `lower` and `upper` are expected to come from `Score.onset(of:)` and `Score.end(of:)` of real elements,
    /// never from arithmetic on a bar length: `ScoreTickPosition` compares measure-first, so `(m, barTicks)` and
    /// `(m + 1, 0)` name one instant without being equal, and taking both edges from the same source as the
    /// positions being filtered is what keeps the comparison consistent.
    struct Extent {
        /// The staves to cover. Order is irrelevant — the walk visits `Score.allStaves` in display order and
        /// tests membership — but display order is what every caller has to hand.
        let staves: [StaffAddress]
        /// Inclusive onset edge of the tick span.
        let lower: ScoreTickPosition
        /// Exclusive end edge of the tick span.
        let upper: ScoreTickPosition
        /// The slot standing at the earlier edge. It names a partial-tuplet refusal and does nothing else — the
        /// region above is what selects material, so this slot's staff and tick no longer have to restate it.
        let lowBound: VoiceElementID
        /// The slot standing at the later edge, for the same and only that purpose.
        let highBound: VoiceElementID
    }

    /// Resolves an explicitly stated extent into copy material. Both public entry points funnel through here, so
    /// every rule the copy side enforces — the half-open span, the range-end clamp with its tuplet-member
    /// exemption, the partial-tuplet refusal, the outer-tie clearing, the carried clefs and annotations, the
    /// spanner collection — is stated once and applies identically to `DuplicateRange` and `PasteRange`.
    ///
    /// `nil` when the extent selects no chord or rest at all, or when its edges do not resolve on the staff the
    /// material starts on. Throws `.insideTuplet`, stamped with `operation`, when the extent cuts a tuplet — see
    /// `init?(range:in:operation:)` for why there is no default operation name.
    init?(extent: Extent, in score: Score, operation: String) throws {
        let targets = score.voiceElements(staves: extent.staves, from: extent.lower, to: extent.upper)

        // `voiceElements(staves:from:to:)` yields ids in staff order, so the staff of the first id is the first
        // staff the material actually occupies — which is the axis the tick figures below are measured on.
        var orderedStaves: [StaffAddress] = []
        for target in targets where !orderedStaves.contains(target.staff) {
            orderedStaves.append(target.staff)
        }
        guard let firstStaff = orderedStaves.first else { return nil }
        staves = orderedStaves

        let anchor = RangeCopyGeometry(staff: firstStaff, in: score)
        guard let start = anchor.absolute(extent.lower), let end = anchor.absolute(extent.upper)
        else { return nil }
        startTick = start
        lengthTicks = end - start

        streams = try Self.makeStreams(
            from: targets, in: score, rangeStart: start, rangeEnd: end,
            lowBound: extent.lowBound, highBound: extent.highBound, operation: operation,
        )
        guard !streams.isEmpty else { return nil }
    }
}
