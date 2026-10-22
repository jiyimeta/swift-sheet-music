@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

/// A measure repeat travels through ⌘C / ⌘V and `R` the way MuseScore's paste carries one: its group comes back where
/// it lands on a barline over bars as long as its own, misaligned it lands as rests, a group the paste writes into is
/// dissolved first, and only a group the range covers whole travels (`RangeCopyMeasureRepeats.swift`).
@Suite("Measure repeat copy and paste")
struct MeasureRepeatCopyTests {
    private static let drums = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let sign = VoiceElement.measureRepeat(MeasureRepeat(numMeasures: 1, duration: .measure))

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: drums, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func bar(_ score: Score, _ measure: Int) -> Measure {
        score.parts[0].staves[0].measures[measure]
    }

    private static func quarter(_ pitch: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)]))
    }

    /// Six 4/4 bars: four quarters in bar 0 (after its signatures), four quarter rests in bar 2, and measure rests
    /// everywhere else. `repeats` names the bars a one-bar group goes on, and `pair` the first bar of a two-bar one.
    private static func score(repeats: [Int] = [], pair: Int? = nil) throws -> Score {
        var measures: [Measure] = (0 ..< 6).map { _ in Measure(voices: [Voice(elements: [.rest(duration: .measure)])]) }
        measures[0] = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .keySignature(KeySignature(concertKey: 0)),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            quarter(60), quarter(62), quarter(64), quarter(65),
        ])])
        measures[2] = Measure(voices: [Voice(elements: Array(repeating: .rest(duration: .quarter), count: 4))])
        var score = Score(division: 480, parts: [
            Part(
                id: "1", trackName: "Drums", instrument: Instrument(id: "drumset"),
                staves: [Staff(defaultClefType: "G", measures: measures)],
            ),
        ])
        for measure in repeats {
            _ = try SetMeasureRepeat(at: MeasureRef(measureIndex: measure), staff: drums, numMeasures: 1)
                .apply(to: &score)
        }
        if let pair {
            _ = try SetMeasureRepeat(at: MeasureRef(measureIndex: pair), staff: drums, numMeasures: 2)
                .apply(to: &score)
        }
        return score
    }

    /// ⌘C on `range`, through the MSCX bytes a host puts on the pasteboard, then ⌘V at `location`.
    private static func paste(
        _ range: VoiceElementRange, at location: VoiceElementID, in score: inout Score,
    ) throws {
        let document = try #require(score.clipboardDocument(for: range))
        let text = try #require(String(data: MSCXEncoder.encode(document), encoding: .utf8))
        _ = try PasteRange(at: location, payload: text, readPayload: MSCXParser.parse).apply(to: &score)
    }

    private static func holdsSign(_ measure: Measure) -> Bool {
        measure.voices[0].elements.values.contains { if case .measureRepeat = $0 { true } else { false } }
    }

    @Test("a copied sign pastes as a sign on a barline")
    func signPastesAsSign() throws {
        var score = try Self.score(repeats: [1])
        try Self.paste(VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 0)), at: Self.slot(3, 0), in: &score)
        #expect(Self.bar(score, 3).measureRepeatCount == 1)
        #expect(Self.bar(score, 3).voices[0].elements.values == [Self.sign])
    }

    @Test("a range taking in notes and a sign pastes both, the sign on its own bar")
    func rangeWithSignPastesBoth() throws {
        var score = try Self.score(repeats: [1])
        try Self.paste(VoiceElementRange(start: Self.slot(0, 3), end: Self.slot(1, 0)), at: Self.slot(3, 0), in: &score)
        #expect(Self.bar(score, 3).voices[0].elements.values == [
            Self.quarter(60), Self.quarter(62), Self.quarter(64), Self.quarter(65),
        ])
        #expect(Self.bar(score, 3).measureRepeatCount == nil)
        #expect(Self.bar(score, 4).voices[0].elements.values == [Self.sign])
        #expect(Self.bar(score, 4).measureRepeatCount == 1)
    }

    @Test("a sign pasted off the barline lands as rests")
    func misalignedSignLandsAsRests() throws {
        var score = try Self.score(repeats: [1])
        // Bar 2's second quarter rest: the copied bar's length runs from beat 2 of bar 2 to beat 2 of bar 3.
        try Self.paste(VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 0)), at: Self.slot(2, 1), in: &score)
        for measure in [2, 3] {
            #expect(Self.bar(score, measure).measureRepeatCount == nil)
            #expect(!Self.holdsSign(Self.bar(score, measure)))
            let elements = Self.bar(score, measure).voices[0].elements.values
            let allRests = elements.allSatisfy(\.isRest)
            #expect(allRests)
        }
    }

    @Test("a paste over a group dissolves it before writing")
    func pasteOverGroupDissolvesIt() throws {
        var score = try Self.score(repeats: [3])
        try Self.paste(VoiceElementRange(start: Self.slot(0, 3), end: Self.slot(0, 6)), at: Self.slot(3, 0), in: &score)
        #expect(Self.bar(score, 3).measureRepeatCount == nil)
        #expect(Self.bar(score, 3).voices[0].elements.values == [
            Self.quarter(60), Self.quarter(62), Self.quarter(64), Self.quarter(65),
        ])
    }

    @Test("a two-bar group copied whole forms again where it lands")
    func twoBarGroupFormsAgain() throws {
        var score = try Self.score(pair: 3)
        // The sign, then the rest bar 4 holds under it.
        try Self.paste(VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(4, 0)), at: Self.slot(1, 0), in: &score)
        #expect(Self.bar(score, 1).measureRepeatCount == 1)
        #expect(Self.bar(score, 2).measureRepeatCount == 2)
        #expect(Self.bar(score, 1).voices[0].elements.values == [
            .measureRepeat(MeasureRepeat(numMeasures: 2, duration: .measure)),
        ])
    }

    @Test("a two-bar group's sign copied alone lands as a rest")
    func partOfGroupLandsAsRest() throws {
        var score = try Self.score(pair: 3)
        try Self.paste(VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0)), at: Self.slot(1, 0), in: &score)
        #expect(Self.bar(score, 1).measureRepeatCount == nil)
        #expect(Self.bar(score, 1).voices[0].elements.values == [.rest(duration: .measure)])
    }

    @Test("R duplicates a sign as a sign")
    func duplicateCarriesTheSign() throws {
        var score = try Self.score(repeats: [5])
        let session = ScoreEditSession(score: score)
        #expect(session.apply(.duplicateRange(over: VoiceElementRange(start: Self.slot(5, 0), end: Self.slot(5, 0)))))
        score = session.score
        #expect(score.parts[0].staves[0].measures.count == 7)
        #expect(Self.bar(score, 6).measureRepeatCount == 1)
        #expect(Self.bar(score, 6).voices[0].elements.values == [Self.sign])
    }
}
