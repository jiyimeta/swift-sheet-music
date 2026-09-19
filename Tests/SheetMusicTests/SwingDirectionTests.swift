import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Which way a swung pair leans, measured off the rendered note-ons.
///
/// Reported 2026-09-20: at 60% the OFF-beat sounds long and the down-beat short — the opposite of swing. The
/// adjustment rule reads correctly (`MidiRenderer+Swing.swingAdjustment` delays the up-beat and lengthens the
/// down-beat), so this measures what actually comes out rather than arguing with it.
@Suite("swing leans on the down-beat")
struct SwingDirectionTests {
    /// Four eighths in one 4/4 bar, with a system-wide swing directive on beat one.
    private static func swungEighths(division: Int = 480) -> Score {
        let eighth = Chord(duration: .eighth, notes: [Note(pitch: 60, tpc: 14)])
        var score = Score(
            division: division,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "piano"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(eighth), .chord(eighth), .chord(eighth), .chord(eighth),
                ])])])],
            )],
        )
        var ids = EIDAllocator()
        let anchor = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )
        try? SetSwing(
            anchor: anchor,
            settings: SetSwing.Settings(text: "Swing", unit: .eighth, ratio: 60),
        ).apply(to: &score, ids: &ids)
        return score
    }

    /// The same bar at a finer grid: eight sixteenths, with a sixteenth-unit swing directive on beat one.
    ///
    /// The user reports (2026-09-20) that eighth swing over eighths leans the WRONG way while sixteenth swing
    /// over sixteenths leans correctly. `swingAdjustment` is written in terms of `unitTicks` alone, so the two
    /// cases go down the identical arithmetic — which means either the report is about something upstream of this
    /// renderer, or one of these two measurements is about to disagree with the other. Measuring both side by side
    /// is what tells them apart.
    private static func swungSixteenths(division: Int = 480) -> Score {
        let sixteenth = Chord(duration: .sixteenth, notes: [Note(pitch: 60, tpc: 14)])
        var score = Score(
            division: division,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "piano"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(sixteenth), .chord(sixteenth), .chord(sixteenth), .chord(sixteenth),
                    .chord(sixteenth), .chord(sixteenth), .chord(sixteenth), .chord(sixteenth),
                ])])])],
            )],
        )
        var ids = EIDAllocator()
        let anchor = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )
        try? SetSwing(
            anchor: anchor,
            settings: SetSwing.Settings(text: "Swing", unit: .sixteenth, ratio: 60),
        ).apply(to: &score, ids: &ids)
        return score
    }

    /// The same swung eighths, but behind a 1/8 PICKUP bar — the shape of the user's own score.
    ///
    /// A pickup puts every later bar line at `tick % 480 == 240`, which is exactly the test for an up-beat, so a
    /// grid measured from the score's tick 0 swaps the two halves of every pair. MuseScore measures from the bar
    /// and adds the pickup's shortfall (`chord->rtick() + measure->anacrusisOffset()`, `dom/swing.cpp`).
    private static func swungEighthsAfterPickup(division: Int = 480) -> Score {
        let eighth = Chord(duration: .eighth, notes: [Note(pitch: 60, tpc: 14)])
        let pickup = Measure(
            voices: [Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(eighth),
            ])],
            actualLength: Fraction(numerator: 1, denominator: 8),
        )
        let full = Measure(voices: [Voice(elements: [
            .chord(eighth), .chord(eighth), .chord(eighth), .chord(eighth),
            .chord(eighth), .chord(eighth), .chord(eighth), .chord(eighth),
        ])])
        var score = Score(
            division: division,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "piano"),
                staves: [Staff(measures: [pickup, full])],
            )],
        )
        var ids = EIDAllocator()
        let anchor = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )
        try? SetSwing(
            anchor: anchor,
            settings: SetSwing.Settings(text: "Swing", unit: .eighth, ratio: 60),
        ).apply(to: &score, ids: &ids)
        return score
    }

    /// The note-on ticks of the rendered track, in order.
    private static func noteOnTicks(_ file: MidiFile) -> [Int] {
        file.tracks.flatMap { track in
            track.events.compactMap { event in
                if case let .noteOn(_, _, velocity) = event.event, velocity > 0 { event.tick } else { nil }
            }
        }.sorted()
    }

    @Test("the second eighth of a swung pair starts LATE, not early")
    func offBeatIsDelayed() throws {
        let file = try MidiRenderer.renderForPlayback(score: Self.swungEighths())
        let onsets = Self.noteOnTicks(file)
        try #require(onsets.count == 4)
        // Straight, the pair's second eighth starts at 240. At 60% the down-beat takes 60% of the 480-tick pair,
        // so the off-beat starts at 288.
        #expect(onsets[1] == 288, "off-beat onset — later than 240 means the down-beat is the long one")
        #expect(onsets[3] == 768)
    }

    /// The sixteenth-unit twin, at the same 60%. The pair is 240 ticks, so the off-beat moves from 120 to 144 —
    /// the same 1/10-of-a-pair delay the eighth case gets, measured on the finer grid.
    @Test("a sixteenth-unit swing delays its off-beats by the same proportion")
    func sixteenthOffBeatIsDelayed() throws {
        let file = try MidiRenderer.renderForPlayback(score: Self.swungSixteenths())
        let onsets = Self.noteOnTicks(file)
        try #require(onsets.count == 8)
        #expect(onsets[1] == 144, "off-beat onset — later than 120 means the down-beat is the long one")
        #expect(onsets[3] == 384, "second pair's off-beat: 360 straight, 384 swung")
    }

    /// **The user's own score, reduced to its cause** (2026-09-20). Behind a 1/8 pickup, eighth swing played
    /// backwards — down-beats short, up-beats long — while sixteenth swing was untouched, because a sixteenth
    /// pair is 240 ticks and the pickup's 240-tick shift is invisible to it. That asymmetry is what made the
    /// report read as a bug in the swing UNIT rather than in the grid the unit is measured on.
    ///
    /// The pickup's own eighth IS an up-beat — the last eighth of a notional full bar — so it is delayed; every
    /// bar after it starts a fresh pair, so its first eighth is a down-beat and stays put.
    @Test("a pickup does not invert the pairs of the bars after it")
    func pickupKeepsTheGridOnTheBar() throws {
        let file = try MidiRenderer.renderForPlayback(score: Self.swungEighthsAfterPickup())
        let onsets = Self.noteOnTicks(file)
        try #require(onsets.count == 9, "one pickup eighth plus a full bar of eight")
        #expect(onsets[0] == 48, "the pickup's own eighth is the up-beat before bar 1, so it is delayed")
        #expect(onsets[1] == 240, "bar 1 opens on its down-beat, un-shifted — 240 is the bar line, not a swing")
        // Bar 1 opens at absolute 240, so its own eighths sit at 240, 480, 720 … and only the bar-RELATIVE
        // position decides which of them swings.
        #expect(onsets[2] == 528, "bar 1's first up-beat: bar-relative 240, so absolute 480 + 48")
        #expect(onsets[3] == 720, "bar 1's second down-beat: bar-relative 480, un-shifted")
    }

    /// **Both units, one assertion**: the fraction of its pair that each down-beat keeps. If the eighth case really
    /// leans the other way while the sixteenth case does not, these two numbers disagree — and if they agree, the
    /// reversal the user hears is not coming from this renderer and the search moves upstream of it.
    @Test("both units lean the same way")
    func bothUnitsLeanTheSameWay() throws {
        let eighths = try Self.noteOnTicks(MidiRenderer.renderForPlayback(score: Self.swungEighths()))
        let sixteenths = try Self.noteOnTicks(MidiRenderer.renderForPlayback(score: Self.swungSixteenths()))
        try #require(eighths.count == 4)
        try #require(sixteenths.count == 8)
        // Down-beat share of the first pair, as a percentage of the pair's own length.
        let eighthShare = eighths[1] * 100 / 480
        let sixteenthShare = sixteenths[1] * 100 / 240
        #expect(eighthShare == 60, "eighth unit: the down-beat keeps 60% of the pair")
        #expect(sixteenthShare == 60, "sixteenth unit: the down-beat keeps 60% of the pair")
    }
}
