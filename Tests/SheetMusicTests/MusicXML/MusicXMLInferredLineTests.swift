import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// Lines MuseScore infers from words, and where it ends them (`terminateInferredLine`, `P2:3402-3418`).
@Suite("MusicXML inferred lines")
struct MusicXMLInferredLineTests {
    private typealias F = DirectionFixtures

    private static func fermata(_ step: String) -> String {
        F.quarter(step, extra: "<notations><fermata type=\"upright\"/></notations>")
    }

    private static func begin(_ voice: Voice) -> Spanner? {
        F.spanners(in: voice).first { !$0.spanner.isEndMarker }?.spanner
    }

    @Test("cresc. words are a hairpin line ended by the next dynamic")
    func crescEndedByADynamic() throws {
        let body = F.direction(F.words("cresc."), attributes: "placement=\"below\"") + F.quarter("C") + F.quarter("D")
            + F.direction("<dynamics><f/></dynamics>") + F.quarter("E") + F.quarter("F")
        let score = try F.score(measures: [body])
        let voice = F.voice(score)
        let spanner = try #require(Self.begin(voice))
        #expect(spanner.kind == .hairpin)
        #expect(spanner.hairpin?.subtype == .crescLine)
        #expect(spanner.beginText == nil)
        #expect(spanner.lineProperties?.lineVisible == false)
        #expect(spanner.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
        #expect(F.spanners(in: voice).map(\.tick) == [0, 960])
        #expect(F.lane(score).isEmpty)
    }

    @Test("custom cresc. text is kept as the begin text")
    func customText() throws {
        let body = F.direction(F.words("poco a poco cresc.")) + F.fourQuarters
            + F.direction("<dynamics><f/></dynamics>")
        let spanner = try #require(try Self.begin(F.voice(F.score(measures: [body]))))
        #expect(spanner.beginText == "poco a poco cresc.")
    }

    @Test("dim. words are the diminuendo line")
    func dimWords() throws {
        let body = F.direction(F.words("dim.")) + F.fourQuarters + F.direction("<dynamics><p/></dynamics>")
        let spanner = try #require(try Self.begin(F.voice(F.score(measures: [body]))))
        #expect(spanner.hairpin?.subtype == .dimLine)
    }

    @Test("rit. is a gradual tempo change ended by a fermata two bars later (testTempoLineFermata)")
    func ritEndedByAFermata() throws {
        let score = try F.score(measures: [
            F.direction(F.words("rit.")) + F.fourQuarters, F.fourQuarters,
            Self.fermata("B") + F.quarter("C") + F.half("D"),
        ])
        let spanner = try #require(Self.begin(F.voice(score)))
        #expect(spanner.kind == .gradualTempoChange)
        #expect(spanner.rawType == "GradualTempoChange")
        #expect(spanner.gradualTempoChange?.type == .ritardando)
        #expect(spanner.beginText == "rit.")
        #expect(spanner.nextMeasuresOffset == 2)
        #expect(spanner.nextFractionsOffset == nil)
    }

    @Test("a tempo text ends a tempo line")
    func tempoTextEndsIt() throws {
        let score = try F.score(measures: [
            F.direction(F.words("rit.")) + F.fourQuarters,
            F.direction(F.words("a tempo"), "<sound tempo=\"90\"/>") + F.fourQuarters,
        ])
        #expect(Self.begin(F.voice(score))?.nextMeasuresOffset == 1)
    }

    @Test("a terminator more than 24 quarters away leaves the line zero-length")
    func tooFar() throws {
        var bars = [F.direction(F.words("cresc.")) + F.fourQuarters]
        bars += Array(repeating: F.fourQuarters, count: 6)
        bars.append(F.direction("<dynamics><f/></dynamics>") + F.fourQuarters)
        let spanner = try #require(try Self.begin(F.voice(F.score(measures: bars))))
        #expect(spanner.nextMeasuresOffset == 0)
        #expect(spanner.nextFractionsOffset == nil)
    }

    @Test("with no terminator at all the line is kept, zero-length (probe 2026-10-15)")
    func unterminatedStaysZeroLength() throws {
        let body = F.direction(F.words("rit.")) + F.fourQuarters
        let voice = try F.voice(F.score(measures: [body]))
        let found = F.spanners(in: voice)
        #expect(found.count == 2)
        #expect(found.map(\.tick) == [0, 0])
        #expect(found.last?.spanner.isEndMarker == true)
    }

    @Test("an inferred tempo line has no continue text: GradualTempoChange's default is \"\", so the file omits it")
    func tempoLineHasNoContinueText() throws {
        let score = try F.score(measures: [
            F.direction(F.words("rit.")) + F.fourQuarters,
            F.direction(F.words("a tempo"), "<sound tempo=\"90\"/>") + F.fourQuarters,
        ])
        let spanner = try #require(Self.begin(F.voice(score)))
        #expect(spanner.kind == .gradualTempoChange)
        #expect(spanner.continueText == nil)
    }

    /// An inferred hairpin line's `<direction>` (`addInferredHairpin`, `P2:4575-4579`): the placement attribute
    /// only — `default-y` is not consulted — else above on a vocal staff, below on any other.
    private static func crescSide(_ attributes: String, wordsAttributes: String = "", partName: String? = nil)
        throws -> [PreservedXML]
    {
        let body = F.direction(F.words("cresc.", attributes: wordsAttributes), attributes: attributes)
            + F.quarter("C") + F.quarter("D") + F.direction("<dynamics><f/></dynamics>") + F.half("E")
        let spanner = try #require(try Self.begin(F.voice(F.score(measures: [body], partName: partName))))
        return spanner.payloadMarkup
    }

    @Test("an inferred cresc. line's side is its placement attribute, else the staff's default")
    func crescLineSide() throws {
        let down = [PreservedXML(name: "direction", text: "down")]
        let up = [PreservedXML(name: "direction", text: "up")]
        #expect(try Self.crescSide("placement=\"above\"") == up)
        #expect(try Self.crescSide("placement=\"below\"", partName: "Alto") == down)
        #expect(try Self.crescSide("", wordsAttributes: "default-y=\"20\"") == down)
        #expect(try Self.crescSide("", partName: "Alto") == up)
    }
}
