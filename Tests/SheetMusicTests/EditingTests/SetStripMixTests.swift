@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite("SetStripMix")
struct SetStripMixTests {
    /// Flute (program 73) and a piano that changes to an organ in bar 2 and back to a piano in bar 3.
    private func fixture() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "t",
            parts: [
                .init(instrumentID: "flute", longName: "Flute", staves: [.init(clefType: "G")], gmProgram: 73),
                .init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")], gmProgram: 0),
            ],
            measureCount: 3,
        ))
        let piano = score.parts[1].instrument
        var organ = piano
        organ.id = "organ"
        organ.channels = [InstrumentChannel(program: 19)]
        for (measure, instrument) in [(1, organ), (2, piano)] {
            score.systemMeasures.updateValue(at: measure) { measureValue in
                measureValue = SystemMeasure(elements: [PositionedSystemElement(
                    position: .start,
                    element: .instrumentChange(InstrumentChange(text: instrument.id, instrument: instrument)),
                    originalStaff: StaffAddress(partIndex: 1, staffIndexInPart: 0),
                )])
            }
        }
        return score
    }

    private func changeChannel(_ score: Score, measure: Int) throws -> InstrumentChannel {
        guard case let .instrumentChange(change) = score.systemMeasures[measure].elements[0].element else {
            throw Missing()
        }
        return try #require(change.instrument?.channels.first)
    }

    private struct Missing: Error {}

    private func mix(_ partIndex: Int, _ points: [Int], volume: Int = 90, program: Int = 5) -> StripMix {
        StripMix(partIndex: partIndex, points: points, volume: volume, program: program, isMuted: true, isSoloed: true)
    }

    @Test("writes the part instrument's primary channel")
    func writesPartInstrumentChannel() throws {
        var score = fixture()
        try SetStripMix([mix(0, [0])]).apply(to: &score)
        let channel = score.parts[0].instrument.channel
        #expect(channel.volume == 90)
        #expect(channel.program == 5)
        #expect(channel.isMuted && channel.isSoloed)
        #expect(score.parts[1].instrument.channel.program == 0)
    }

    @Test("writes every point of a strip, the part instrument and its later instrument change alike")
    func writesEveryPointOfAStrip() throws {
        var score = fixture()
        let plan = LiveChannelPlan.build(score: score)
        let pianoPoints = plan.timelineIndices(partIndex: 1, ordinal: 0)
        #expect(pianoPoints == [0, 2])
        try SetStripMix([mix(1, pianoPoints)]).apply(to: &score)
        #expect(score.parts[1].instrument.channel.volume == 90)
        #expect(try changeChannel(score, measure: 2).volume == 90)
        #expect(try changeChannel(score, measure: 1).program == 19, "the organ is another strip")
    }

    @Test("the edited strips keep their numbering: a saved mute does not split one strip into two")
    func muteDoesNotSplitAStrip() throws {
        var score = fixture()
        let before = LiveChannelPlan.build(score: score)
        try SetStripMix([mix(1, [0, 2], volume: 100, program: 0)]).apply(to: &score)
        let after = LiveChannelPlan.build(score: score)
        #expect(after.timelineIndices(partIndex: 1, ordinal: 0) == before.timelineIndices(partIndex: 1, ordinal: 0))
    }

    @Test("undo restores every channel it changed")
    func undoRestoresPreviousChannels() throws {
        let original = fixture()
        var score = original
        let inverse = try SetStripMix([mix(1, [0, 1, 2]), mix(0, [0])]).apply(to: &score)
        try inverse.apply(to: &score)
        #expect(score.parts[0].instrument.channels == original.parts[0].instrument.channels)
        #expect(score.parts[1].instrument.channels == original.parts[1].instrument.channels)
        #expect(try changeChannel(score, measure: 1) == changeChannel(original, measure: 1))
        #expect(try changeChannel(score, measure: 2) == changeChannel(original, measure: 2))
    }

    @Test("an unchanged mix plans to nothing; a changed one plans a command")
    func unchangedPlansNothing() throws {
        let score = fixture()
        let flute = score.parts[0].instrument.channel
        let same = StripMix(
            partIndex: 0, points: [0], volume: flute.volume, program: flute.program, isMuted: false, isSoloed: false,
        )
        #expect(try ScoreEditSession.command(for: .setStripMix([same]), in: score, ids: EIDAllocator(), depth: 0)
            == nil)
        #expect(try ScoreEditSession.command(for: .setStripMix([mix(0, [0])]), in: score, ids: EIDAllocator(), depth: 0)
            != nil)
    }

    /// One part on `instrument`, optionally with a "pizz." staff text at the start (sound-timeline point 1).
    private func techniqueFixture(_ instrument: Instrument, pizzicato: Bool) -> Score {
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        var text = StaffText(text: "pizz.")
        text.annotation = .playTechnique(.pizzicato, playsBack: true)
        let lane = [SystemMeasure(elements: pizzicato
                ? [PositionedSystemElement(position: .start, element: .staffText(text), originalStaff: address)]
                : [])]
        let measure = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 69, tpc: 17)]))),
        ])])
        return Score(division: 480, parts: [Part(
            id: "P1", instrument: instrument, staves: [Staff(lineCount: 5, measures: [measure])],
        )], systemMeasures: IdentifiedArray(lane))
    }

    private let violin = Instrument(id: "violin", channels: [
        InstrumentChannel(program: 40), InstrumentChannel(name: "pizzicato", program: 45),
    ])

    @Test("an instrument point carries volume, mute and solo to its other channels, but not program")
    func instrumentPointFansOutToItsOtherChannels() throws {
        var score = techniqueFixture(violin, pizzicato: false)
        try SetStripMix([mix(0, [0])]).apply(to: &score)
        let channels = score.parts[0].instrument.channels
        #expect(channels[0].program == 5)
        #expect(channels[1].volume == 90)
        #expect(channels[1].isMuted && channels[1].isSoloed)
        #expect(channels[1].program == 45)
    }

    @Test("a technique's own strip wins its channel over the instrument's fan-out, in either order")
    func techniqueStripBeatsFanOut() throws {
        let original = techniqueFixture(violin, pizzicato: true)
        #expect(original.soundTimeline(forPart: 0)[1].flavourSource != nil)
        let arco = mix(0, [0], volume: 90, program: 40)
        let pizz = StripMix(partIndex: 0, points: [1], volume: 30, program: 45, isMuted: false, isSoloed: false)
        for mixes in [[arco, pizz], [pizz, arco]] {
            var score = original
            try SetStripMix(mixes).apply(to: &score)
            let channels = score.parts[0].instrument.channels
            #expect(channels[1].volume == 30)
            #expect(!channels[1].isMuted)
            #expect(channels[0].volume == 90 && channels[0].isMuted)
        }
        // Saving the instrument's strip alone leaves the technique's strip as the score had it.
        var score = original
        try SetStripMix([arco]).apply(to: &score)
        #expect(score.parts[0].instrument.channels[1] == original.parts[0].instrument.channels[1])
    }

    @Test("a strip made only of a technique with no channel of its own cannot be written")
    func generalMIDITechniqueCannotBeWritten() {
        let strings = Instrument(id: "violins", channels: [InstrumentChannel(program: 48)])
        let score = techniqueFixture(strings, pizzicato: true)
        #expect(score.soundTimeline(forPart: 0)[1].flavourSource == nil)
        #expect(!SetStripMix.canWrite(mix(0, [1]), in: score))
        #expect(SetStripMix.canWrite(mix(0, [0]), in: score))
        #expect(SetStripMix.canWrite(mix(0, [1]), in: techniqueFixture(violin, pizzicato: true)))
        #expect(!SetStripMix.canWrite(mix(4, [0]), in: score))
    }

    @Test("an unknown part or point is refused")
    func outOfRangeIsTargetNotFound() {
        var score = fixture()
        #expect(throws: SheetMusicError.self) { try SetStripMix([mix(7, [0])]).apply(to: &score) }
        #expect(throws: SheetMusicError.self) { try SetStripMix([mix(0, [9])]).apply(to: &score) }
    }
}
