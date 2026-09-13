import SheetMusicFoundation

/// Reading a clipboard payload — a small, self-contained `Score` — as copy material, and re-addressing what came
/// back onto the staves of the score being pasted into.
///
/// Split out of `RangeCopySource.swift` rather than added to it: that file sits at its 400-line ceiling, and the
/// payload entry point is a seam of its own — everything here is about a score that arrived from outside, while
/// the main file is about a range of the score already open.
extension RangeCopySource {
    /// The whole extent of `payload`, read as copy material: every staff it carries, over the span from its own
    /// earliest onset to its own latest end, handed to `init?(extent:in:operation:)` so every rule that path
    /// enforces — the half-open span, the clamp and its tuplet-member exemption, the outer-tie clearing, the
    /// spanner collection — applies to a pasted payload exactly as it already applies to a duplicated range.
    /// `nil` when the payload holds no chord or rest, or when its edges do not resolve on the staff its
    /// material starts on. The `operation` this passes downstream is always `"PasteRange"` — the payload entry
    /// point exists for exactly one caller.
    ///
    /// A partial-tuplet refusal is deliberately NOT among the causes, even though `init?(extent:in:operation:)`
    /// can raise one: `wholeExtent(in:)` sets the span to `[earliest onset, latest end)` over every staff, so
    /// every chord in the payload is inside it and no tuplet can be cut by it. That refusal belongs to the COPY
    /// — `RangeCopyPayload.score(for:in:)` makes it, so a range that cuts a tuplet never becomes a payload in
    /// the first place — and `PasteRange.refusalReason(forUnusable:at:)` therefore has only the empty case to
    /// tell apart, which it reads off `wholeExtent(in:)` alone. `try?` here swallows a throw that cannot happen
    /// rather than one that is being ignored.
    init?(payload: Score) {
        guard let extent = Self.wholeExtent(in: payload),
              let resolved = try? RangeCopySource(extent: extent, in: payload, operation: "PasteRange")
        else { return nil }
        self = resolved
    }

    /// `score`'s whole extent, stated outright: every one of its staves, over `[earliest onset, latest end)`.
    ///
    /// This is the region a payload has always meant, and it is now said directly instead of being encoded into
    /// a pair of slots. That encoding could not be made general: `Score.voiceElements(in:)` reads a range's
    /// staff span off the two bounds' staves and its tick span off those same two bounds, so a payload whose
    /// staves do not both stand at both temporal extremes had to surrender one of the four facts. Two successive
    /// approximations surrendered a different one — first the staff span collapsed to whichever staff won both
    /// ties, then re-addressing one slot onto the missing outer staff pulled the tick span in to that staff's
    /// own local extreme — and ordinary piano writing (the lower staff alone reaching both extremes, through two
    /// different elements) still lost a staff's worth of material. `Extent` removes the encoding step, so there
    /// is nothing left to surrender.
    ///
    /// `nil` only when `score` has no chord or rest at all.
    static func wholeExtent(in score: Score) -> Extent? {
        guard let first = firstTimedSlot(in: score), let last = lastTimedSlot(in: score),
              let lower = score.onset(of: first), let upper = score.end(of: last)
        else { return nil }
        return Extent(
            staves: score.allStaves.map(\.address), lower: lower, upper: upper,
            lowBound: first, highBound: last,
        )
    }

    /// The chord or rest with the EARLIEST ONSET anywhere in `score`, compared across every staff rather than
    /// picked from staff-address order. A staff-major pick would be wrong whenever the first-addressed staff
    /// rests through the payload's opening beat while another staff already sounds at tick zero — a plain offset
    /// entry, and one `RangeCopyPayload.score(for:in:)` can legitimately produce, since it trims each staff's
    /// boundary measure independently and only the staff that owned the original range's bound is guaranteed a
    /// chord exactly at that tick.
    private static func firstTimedSlot(in score: Score) -> VoiceElementID? {
        chordSlots(in: score)
            .compactMap { id in score.onset(of: id).map { (id, $0) } }
            .min { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The chord or rest with the LATEST END anywhere in `score` — the mirror of `firstTimedSlot(in:)`, and for
    /// the same reason: the last-addressed staff is not guaranteed to be the one still sounding when every other
    /// staff has already finished.
    private static func lastTimedSlot(in score: Score) -> VoiceElementID? {
        chordSlots(in: score)
            .compactMap { id in score.end(of: id).map { (id, $0) } }
            .max { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Every chord or rest in `score`, staff by staff in display order, measure/voice/element order within each.
    private static func chordSlots(in score: Score) -> [VoiceElementID] {
        var result: [VoiceElementID] = []
        for (address, staff) in score.allStaves {
            for (measureIndex, measure) in staff.measures.enumerated() {
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    for (elementIndex, element) in voice.elements.enumerated() {
                        guard case .chord = element else { continue }
                        result.append(VoiceElementID(
                            staff: address, measureIndex: measureIndex,
                            voiceIndex: voiceIndex, elementIndex: elementIndex,
                        ))
                    }
                }
            }
        }
        return result
    }

    /// This source with every staff address translated from the payload's own numbering to the destination's.
    ///
    /// A payload is renumbered from zero — `RangeCopyPayload.score(for:in:)` drops the parts the range did not
    /// cover — so its staff addresses mean nothing in the score being pasted into. The translation is by
    /// POSITION in display order: the payload's first staff lands on `anchor`, its second on the staff below
    /// that one, and so on, which is where MuseScore's own `pasteStaff` puts them (`read410.cpp:400-402`) and
    /// what makes pasting onto a selected staff mean anything at all. Voice indices are NOT shifted — a
    /// payload's voice 2 is the destination's voice 2, exactly as in MuseScore.
    ///
    /// > Note: MuseScore does NOT refuse a clipboard taller than the staves below the anchor. It logs "paste
    /// > beyond staves" and pastes the staves that fit (`read410.cpp:404-407`). The divergence here is
    /// > DELIBERATE: a paste that silently drops half its material is worse than one the host can report, and
    /// > `PasteRange` has a structured refusal channel MuseScore's `LOGD` does not. A later parity audit should
    /// > leave this alone rather than "fix" it back.
    ///
    /// `nil` when the anchor is not a staff of `score`, or when the material needs more staves than the score
    /// has below it. **The second case is DEFENSIVE, not reachable from this package's own copy path**: a
    /// payload `RangeCopyPayload.score(for:in:)` produced can never be taller than the score it was cut from,
    /// and pasting into that same score therefore always fits. It exists for a hand-built payload, or one that
    /// arrived from a taller document. That is also why the refusal names the anchor rather than working out
    /// which staff was missing — nothing can currently see the difference.
    func relocated(from payload: Score, onto anchor: StaffAddress, in score: Score) -> RangeCopySource? {
        let payloadStaves = payload.allStaves.map(\.address)
        let destinationStaves = score.allStaves.map(\.address)
        guard let base = destinationStaves.firstIndex(of: anchor) else { return nil }
        func mapped(_ staff: StaffAddress) -> StaffAddress? {
            guard let offset = payloadStaves.firstIndex(of: staff),
                  destinationStaves.indices.contains(base + offset)
            else { return nil }
            return destinationStaves[base + offset]
        }
        var movedStreams: [Stream] = []
        for stream in streams {
            guard let destination = mapped(stream.staff) else { return nil }
            movedStreams.append(Stream(
                staff: destination, voiceIndex: stream.voiceIndex, elements: stream.elements,
                tuplets: stream.tuplets, spanners: stream.spanners,
            ))
        }
        var movedStaves: [StaffAddress] = []
        for staff in staves {
            guard let destination = mapped(staff) else { return nil }
            movedStaves.append(destination)
        }
        return RangeCopySource(
            streams: movedStreams, startTick: startTick, lengthTicks: lengthTicks, staves: movedStaves,
        )
    }
}
