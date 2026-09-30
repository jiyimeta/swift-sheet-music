@testable import SheetMusicAudioCore
@testable import SheetMusicCore
import SheetMusicFoundation
import SheetMusicMIDI
import Testing

/// Where an audition sounds (`PreviewRouting`), shared by the Apple and Windows engines.
@Suite("PreviewRouting")
struct PreviewRoutingTests {
    @Test("a note's tick counts whole measures, then the chords before it in its own measure")
    func noteTick() {
        let score = makeScore(measureCount: 2)
        // Measure 0 opens with its time signature, so its first chord is element 1.
        #expect(PreviewRouting.tick(of: noteID(measure: 0, element: 1), in: score) == 0)
        #expect(PreviewRouting.tick(of: noteID(measure: 0, element: 2), in: score) == 480)
        #expect(PreviewRouting.tick(of: noteID(measure: 1, element: 0), in: score) == 1920)
        #expect(PreviewRouting.tick(of: noteID(measure: 1, element: 3), in: score) == 3360)
    }

    @Test("an out-of-range measure answers the in-measure offset alone")
    func unresolvedMeasure() {
        let score = makeScore(measureCount: 1)
        #expect(PreviewRouting.tick(of: noteID(measure: 5, element: 0), in: score) == 0)
    }

    @Test("the channel follows the part's instrument change from the change's tick on")
    func channelAfterInstrumentChange() throws {
        let score = makeInstrumentChangeScore(leadingMeasureCount: 1)
        let derivation = PreparedPlayback.derive(score: score)
        let plan = derivation.channelLayout.liveChannelPlan
        let opening = try UInt8(clamping: #require(plan.strip(partIndex: 0, ordinal: 0)).liveChannel)
        let changed = try UInt8(clamping: #require(plan.strip(partIndex: 0, ordinal: 1)).liveChannel)
        #expect(opening != changed)

        func channel(atTick tick: Int) -> UInt8? {
            PreviewRouting.channel(
                forStaff: 0, atTick: tick,
                openingChannels: derivation.channelLayout.staffMIDIChannels,
                switches: derivation.staffChannelSwitches,
            )
        }
        #expect(channel(atTick: 0) == opening)
        #expect(channel(atTick: 1919) == opening)
        #expect(channel(atTick: 1920) == changed)
        #expect(channel(atTick: 3000) == changed)
    }

    @Test("a staff without instrument changes keeps its opening channel; an unknown staff has none")
    func channelWithoutSwitches() {
        let opening: [Int: UInt8] = [0: 3]
        #expect(PreviewRouting.channel(forStaff: 0, atTick: 9999, openingChannels: opening, switches: [:]) == 3)
        #expect(PreviewRouting.channel(forStaff: 1, atTick: 0, openingChannels: opening, switches: [:]) == nil)
    }

    private func noteID(measure: Int, element: Int) -> NoteID {
        NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measure, voiceIndex: 0, elementIndex: element, noteIndexInChord: 0,
        )
    }

    private func makeScore(measureCount: Int) -> Score {
        let measures = (0 ..< measureCount).map { index in
            let timeSignature: [VoiceElement] = index == 0
                ? [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                : []
            let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
            return Measure(voices: [Voice(elements: timeSignature + [
                .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
            ])])
        }
        return Score(
            division: 480,
            parts: [Part(
                id: "piano",
                instrument: Instrument(id: "piano", longName: "Piano", channels: [InstrumentChannel(program: 0)]),
                staves: [Staff(measures: measures)],
            )],
            systemMeasures: IdentifiedArray(Array(repeating: SystemMeasure(), count: measureCount)),
        )
    }

    private func makeInstrumentChangeScore(leadingMeasureCount: Int) -> Score {
        let changed = Instrument(id: "accordion", longName: "Accordion", channels: [InstrumentChannel(program: 21)])
        var score = makeScore(measureCount: leadingMeasureCount + 1)
        score.systemMeasures.updateValue(at: leadingMeasureCount) { systemMeasure in
            systemMeasure.elements = [
                PositionedSystemElement(
                    position: MeasurePosition(offset: Fraction(numerator: 0, denominator: 1)),
                    element: .instrumentChange(InstrumentChange(text: "Accordion", instrument: changed)),
                    originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                ),
            ]
        }
        return score
    }
}
