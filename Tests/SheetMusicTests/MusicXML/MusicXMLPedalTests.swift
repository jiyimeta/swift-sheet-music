import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// Pedal shapes and the MuseScore probe of 2026-10-15: start / change / stop with `line="yes"` give a pedal ending in a
/// 45° hook, a pedal from a 45° hook to a 90° hook, and the stop's 90° hook.
@Suite("MusicXML pedals")
struct MusicXMLPedalTests {
    private typealias F = DirectionFixtures

    private static func pedal(_ attributes: String) -> String {
        F.direction("<pedal \(attributes)/>")
    }

    private static func begins(_ voice: Voice) -> [(tick: Int, spanner: Spanner)] {
        F.spanners(in: voice).filter { !$0.spanner.isEndMarker }
    }

    @Test("start, change and stop reproduce MuseScore's three pedal payloads")
    func startChangeStop() throws {
        let score = try F.score(measures: [
            F.quarter("C") + F.quarter("D") + F.quarter("E")
                + Self.pedal("type=\"start\" line=\"yes\" sign=\"yes\"") + F.quarter("F"),
            Self.pedal("type=\"change\" line=\"yes\"") + F.half("C") + F.half("C"),
            F.half("C") + Self.pedal("type=\"stop\" line=\"yes\"") + F.half("C"),
        ])
        let first = try #require(Self.begins(F.voice(score, measure: 0)).first)
        #expect(first.tick == 1440)
        #expect(first.spanner.kind == .pedal)
        #expect(first.spanner.rawType == "Pedal")
        #expect(first.spanner.nextMeasuresOffset == 1)
        #expect(first.spanner.nextFractionsOffset == Fraction(numerator: -3, denominator: 4))
        #expect(first.spanner.lineProperties?.endHook == .hook45)
        #expect(first.spanner.lineProperties?.beginHook == nil)
        #expect(first.spanner.lineProperties?.lineVisible == nil)

        let atBarStart = F.spanners(in: F.voice(score, measure: 1))
        #expect(atBarStart.map(\.tick) == [0, 0])
        #expect(atBarStart.map(\.spanner.isEndMarker) == [true, false])
        try #require(atBarStart.count == 2)
        let second = atBarStart[1].spanner
        #expect(second.lineProperties?.beginHook == .hook45)
        #expect(second.lineProperties?.endHook == .hook90)
        #expect(second.nextMeasuresOffset == 1)
        #expect(second.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
        let begin = (second.lineLabels.begin ?? "")
        #expect(begin.isEmpty)
        #expect(F.spanners(in: F.voice(score, measure: 2)).map(\.tick) == [960])
    }

    @Test("line=\"no\" is lineVisible false, and its end text is the pedal-up sign")
    func lineNo() throws {
        let body = Self.pedal("type=\"start\" line=\"no\" sign=\"yes\"") + F.half("C") + F.half("D")
            + Self.pedal("type=\"stop\" line=\"no\"")
        let spanner = try #require(try Self.begins(F.voice(F.score(measures: [body]))).first).spanner
        #expect(spanner.lineProperties?.lineVisible == false)
        #expect(spanner.lineLabels.end == "<sym>keyboardPedalUp</sym>")
        #expect(spanner.lineLabels.begin == "<sym>keyboardPedalPed</sym>")
    }

    @Test("sign=\"no\" with a drawn line gives 90° hooks")
    func hooks() throws {
        let body = Self.pedal("type=\"start\" line=\"yes\" sign=\"no\"") + F.half("C") + F.half("D")
            + Self.pedal("type=\"stop\" line=\"yes\" sign=\"no\"")
        let spanner = try #require(try Self.begins(F.voice(F.score(measures: [body]))).first).spanner
        #expect(spanner.lineProperties?.beginHook == .hook90)
        #expect(spanner.lineProperties?.endHook == .hook90)
    }

    @Test("sostenuto carries its own signs")
    func sostenuto() throws {
        let body = Self.pedal("type=\"sostenuto\" line=\"no\"") + F.half("C") + F.half("D")
            + Self.pedal("type=\"stop\" line=\"no\"")
        let spanner = try #require(try Self.begins(F.voice(F.score(measures: [body]))).first).spanner
        #expect(spanner.beginText == "<sym>keyboardPedalSost</sym>")
    }

    @Test("a start while another pedal is open drops the old one")
    func startWhileOpen() throws {
        let body = Self.pedal("type=\"start\" line=\"yes\"") + F.half("C")
            + Self.pedal("type=\"start\" line=\"yes\"") + F.half("D")
            + Self.pedal("type=\"stop\" line=\"yes\"")
        let found = try Self.begins(F.voice(F.score(measures: [body])))
        #expect(found.map(\.tick) == [960])
    }

    @Test("a pedal with no stop is dropped")
    func unterminated() throws {
        let body = Self.pedal("type=\"start\" line=\"yes\"") + F.fourQuarters
        #expect(try F.spanners(in: F.voice(F.score(measures: [body]))).isEmpty)
    }
}
