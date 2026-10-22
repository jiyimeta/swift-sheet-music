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

    @Test("an unknown part or point is refused")
    func outOfRangeIsTargetNotFound() {
        var score = fixture()
        #expect(throws: SheetMusicError.self) { try SetStripMix([mix(7, [0])]).apply(to: &score) }
        #expect(throws: SheetMusicError.self) { try SetStripMix([mix(0, [9])]).apply(to: &score) }
    }
}
