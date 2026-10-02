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
        guard let axis = Axis(extent: extent, targets: targets, in: score) else { return nil }
        staves = axis.staves
        startTick = axis.start
        lengthTicks = axis.end - axis.start

        texts = Self.makeTexts(
            in: score, coveredStaves: extent.staves, geometry: axis.geometry,
            rangeStart: axis.start, rangeEnd: axis.end,
        )

        streams = try Self.makeStreams(
            from: targets, in: score, rangeStart: axis.start, rangeEnd: axis.end,
            lowBound: extent.lowBound, highBound: extent.highBound, operation: operation,
        )
        guard !streams.isEmpty else { return nil }
    }

    /// The lane texts `extent` carries, resolved exactly as `init?(extent:in:operation:)` resolves them but without
    /// building the voice streams, so it costs a walk rather than a copy and never refuses a cut tuplet. It is what
    /// `Score.rangeTextIDs(for:)` lights a range's texts from, which a renderer asks for on every selection change.
    ///
    /// `nil` when the extent selects no chord or rest at all, which is when the copy answers `nil` too.
    static func texts(for extent: Extent, in score: Score) -> [CopiedText]? {
        let targets = score.voiceElements(staves: extent.staves, from: extent.lower, to: extent.upper)
        guard let axis = Axis(extent: extent, targets: targets, in: score) else { return nil }
        return makeTexts(
            in: score, coveredStaves: extent.staves, geometry: axis.geometry,
            rangeStart: axis.start, rangeEnd: axis.end,
        )
    }

    /// The tick axis every figure of a copy is measured on: the first staff the material actually occupies, with the
    /// extent's two edges made absolute on it. Shared by the copy and by `texts(for:in:)`, so the two can never
    /// measure a text's beat against different staves.
    private struct Axis {
        let staves: [StaffAddress]
        let geometry: RangeCopyGeometry
        let start: Int
        let end: Int

        init?(extent: Extent, targets: [VoiceElementID], in score: Score) {
            // `voiceElements(staves:from:to:)` yields ids in staff order, so the staff of the first id is the first
            // staff the material actually occupies — which is the axis the tick figures are measured on.
            var orderedStaves: [StaffAddress] = []
            for target in targets where !orderedStaves.contains(target.staff) {
                orderedStaves.append(target.staff)
            }
            guard let firstStaff = orderedStaves.first else { return nil }
            let geometry = RangeCopyGeometry(staff: firstStaff, in: score)
            guard let start = geometry.absolute(extent.lower), let end = geometry.absolute(extent.upper)
            else { return nil }
            staves = orderedStaves
            self.geometry = geometry
            self.start = start
            self.end = end
        }
    }

    /// Resolves the system-lane text subset once, alongside the voice streams. Flattening measure order and lane
    /// order gives the required tick/lane ordering; the explicit ordinal keeps same-tick lane order stable.
    private static func makeTexts(
        in score: Score, coveredStaves: [StaffAddress], geometry: RangeCopyGeometry,
        rangeStart: Int, rangeEnd: Int,
    ) -> [CopiedText] {
        var collected: [(ordinal: Int, copied: CopiedText)] = []
        var ordinal = 0
        for measureIndex in score.systemMeasures.indices {
            guard geometry.measureStarts.indices.contains(measureIndex) else { continue }
            for positioned in score.systemMeasures[measureIndex].elements {
                defer { ordinal += 1 }
                guard case let .staffText(text) = positioned.element else { continue }
                let absoluteTick = geometry.measureStarts[measureIndex]
                    + positioned.position.ticks(division: score.division)
                guard absoluteTick >= rangeStart, absoluteTick < rangeEnd else { continue }
                if text.isSystemText {
                    guard coveredStaves.contains(Score.canonicalStaff) else { continue }
                    collected.append((ordinal, CopiedText(absoluteTick: absoluteTick, staff: nil, text: text)))
                } else {
                    let staff = positioned.originalStaff ?? Score.canonicalStaff
                    guard coveredStaves.contains(staff) else { continue }
                    collected.append((ordinal, CopiedText(absoluteTick: absoluteTick, staff: staff, text: text)))
                }
            }
        }
        return collected.sorted {
            ($0.copied.absoluteTick, $0.ordinal) < ($1.copied.absoluteTick, $1.ordinal)
        }.map(\.copied)
    }
}

extension RangeCopySource.Extent {
    /// The extent a `VoiceElementRange` states, derived the one way `Score.voiceElements(in:)` derives it:
    /// staves `min ... max` of the two bounds' staves, ticks `[earlier onset, later end)`, and the two bounds
    /// put in chronological order by `Score.chronologicalBounds(of:)` so a partial-tuplet refusal can name the
    /// specific bound that landed inside the tuplet — a range's two bounds may be given in either temporal
    /// order.
    ///
    /// Every range-side caller comes through here: `RangeCopySource.init?(range:in:operation:)` for `R`, and
    /// `RangeCopyPayload.score(for:in:)` for ⌘C. Keeping a private copy of this derivation is what let the
    /// payload builder miss a fact the resolution already had — the boundary measure's new length — so the
    /// derivation is stated once and read from here.
    ///
    /// `nil` when either bound does not resolve in `score`.
    init?(range: VoiceElementRange, in score: Score) {
        guard let startOnset = score.onset(of: range.start), let endOnset = score.onset(of: range.end),
              let startEnd = score.end(of: range.start), let endEnd = score.end(of: range.end),
              let bounds = score.chronologicalBounds(of: range)
        else { return nil }
        let lo = min(range.start.staff, range.end.staff)
        let hi = max(range.start.staff, range.end.staff)
        self.init(
            staves: score.allStaves.map(\.address).filter { (lo ... hi).contains($0) },
            lower: min(startOnset, endOnset), upper: max(startEnd, endEnd),
            lowBound: bounds.earlier, highBound: bounds.later,
        )
    }
}
