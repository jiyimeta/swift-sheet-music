import Foundation
@testable import SheetMusicAudioApple
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI
import Testing

/// Sequence-build assertions for the count-in pre-roll. These inspect the built
/// `MidiFile` (via the pure `PreRollSequenceAssembler` seam) and the engine's
/// use of `SequenceMap` (via `PlaybackEngine.mappedCursor`) — never live audio,
/// so they run headless.
struct PlaybackEnginePreRollTests {
    private static let division = 480
    private static let quarter = 480

    /// `measureCount` bars of 4/4, each holding four quarter-note chords with
    /// distinct pitches, at 120 BPM (quarter). Notes land at consecutive
    /// quarter ticks: measure `m` note `i` at `(m * 4 + i) * quarter`.
    private static func score(measureCount: Int = 3) -> Score {
        let pitches = [60, 62, 64, 65]
        var measures: [Measure] = []
        for m in 0 ..< measureCount {
            var elements: [VoiceElement] = []
            if m == 0 {
                elements.append(.timeSignature(TimeSignature(numerator: 4, denominator: 4)))
            }
            for i in 0 ..< 4 {
                elements.append(.chord(Chord(
                    duration: .quarter,
                    notes: [Note(pitch: pitches[i], tpc: 14)],
                )))
            }
            measures.append(Measure(voices: [Voice(elements: elements)]))
        }
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: measures)],
        )
        let systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2.0))),
        ])] + Array(repeating: SystemMeasure(), count: max(0, measureCount - 1))
        return Score(division: division, parts: [part], systemMeasures: systemMeasures, metaTags: [:])
    }

    private static func managedChannels(_ score: Score) -> Set<Int> {
        Set(MidiRenderer.staffChannels(score: score))
    }

    private static func noteOnTicks(_ track: MidiTrack) -> [Int] {
        track.events.compactMap { timed in
            if case .noteOn = timed.event { return timed.tick }
            return nil
        }
    }

    /// The `(pitch, velocity)` of every note-on in the track, tick order.
    private static func noteOns(_ track: MidiTrack) -> [(tick: Int, pitch: Int, velocity: Int)] {
        track.events.compactMap { timed in
            if case let .noteOn(_, pitch, velocity) = timed.event {
                return (timed.tick, pitch, velocity)
            }
            return nil
        }
    }

    // MARK: - Count-in from the start

    @Test func countInFromStartPlacesClicksAcrossTheProRollAndShiftsContent() throws {
        let score = Self.score()
        let plan = try #require(CountInBeats.compute(
            score: score, startCursor: .beat(measureIndex: 0, tickInMeasure: 0),
        ))
        #expect(plan.preRollTicks == 1920)

        let rendered = try MidiRenderer.render(score: score)
        let beats = PlaybackTimeline.metronomeBeats(score: score)
        let assembled = PreRollSequenceAssembler.assemble(
            rendered: rendered,
            metronomeBeats: beats,
            mixerManagedChannels: Self.managedChannels(score),
            plan: plan,
            baseTick: 0,
        )

        // Pre-roll click track: note-ons exactly at plan.beats' ticks, count
        // matches, and only tick 0 is the strong (hi wood block, note 76, vel 100).
        let preRoll = assembled.midi.tracks[assembled.preRollTrackIndex]
        let clicks = Self.noteOns(preRoll)
        #expect(clicks.count == plan.beats.count)
        #expect(clicks.map(\.tick) == [0, 480, 960, 1440])
        #expect(clicks.map(\.tick) == plan.beats.map(\.tick))
        #expect(clicks[0].pitch == 76)
        #expect(clicks[0].velocity == 100)
        #expect(clicks.dropFirst().allSatisfy { $0.pitch == 77 })
        // Every click sits strictly inside the pre-roll region.
        #expect(clicks.allSatisfy { $0.tick < plan.preRollTicks })

        // Score content that was at score tick 0 (baseTick) now sits at seq
        // tick preRollTicks; nothing sounds before it.
        let staff = assembled.midi.tracks[0]
        let staffNoteOns = Self.noteOnTicks(staff)
        #expect(staffNoteOns.min() == 1920)
        #expect(staffNoteOns.contains(1920))
        // Shift is uniform: the four measure-0 notes at score 0/480/960/1440
        // land at seq 1920/2400/2880/3360.
        #expect(Array(staffNoteOns.prefix(4)) == [1920, 2400, 2880, 3360])

        // A tempo meta is seeded at seq tick 0 (governing tempo 120 BPM →
        // 500_000 µs/quarter) so the pre-roll plays at the right speed.
        #expect(staff.events.first == TimedMidiEvent(
            tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 500_000)),
        ))

        // Body metronome (last track) is shifted too: first body click at
        // seq preRollTicks, none inside the pre-roll.
        let body = assembled.midi.tracks[assembled.bodyMetronomeTrackIndex]
        #expect(Self.noteOnTicks(body).min() == 1920)
    }

    // MARK: - Count-in from mid-score

    @Test func countInMidScoreDropsEarlierContentAndShiftsTheRest() throws {
        let score = Self.score()
        let startCursor = ScoreCursor.beat(measureIndex: 1, tickInMeasure: 0)
        let plan = try #require(CountInBeats.compute(score: score, startCursor: startCursor))
        let baseTick = PlaybackTimeline(score: score).frame(forCursor: startCursor)?.tick ?? -1
        #expect(baseTick == 1920)

        let rendered = try MidiRenderer.render(score: score)
        let fullNoteOnCount = Self.noteOnTicks(rendered.tracks[0]).count // 12 quarter notes

        let assembled = PreRollSequenceAssembler.assemble(
            rendered: rendered,
            metronomeBeats: PlaybackTimeline.metronomeBeats(score: score),
            mixerManagedChannels: Self.managedChannels(score),
            plan: plan,
            baseTick: baseTick,
        )

        let staffNoteOns = Self.noteOnTicks(assembled.midi.tracks[0])
        // The four measure-0 notes (score tick < baseTick) are gone.
        #expect(staffNoteOns.count == fullNoteOnCount - 4)
        // The note at score tick baseTick now sits at seq tick preRollTicks;
        // nothing before it.
        #expect(staffNoteOns.min() == plan.preRollTicks)
        #expect(staffNoteOns.contains(plan.preRollTicks))
        // Content shifted by (preRollTicks - baseTick): score 1920/2400/2880/3360
        // → seq preRollTicks + 0/480/960/1440.
        let shift = plan.preRollTicks - baseTick
        #expect(Array(staffNoteOns.prefix(4)) == [1920, 2400, 2880, 3360].map { $0 + shift })
    }

    // MARK: - Count-in disabled: byte-identical to today's build

    @Test func countInFalseBuildsTheSameSequenceAsToday() throws {
        let score = Self.score()
        let managed = Self.managedChannels(score)
        let beats = PlaybackTimeline.metronomeBeats(score: score)

        // Reference: exactly what the pre-count-in engine assembled — render,
        // append the body metronome, post-process. No pre-roll, no shift.
        var reference = try MidiRenderer.render(score: score)
        reference.tracks.append(
            MetronomeController.makeMetronomeTrack(beats: beats, division: reference.division),
        )
        MidiSynthPostProcess.apply(midi: &reference, mixerManagedChannels: managed)

        let built = try PreRollSequenceAssembler.assembleNormal(
            rendered: MidiRenderer.render(score: score),
            metronomeBeats: beats,
            mixerManagedChannels: managed,
        )
        #expect(built == reference)
        // The serialized bytes match too (nothing shift/pre-roll leaked in).
        #expect(try MidiWriter.write(built) == (MidiWriter.write(reference)))
        // One staff track + one metronome track — no extra pre-roll track.
        #expect(built.tracks.count == 2)
    }

    // MARK: - Engine's use of SequenceMap: cursor pins during the pre-roll

    @Test func mappedCursorPinsDuringProRollThenTracksScore() {
        let score = Self.score()
        let timeline = PlaybackTimeline(score: score)
        let map = SequenceMap(preRollTicks: 1920, baseTick: 0)

        // Inside the pre-roll → nil (caller keeps the cursor pinned at start).
        #expect(PlaybackEngine.mappedCursor(rawSequencerTick: 0, sequenceMap: map, timeline: timeline) == nil)
        #expect(PlaybackEngine.mappedCursor(rawSequencerTick: 1919, sequenceMap: map, timeline: timeline) == nil)

        // First tick after the pre-roll maps to score tick 0's cursor.
        let atStart = PlaybackEngine.mappedCursor(rawSequencerTick: 1920, sequenceMap: map, timeline: timeline)
        #expect(atStart != nil)
        #expect(atStart == timeline.frame(atTick: 0)?.cursor)

        // Deeper into the body maps to the corresponding score tick (480).
        let atBeatTwo = PlaybackEngine.mappedCursor(rawSequencerTick: 2400, sequenceMap: map, timeline: timeline)
        #expect(atBeatTwo == timeline.frame(atTick: 480)?.cursor)

        // Identity map is a straight pass-through (normal, non-count-in play).
        let identity = SequenceMap.identity
        #expect(
            PlaybackEngine.mappedCursor(rawSequencerTick: 480, sequenceMap: identity, timeline: timeline)
                == timeline.frame(atTick: 480)?.cursor,
        )
    }

    // MARK: - Nil-cursor resume semantics (guards the count-in "restart at m1 on resume" bug)

    @Test func effectiveStartCursorResolvesNilAsResumeUnlessStopped() {
        let explicit = ScoreCursor.beat(measureIndex: 3, tickInMeasure: 0)
        let current = ScoreCursor.beat(measureIndex: 1, tickInMeasure: 240)

        // An explicit cursor always wins, regardless of state / current position.
        #expect(PlaybackEngine.effectiveStartCursor(
            cursor: explicit, isStopped: true, currentCursor: current,
        ) == explicit)
        #expect(PlaybackEngine.effectiveStartCursor(
            cursor: explicit, isStopped: false, currentCursor: nil,
        ) == explicit)

        // Nil cursor while NOT stopped (paused/playing) → resume from the current position.
        #expect(PlaybackEngine.effectiveStartCursor(
            cursor: nil, isStopped: false, currentCursor: current,
        ) == current)

        // Nil cursor while stopped → from the top (nil → measure 1).
        #expect(PlaybackEngine.effectiveStartCursor(
            cursor: nil, isStopped: true, currentCursor: current,
        ) == nil)

        // Nil cursor, not stopped, but no current position → nil.
        #expect(PlaybackEngine.effectiveStartCursor(
            cursor: nil, isStopped: false, currentCursor: nil,
        ) == nil)
    }
}
