import Foundation
@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

@Suite("showCourtesySig")
struct SignatureCourtesyFlagTests {
    private func pianoTemplate(measures: Int) -> BlankScoreTemplate {
        BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
            measureCount: measures,
        )
    }

    @Test("courtesy defaults to shown on both signature kinds")
    func defaultsToTrue() {
        #expect(KeySignature(concertKey: 2).showCourtesy)
        #expect(TimeSignature(numerator: 3, denominator: 4).showCourtesy)
    }

    @Test("a suppressed courtesy survives an mscx round trip")
    func showCourtesySigRoundTripsThroughMSCX() throws {
        var score = Score.blank(pianoTemplate(measures: 2))
        // A mid-piece key change with courtesy suppressed, at the head of measure 1.
        var key = KeySignature(concertKey: 3)
        key.showCourtesy = false
        score.parts[0].staves[0].measures[1].voices[0].elements.insert(.keySignature(key), at: 0)
        MeasureStructure.shiftTuplets(in: &score.parts[0].staves[0].measures[1].voices[0], by: 1)
        let xml = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(xml.contains("<showCourtesySig>0</showCourtesySig>"))
        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(score))
        guard case let .keySignature(decoded) = reparsed.parts[0].staves[0].measures[1].voices[0].elements[0]
        else { Issue.record("no key sig"); return }
        #expect(decoded.showCourtesy == false)
        #expect(decoded.concertKey == 3)
    }

    @Test("a suppressed courtesy survives an mscx round trip on a time signature")
    func timeSignatureCourtesyRoundTripsThroughMSCX() throws {
        var score = Score.blank(pianoTemplate(measures: 2))
        var time = TimeSignature(numerator: 6, denominator: 8)
        time.showCourtesy = false
        score.parts[0].staves[0].measures[1].voices[0].elements.insert(.timeSignature(time), at: 0)
        MeasureStructure.shiftTuplets(in: &score.parts[0].staves[0].measures[1].voices[0], by: 1)
        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(score))
        guard case let .timeSignature(decoded) = reparsed.parts[0].staves[0].measures[1].voices[0].elements[0]
        else { Issue.record("no time sig"); return }
        #expect(decoded.showCourtesy == false)
        #expect(decoded.numerator == 6)
        #expect(decoded.denominator == 8)
    }

    @Test("the default emits no tag, keeping MuseScore-written files byte-stable")
    func defaultTrueEmitsNoTag() throws {
        let score = Score.blank(pianoTemplate(measures: 1))
        let xml = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(!xml.contains("showCourtesySig"))
    }
}
