import SheetMusicAudioCore
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Playback runs to the barline of the bar the music stops in, rather than cutting off the instant the last note
/// releases.
///
/// The subject is the RENDERED SEQUENCE, not `PlaybackTimeline`: the timeline already walks rests and already
/// reported the full bar, and `PlaybackEngine` decides end-of-score from the transport (`!sequencer.isPlaying` /
/// `backend.isAtEnd`), never from the timeline. So every assertion here reads the end-of-track tick, which is what
/// the transport's length actually is.
@Suite("Rendered tail reaches the barline")
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

    /// Trailing EMPTY bars are not played through. A new score in folino is 32 bars by default, so padding to the
    /// notated end would answer "it stops too soon" with half a minute of silence — the music's own bar is the end.
    @Test func `trailing empty bars are not played through`() throws {
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
        #expect(ends == [1920], "padded past the first bar into the 7 empty ones")
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
    /// first barline of a score with an anacrusis is the pickup's own end, not a full bar in.
    @Test func `a pickup bar's barline is the pickup's own length`() {
        let score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", staves: [.init(clefType: "G")])],
            measureCount: 4, pickup: Fraction(numerator: 1, denominator: 4),
        ))
        // A note released one eighth into a quarter-note pickup reaches that pickup's barline at 480, not at 1920.
        #expect(MidiRenderer.ticksToBarline(afterNotated: 240, in: score) == 240)
    }
}
