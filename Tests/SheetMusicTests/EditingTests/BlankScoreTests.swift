@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

@Suite("Score.blank")
struct BlankScoreTests {
    private func pianoTemplate(measures: Int = 4) -> BlankScoreTemplate {
        BlankScoreTemplate(
            title: "My Piece", composer: "Me",
            instrumentID: "piano", instrumentName: "Piano",
            staves: [.init(clefType: "G"), .init(clefType: "F")],
            concertKey: 2, timeNumerator: 3, timeDenominator: 4,
            tempoBPM: 90, measureCount: measures,
        )
    }

    @Test("shape: parts, staves, parallel systemMeasures, signatures on every staff")
    func shape() {
        let score = Score.blank(pianoTemplate())
        #expect(score.division == 480)
        #expect(score.parts.count == 1)
        #expect(score.parts[0].staves.count == 2)
        #expect(score.systemMeasures.count == 4)
        for staff in score.parts[0].staves {
            #expect(staff.measures.count == 4)
            let first = staff.measures[0].voices[0].elements
            #expect(first[0] == .keySignature(KeySignature(concertKey: 2)))
            #expect(first[1] == .timeSignature(TimeSignature(numerator: 3, denominator: 4)))
            #expect(first[2].isMeasureRest)
            for measure in staff.measures.dropFirst() {
                #expect(measure.voices[0].elements == [.rest(duration: .measure)])
            }
        }
        #expect(score.parts[0].staves[0].defaultClefType == "G")
        #expect(score.parts[0].staves[1].defaultClefType == "F")
    }

    @Test("tempo lands on systemMeasures[0], grand staff gets a brace")
    func tempoAndBrace() {
        let score = Score.blank(pianoTemplate())
        let tempoElements = score.systemMeasures[0].elements
        #expect(tempoElements.count == 1)
        guard case let .tempo(tempo) = tempoElements[0].element else {
            Issue.record("expected a tempo"); return
        }
        #expect(abs(tempo.beatsPerSecond - 90.0 / 60.0) < 0.0001)
        #expect(score.parts[0].staves[0].brackets == [BracketItem(type: .brace, span: 2)])
        #expect(score.parts[0].staves[1].brackets.isEmpty)
    }

    @Test("metadata: metaTags and title frame")
    func metadata() {
        let score = Score.blank(pianoTemplate())
        #expect(score.metaTags["workTitle"] == "My Piece")
        #expect(score.metaTags["composer"] == "Me")
        let texts = score.titleFrame?.texts ?? []
        #expect(texts.contains(FrameText(style: .title, text: "My Piece")))
        #expect(texts.contains(FrameText(style: .composer, text: "Me")))
    }

    @Test("single-staff template omits brace, nil composer omits composer text")
    func singleStaff() {
        var template = pianoTemplate()
        template.staves = [.init(clefType: "G")]
        template.composer = nil
        let score = Score.blank(template)
        #expect(score.parts[0].staves[0].brackets.isEmpty)
        #expect(score.metaTags["composer"] == nil)
        #expect(!(score.titleFrame?.texts ?? []).contains { $0.style == .composer })
    }

    @Test("round-trips through the mscx encoder semantically")
    func roundTrip() throws {
        let score = Score.blank(pianoTemplate())
        let data = try MSCXEncoder.encode(score)
        let reparsed = try MSCXParser.parse(data)
        // `source` is loader-set metadata (which file format we read), not score content — see
        // `Score.withSource(_:)` in MSCXRoundTripTests.swift, whose doc comment makes the same call for the
        // package's other round-trip suite. `Score.blank(_:)` reports `.unknown` (programmatic construction);
        // re-parsing the encoded bytes necessarily reports `.museScore(.v4)` since mscx carries no such field.
        #expect(reparsed.withSource(.unknown) == score.withSource(.unknown))
    }
}
