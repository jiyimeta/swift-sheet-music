import SheetMusicFoundation

/// Reading a clipboard payload — a small, self-contained `Score` — as copy material, and re-addressing what came
/// back onto the staves of the score being pasted into.
///
/// Split out of `RangeCopySource.swift` rather than added to it: that file sits at its 400-line ceiling, and the
/// payload entry point is a seam of its own — everything here is about a score that arrived from outside, while
/// the main file is about a range of the score already open.
extension RangeCopySource {
    /// The whole extent of `payload`, read as copy material: its own first timed slot to its own last, handed to
    /// `init?(range:in:)` so every rule that path enforces — the half-open span, the clamp and its tuplet-member
    /// exemption, the outer-tie clearing, the spanner collection — applies to a pasted payload exactly as it
    /// already applies to a duplicated range. `nil` when the payload holds no chord or rest, OR when its own
    /// extent cuts a tuplet: `init?(range:in:)` throws `.insideTuplet` for that, and a payload has no channel to
    /// report a throw, so a payload that cannot be resolved is simply unreadable rather than a thrown error.
    ///
    /// Which of the two it was is still recoverable, and `PasteRange.refusalReason(forUnusable:at:)` recovers it
    /// by re-running these same two steps on the failure path — so the distinction costs a second resolution
    /// only when the paste is already being refused, and no rule is stated twice.
    init?(payload: Score) {
        guard let first = Self.firstTimedSlot(in: payload), let last = Self.lastTimedSlot(in: payload),
              let resolved = try? RangeCopySource(
                  range: VoiceElementRange(start: first, end: last), in: payload,
              )
        else { return nil }
        self = resolved
    }

    /// The chord or rest with the EARLIEST ONSET anywhere in `score`, compared across every staff rather than
    /// picked from staff-address order. A staff-major pick would be wrong whenever the first-addressed staff
    /// rests through the payload's opening beat while another staff already sounds at tick zero — a plain offset
    /// entry, and one `RangeCopyPayload.score(for:in:)` can legitimately produce, since it trims each staff's
    /// boundary measure independently and only the staff that owned the original range's bound is guaranteed a
    /// chord exactly at that tick.
    static func firstTimedSlot(in score: Score) -> VoiceElementID? {
        chordSlots(in: score)
            .compactMap { id in score.onset(of: id).map { (id, $0) } }
            .min { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The chord or rest with the LATEST END anywhere in `score` — the mirror of `firstTimedSlot(in:)`, and for
    /// the same reason: the last-addressed staff is not guaranteed to be the one still sounding when every other
    /// staff has already finished.
    static func lastTimedSlot(in score: Score) -> VoiceElementID? {
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
