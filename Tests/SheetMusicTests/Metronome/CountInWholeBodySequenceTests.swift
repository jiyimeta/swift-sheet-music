import Foundation
@testable import SheetMusicAudioCore
import SheetMusicAudioSwiftySynthCore
import SheetMusicMIDI
import Testing

/// The count-in sequence a one-sequence-per-synth backend plays its metronome from: the pre-roll, the body from the
/// count's start on, then the whole body again (`MetronomeSequenceBuilder.countInSequenceWithWholeBody`). A loop wrap
/// or a seek during that play lands on the copy, so these pin that every score tick maps, through the one offset
/// function, onto a click exactly where the plain body sequence has one — and at the same time.
@Suite("MetronomeSequenceBuilder.countInSequenceWithWholeBody")
struct CountInWholeBodySequenceTests {
    private static let division = 480

    /// A 4/4 conductor at 60 bpm that turns to 120 bpm at bar 2 (tick 1920), and runs to the end of bar 4.
    private static let rendered = MidiFile(division: division, tracks: [MidiTrack(events: [
        TimedMidiEvent(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 1_000_000))),
        TimedMidiEvent(tick: 1920, event: .meta(.tempo(microsecondsPerQuarter: 500_000))),
        TimedMidiEvent(tick: 7680, event: .endOfTrack),
    ])])

    private static let beats = stride(from: 0, to: 7680, by: 480).map {
        MetronomeBeat(tick: $0, isDownbeat: $0 % 1920 == 0)
    }

    /// One bar counted in at 120 bpm, into bar 3 (tick 3840) — past the tempo change and past an A–B loop's start.
    private static let plan = CountInBeats.Result(
        preRollTicks: 1920,
        beats: stride(from: 0, to: 1920, by: 480).map { MetronomeBeat(tick: $0, isDownbeat: $0 == 0) },
        quarterBpm: 120,
    )
    private static let baseTick = 3840
    private static let bodyEndTick = 7680

    private static func build() -> (file: MidiFile, wholeBodyTick: Int) {
        MetronomeSequenceBuilder.countInSequenceWithWholeBody(
            rendered: rendered, metronomeBeats: beats, plan: plan, baseTick: baseTick, bodyEndTick: bodyEndTick,
        )
    }

    private static func clickTicks(_ file: MidiFile) -> [Int] {
        file.tracks.flatMap { track in
            track.events.compactMap { event -> Int? in
                guard case let .noteOn(channel, _, _) = event.event, channel == 9 else { return nil }
                return event.tick
            }
        }.sorted()
    }

    private static func tempoMap(_ file: MidiFile) throws -> SequenceTempoMap {
        try #require(SequenceTempoMap(smf: MidiWriter.write(file)))
    }

    @Test("the pre-roll, the body from the count's start, then every body beat behind the copy's start")
    func layout() throws {
        let (file, wholeBodyTick) = Self.build()
        let firstOffset = Self.plan.preRollTicks - Self.baseTick
        let expectedFirst = Self.plan.beats.map(\.tick) + Self.beats.map(\.tick).filter { $0 >= Self.baseTick }.map {
            MetronomeSequenceBuilder.metronomeTick(forScoreTick: $0, offset: firstOffset)
        }
        let expectedCopy = Self.beats.map {
            MetronomeSequenceBuilder.metronomeTick(forScoreTick: $0.tick, offset: wholeBodyTick)
        }
        #expect(Self.clickTicks(file) == expectedFirst + expectedCopy)
        // The copy starts past where the first part plays the score's end, so it never cuts into the first pass.
        #expect(wholeBodyTick > MetronomeSequenceBuilder.metronomeTick(
            forScoreTick: Self.bodyEndTick, offset: firstOffset,
        ))
        // A playable SMF: the writer traps on a track that goes back in time.
        let parsed = try MidiReader.read(MidiWriter.write(file))
        #expect(Self.clickTicks(parsed) == Self.clickTicks(file))
    }

    @Test("tempo changes across the pre-roll: both parts keep the body's own timing beat for beat")
    func tempoAcrossThePreRoll() throws {
        let (file, wholeBodyTick) = Self.build()
        let map = try Self.tempoMap(file)
        let body = try Self.tempoMap(MetronomeSequenceBuilder.metronomeOnlySequence(
            rendered: Self.rendered, metronomeBeats: Self.beats,
        ))
        let firstOffset = Self.plan.preRollTicks - Self.baseTick

        // The pre-roll is the plan's tempo: one 4/4 bar at 120 bpm is 2 s.
        #expect(abs(map.seconds(atTick: Double(Self.plan.preRollTicks)) - 2) < 1e-9)
        // The first part, from the count's start on, plays the body's seconds tick for tick (120 bpm there).
        for tick in stride(from: Self.baseTick, through: Self.bodyEndTick, by: 480) {
            let first = Double(MetronomeSequenceBuilder.metronomeTick(forScoreTick: tick, offset: firstOffset))
            let elapsed = map.seconds(atTick: first) - map.seconds(atTick: Double(Self.plan.preRollTicks))
            let expected = body.seconds(atTick: Double(tick)) - body.seconds(atTick: Double(Self.baseTick))
            #expect(abs(elapsed - expected) < 1e-9, "score tick \(tick)")
        }
        // The copy plays the whole body's seconds from its own start — the 60 bpm bar, then the change at 1920.
        for tick in stride(from: 0, through: Self.bodyEndTick, by: 480) {
            let copy = Double(MetronomeSequenceBuilder.metronomeTick(forScoreTick: tick, offset: wholeBodyTick))
            let elapsed = map.seconds(atTick: copy) - map.seconds(atTick: Double(wholeBodyTick))
            #expect(abs(elapsed - body.seconds(atTick: Double(tick))) < 1e-9, "score tick \(tick)")
        }
    }

    @Test("a wrap or a seek to a tick before the count's start lands on a click in the copy")
    func positionsBeforeTheStartLandOnTheCopy() {
        let (file, wholeBodyTick) = Self.build()
        let clicks = Set(Self.clickTicks(file))
        // The loop's start (bar 2) and a beat in bar 1: before the count's start, so only the copy has them. (Through
        // the first part's offset they would map before tick 0.)
        for scoreTick in [1920, 480] {
            #expect(clicks.contains(MetronomeSequenceBuilder.metronomeTick(
                forScoreTick: scoreTick, offset: wholeBodyTick,
            )))
        }
    }

    @Test("a count whose bars outlast the body still starts the copy past the pre-roll")
    func copyStartsPastThePreRoll() {
        // Counted into the score's last beat: the first part's last click is a pre-roll one.
        let (_, wholeBodyTick) = MetronomeSequenceBuilder.countInSequenceWithWholeBody(
            rendered: Self.rendered, metronomeBeats: Self.beats, plan: Self.plan, baseTick: 7680,
            bodyEndTick: Self.bodyEndTick,
        )
        #expect(wholeBodyTick > Self.plan.preRollTicks)
    }
}
