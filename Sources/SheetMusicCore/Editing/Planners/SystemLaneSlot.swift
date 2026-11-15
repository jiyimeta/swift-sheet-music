import SheetMusicFoundation

/// The system lane's slot arithmetic that `SetTempo` and `SetStaffText` share with `RehearsalMarkLane`: where a
/// chord sits in its bar, which lane element is "the one at that beat", and where a new one goes.
///
/// A lane mark is addressed by the chord or rest it sits on (spec 2026-09-02 §2.3): the intent carries that
/// element's `VoiceElementID` and this derives the `MeasurePosition` from `Score.onset(of:)`, the walker
/// `Score.voiceElements(in:)` ranks onsets with. A lane element MSCX placed at a tick no chord starts —
/// `<location>`-shifted — is unreachable this way, the limit §2.3 accepts for v1.
public enum SystemLaneSlot {
    /// The lane position of the chord or rest at `anchor`: its onset as a fraction of a whole note. `nil` for a
    /// non-timed element (a clef has no tick of its own) or an anchor that does not resolve.
    ///
    /// **Public because a lane mark can only be looked back up by beat.** `LayoutEngine` must name ONE voice
    /// element when it emits a lane mark, and the identity it picks — lowest voice with a chord at that tick, on
    /// the canonical staff for a staff-less mark — is narrower than the mark's real address. So
    /// `LayoutDocument.staffTextOrigin(at:style:in:)` resolves both its caller's anchor and the emitted mark's
    /// anchor through THIS function and compares the results, rather than comparing `VoiceElementID`s. Reading
    /// the position the same way the writer computed it is the whole point: a second walker in the layout module
    /// would be a second answer to "which beat is this", and `ScoreTickPosition` says why that must not happen.
    public static func position(of anchor: VoiceElementID, in score: Score) -> MeasurePosition? {
        guard case .chord? = score[anchor], let onset = score.onset(of: anchor) else { return nil }
        // `Fraction.init` reduces, so tick 960 at division 480 is 1/2 — equal to the 1/4 + 1/4 cursor the decoder
        // records for a lifted element there, and to `.start` at tick 0.
        return MeasurePosition(numerator: onset.tick, denominator: 4 * score.division)
    }

    /// The chord or rest a SCORE-WIDE lane mark — a tempo, a system text, a system swing — at `position` of bar
    /// `measureIndex` is addressed by: the lowest voice of the first staff, in score order, that starts one at that
    /// tick. `nil` when no staff does (a `<location>`-shifted mark).
    ///
    /// **One answer, whatever staff draws the mark.** A score-wide mark is matched by beat alone (`SetStaffText`,
    /// `SetTempo`, `SetSwing`), so every chord at its beat names it equally well; this picks one, and `LayoutEngine`
    /// emits it as the mark's anchor, so a host can re-derive the very identity a tap on the mark reports — after a
    /// part move, say — without a layout to ask. It does not depend on which staff draws the mark, which can be one
    /// that starts nothing at the beat, or one empty-staff hiding chose.
    public static func anchor(at position: MeasurePosition, measureIndex: Int, in score: Score) -> VoiceElementID? {
        anchor(
            at: position, measureIndex: measureIndex, division: score.division,
            staves: score.allStaves.lazy.compactMap { entry in
                let measures = entry.staff.measures
                guard measures.indices.contains(measureIndex) else { return nil }
                return (entry.address, measures[measureIndex], { measures.effectiveMeasureDurations()[measureIndex] })
            },
        )
    }

    /// `anchor(at:measureIndex:in:)` over staves a caller already holds, in score order, each with its bar and a way
    /// to that bar's effective duration — asked only of a bar with a voice to walk — for `LayoutEngine`, which has
    /// both at hand for every staff it places.
    public static func anchor(
        at position: MeasurePosition, measureIndex: Int, division: Int,
        staves: some Sequence<(StaffAddress, Measure, () -> Fraction)>,
    ) -> VoiceElementID? {
        let tick = position.ticks(division: division)
        for (address, measure, measureDuration) in staves where !measure.voices.isEmpty {
            let duration = measureDuration()
            for (voiceIndex, voice) in measure.voices.enumerated() {
                var running = 0
                for elementIndex in voice.elements.indices {
                    let element = voice.elements[elementIndex]
                    if running == tick, case .chord = element {
                        return VoiceElementID(
                            staff: address, measureIndex: measureIndex, voiceIndex: voiceIndex,
                            elementIndex: elementIndex,
                        )
                    }
                    running += element.cursorAdvance(division: division, in: duration)
                    if running > tick { break }
                }
            }
        }
        return nil
    }

    /// Index of the first element of `measure` at `position` that `matches`, or `nil`.
    static func firstIndex(
        in measure: SystemMeasure, at position: MeasurePosition,
        where matches: (PositionedSystemElement) -> Bool,
    ) -> Int? {
        measure.elements.firstIndex { $0.position == position && matches($0) }
    }

    /// Where a new element at `position` goes: before the first element positioned later, since
    /// `SystemMeasure.elements` is document order — the rule `RehearsalMarkLane.write` applies at `.start`.
    static func insertionIndex(in measure: SystemMeasure, for position: MeasurePosition) -> Int {
        measure.elements.firstIndex { $0.position > position } ?? measure.elements.count
    }
}
