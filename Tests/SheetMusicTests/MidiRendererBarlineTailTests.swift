import SheetMusicAudioCore
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Playback runs to the END OF THE SCORE, rather than cutting off the instant the last note releases — MuseScore's
/// own behaviour, and what the project owner asked for (2026-09-20). Several assertions below are one bar long
/// simply because their fixture is a one-bar score, where the last barline and the notated end are the same tick.
///
/// The subject is the RENDERED SEQUENCE, not `PlaybackTimeline`: the timeline already walks rests and already
/// reported the full bar, and `PlaybackEngine` decides end-of-score from the transport (`!sequencer.isPlaying` /
/// `backend.isAtEnd`), never from the timeline. So every assertion here reads the end-of-track tick, which is what
/// the transport's length actually is.
@Suite("Rendered tail reaches the end of the score")
struct MidiRendererBarlineTailTests {
    /// One 4/4 bar at division 480: a quarter note on beat 1, then rests to the barline.
    private static func quarterThenRests(division: Int = 480) -> Score {
        let voice = Voice(elements: [
            .keySignature(KeySignature(concertKey: 0)),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
        return Score(
            division: division,
            parts: [Part(id: "1", instrument: Instrument(id: "piano"), staves: [Staff(measures: [
                Measure(voices: [voice]),
            ])])],
        )
    }

    private static func endOfTrackTicks(_ file: MidiFile) -> [Int] {
        file.tracks.flatMap { track in
            track.events.compactMap { if case .endOfTrack = $0.event { $0.tick } else { nil } }
        }
    }

    /// The reported bug. The last note releases at 480; the bar ends at 1920; the sequence used to end at 481.
    @Test func `a bar that stops after beat one still plays to its barline`() throws {
        let score = Self.quarterThenRests()
        let file = try MidiRenderer.renderForPlayback(score: score)
        #expect(Self.endOfTrackTicks(file) == [1920])
    }

    /// The timeline was never the short one — pinned here so a later "fix" does not go looking for the length in
    /// the wrong object again. Both now agree on 1920.
    @Test func `the timeline already reached the barline`() {
        let timeline = PlaybackTimeline(score: Self.quarterThenRests())
        #expect(timeline.totalTicks == 1920)
    }

    /// A bar the music fills exactly is NOT padded by a phantom extra bar: the final note-off already sits on the
    /// barline, so there is no remainder to add.
    @Test func `a full bar is not padded past its barline`() throws {
        let voice = Voice(elements: [
            .keySignature(KeySignature(concertKey: 0)),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
        ])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "piano"), staves: [Staff(measures: [
                Measure(voices: [voice]),
            ])])],
        )
        #expect(try Self.endOfTrackTicks(MidiRenderer.renderForPlayback(score: score)) == [1920])
    }

    /// Trailing EMPTY bars ARE played through, because MuseScore plays a score to its end and the project owner
    /// asked for that parity (2026-09-20).
    ///
    /// This assertion used to be its own opposite. The reasoning then was that a new folino score is 32 empty bars
    /// by default, so running to the notated end answers "it stops too soon" with half a minute of silence — a
    /// real cost, but the user's to weigh, and they weighed it the other way. It also settles a genuine
    /// inconsistency: `PlaybackTimeline` has always walked to the notated end, so the seek bar showed a length the
    /// transport refused to play.
    @Test func `trailing empty bars are played through`() throws {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", staves: [.init(clefType: "G")])],
            measureCount: 8,
        ))
        let slot = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 2,
        )
        score[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let ends = try Self.endOfTrackTicks(MidiRenderer.renderForPlayback(score: score))
        #expect(ends == [8 * 1920], "all eight bars, not just the one holding the note")
    }

    /// And the transport's length now agrees with the seek bar's, which is the inconsistency the change closes.
    ///
    /// **The fixture keeps its first bar FULL** — a quarter plus three quarter rests, not a quarter written over
    /// the bar's measure rest. The two lengths are measured differently and only coincide on a well-formed score:
    /// the transport pads to the NOMINAL end (`effectiveMeasureDurations`, i.e. what the meter says each bar is
    /// worth) while `PlaybackTimeline.totalTicks` reports where the CONTENT actually ran out. Replacing a measure
    /// rest with a quarter leaves a bar holding 480 ticks of a 1920-tick meter, and the two then differ by the
    /// 1440 that bar is missing — which is a property of that score, not of either measurement.
    @Test func `the transport and the timeline report the same length`() throws {
        let first = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        let empty = { Measure(voices: [Voice(elements: [.rest(duration: .measure)])]) }
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "piano"), staves: [Staff(
                measures: [Measure(voices: [first])] + (0 ..< 7).map { _ in empty() },
            )])],
        )
        let ends = try Self.endOfTrackTicks(MidiRenderer.renderForPlayback(score: score))
        #expect(ends == [8 * 1920], "eight full bars")
        #expect(ends == [PlaybackTimeline(score: score).totalTicks])
    }

    /// Every track in a multi-staff score is carried to the same end, so the transport's length does not depend on
    /// which staff happens to hold the last note.
    @Test func `both staves of a piano part end together`() throws {
        let treble = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)])),
            .rest(duration: .quarter), .rest(duration: .half),
        ])
        let bass = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .half, notes: [Note(pitch: 48, tpc: 14)])),
            .rest(duration: .half),
        ])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "piano"), staves: [
                Staff(measures: [Measure(voices: [treble])]),
                Staff(measures: [Measure(voices: [bass])]),
            ])],
        )
        #expect(try Self.endOfTrackTicks(MidiRenderer.renderForPlayback(score: score)) == [1920, 1920])
    }

    /// The barline arithmetic follows the score's own division rather than assuming 480.
    @Test func `the barline is measured in the score's own division`() throws {
        let file = try MidiRenderer.renderForPlayback(score: Self.quarterThenRests(division: 960))
        #expect(Self.endOfTrackTicks(file) == [3840])
    }

    /// EXPORT is not padded. MuseScore's own MIDI export ends one tick after the final note-off, and the golden
    /// comparisons in `MidiSemanticComparison` measure our file against real MuseScore output — padding `render`
    /// itself made six of them diverge. Playback and a file are different lengths on purpose; this is the pin that
    /// stops the padding migrating back into the shared renderer.
    @Test func `export is left at MuseScore's own end-of-track`() throws {
        let score = Self.quarterThenRests()
        #expect(try Self.endOfTrackTicks(MidiRenderer.render(score: score)) == [480])
        #expect(try Self.endOfTrackTicks(MidiRenderer.renderForPlayback(score: score)) == [1920])
    }

    /// A pickup bar is shorter than its time signature, and `effectiveMeasureDurations` is what knows that — so the
    /// notated end of a score with an anacrusis counts the pickup at its own length, not at a full bar.
    @Test func `the notated end counts a pickup at its own length`() {
        let score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", staves: [.init(clefType: "G")])],
            measureCount: 4, pickup: Fraction(numerator: 1, denominator: 4),
        ))
        // 4 bars: a 480-tick pickup plus three full 4/4 bars = 6240. From one eighth in, 6000 still to go — a
        // pickup counted as a whole bar would ask for 1440 more than that.
        #expect(MidiRenderer.ticksToNotatedEnd(afterNotated: 240, in: score) == 6000)
    }
}
