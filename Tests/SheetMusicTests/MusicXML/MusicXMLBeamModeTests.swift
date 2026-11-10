import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// A note's `<beam>`s set its chord's `beamMode` as MuseScore's import sets it (`computeBeamMode`,
/// `findOrCreateChord`, `handleBeamAndStemDir`), and a rest's as `MusicXmlParserPass2::note` does. The import used to
/// read no `<beam>`, so every chord was `auto` and the layout regrouped every beam by the meter.
@Suite("MusicXML beam modes")
struct MusicXMLBeamModeTests {
    private typealias F = DirectionFixtures

    /// A note of `type` lasting `duration` ticks, with one `<beam>` per entry of `beams`, level 1 first.
    private static func note(
        _ step: String, type: String = "eighth", duration: Int = 240, voice: Int = 1, beams: [String] = [],
        stem: String? = nil,
    ) -> String {
        let stemTag = stem.map { "<stem>\($0)</stem>" } ?? ""
        let beamTags = beams.enumerated().map { "<beam number=\"\($0.offset + 1)\">\($0.element)</beam>" }.joined()
        return F.note(step, duration: duration, type: type, voice: voice, extra: stemTag + beamTags)
    }

    private static func sixteenth(_ step: String, _ beams: String...) -> String {
        note(step, type: "16th", duration: 120, beams: beams)
    }

    private static func thirtySecond(_ step: String, _ beams: String...) -> String {
        note(step, type: "32nd", duration: 60, beams: beams)
    }

    private static func eighthRest(voice: Int = 1) -> String {
        "<note><rest/><duration>240</duration><voice>\(voice)</voice><type>eighth</type></note>"
    }

    private static func backup(_ duration: Int) -> String {
        "<backup><duration>\(duration)</duration></backup>"
    }

    /// The beam mode of each chord and rest in the voice, in order.
    private static func modes(_ score: Score, measure: Int = 0, voice: Int = 0) -> [BeamMode] {
        chords(score, measure: measure, voice: voice).map(\.beamMode)
    }

    private static func chords(_ score: Score, measure: Int = 0, voice: Int = 0) -> [Chord] {
        F.voice(score, measure: measure, voice: voice).elements.values.compactMap { element in
            if case let .chord(chord) = element { chord } else { nil }
        }
    }

    @Test("begin, continue and end make begin, mid and auto — the end is not forced")
    func beginContinueEnd() throws {
        let score = try F.score(measures: [
            Self.note("C", beams: ["begin"]) + Self.note("D", beams: ["continue"])
                + Self.note("E", beams: ["continue"]) + Self.note("F", beams: ["end"]) + F.half("G"),
        ])
        #expect(Self.modes(score) == [.begin, .mid, .mid, .auto, .auto])
    }

    @Test("in a file with beams, an eighth no beam holds is unbeamed and a quarter is left to the meter")
    func unbeamedWithBeamingInfo() throws {
        let score = try F.score(measures: [
            Self.note("C") + Self.note("D", beams: ["begin"]) + Self.note("E", beams: ["end"]) + Self.note("F")
                + F.quarter("G") + F.quarter("A"),
        ])
        #expect(Self.modes(score) == [.none, .begin, .auto, .none, .auto, .auto])
    }

    @Test("in a file with no beaming information, every note is left to the meter")
    func unbeamedWithoutBeamingInfo() throws {
        let score = try F.score(measures: [
            Self.note("C") + Self.note("D") + Self.note("E") + Self.note("F") + F.half("G"),
        ])
        #expect(Self.modes(score) == [.auto, .auto, .auto, .auto, .auto])
    }

    @Test("<supports element=\"beam\" type=\"yes\"> is beaming information, with no <beam> in the file")
    func supportsBeamIsBeamingInfo() throws {
        let plain = try #require(String(bytes: F.data(parts: [(
            [Self.note("C") + Self.note("D") + Self.note("E") + Self.note("F") + F.half("G")], 1,
        )]), encoding: .utf8))
        let supports = "<identification><encoding><supports element=\"beam\" type=\"yes\"/></encoding>"
            + "</identification><part-list>"
        let score = try MusicXMLParser.parse(Data(plain.replacingOccurrences(of: "<part-list>", with: supports).utf8))
        #expect(Self.modes(score) == [.none, .none, .none, .none, .auto])
    }

    @Test("a beam a note with no <beam> breaks off, or a begin before its end, leaves its notes unbeamed")
    func abortedBeamUnbeamsItsNotes() throws {
        let score = try F.score(measures: [
            Self.note("C", beams: ["begin"]) + Self.note("D", beams: ["continue"]) + Self.note("E")
                + Self.note("F", beams: ["begin"]) + Self.note("G", beams: ["begin"]) + Self.note("A", beams: ["end"])
                + F.quarter("B"),
        ])
        #expect(Self.modes(score) == [.none, .none, .none, .none, .begin, .auto, .auto])
    }

    @Test("a rest inside a beam is mid; one outside a beam, or in a beam that breaks off, keeps its default")
    func restInsideABeam() throws {
        let score = try F.score(measures: [
            Self.note("C", beams: ["begin"]) + Self.eighthRest() + Self.note("D", beams: ["continue"])
                + Self.note("E", beams: ["end"]) + Self.eighthRest() + Self.note("F", beams: ["begin"])
                + Self.eighthRest() + Self.note("G"),
        ])
        #expect(Self.modes(score) == [.begin, .mid, .mid, .auto, .auto, .none, .auto, .none])
    }

    @Test("a beam restarting its second level is begin16, its third begin32; a note hooked at level 1 joins none")
    func multiLevelBeams() throws {
        let score = try F.score(measures: [
            Self.sixteenth("C", "begin", "begin") + Self.sixteenth("D", "continue", "end")
                + Self.sixteenth("E", "continue", "begin") + Self.sixteenth("F", "end", "end")
                + Self.thirtySecond("G", "begin", "begin", "begin")
                + Self.thirtySecond("A", "continue", "continue", "end")
                + Self.thirtySecond("B", "continue", "continue", "begin")
                + Self.thirtySecond("C", "end", "end", "end")
                + Self.sixteenth("D", "begin", "begin") + Self.sixteenth("E", "end", "backward hook")
                + Self.sixteenth("F", "forward hook") + Self.sixteenth("G", "backward hook")
                + F.quarter("A") + Self.note("B"),
        ])
        #expect(Self.modes(score) == [
            .begin, .mid, .begin16, .auto,
            .begin, .mid, .begin32, .auto,
            .begin, .auto,
            .none, .none,
            .auto, .none,
        ])
    }

    @Test("each voice keeps its own beam: another voice's notes neither join nor break it")
    func perVoiceBeams() throws {
        let score = try F.score(measures: [
            Self.note("C", beams: ["begin"]) + Self.note("D", beams: ["continue"]) + Self.backup(480)
                + Self.note("G", voice: 2, beams: ["begin"]) + Self.note("A", voice: 2, beams: ["end"])
                + Self.note("B", voice: 2) + Self.backup(240)
                + Self.note("E", beams: ["continue"]) + Self.note("F", beams: ["end"]) + F.half("G"),
        ])
        #expect(Self.modes(score, voice: 0) == [.begin, .mid, .mid, .auto, .auto])
        #expect(Self.modes(score, voice: 1) == [.begin, .auto, .none])
    }

    @Test("a beam still open at the bar line is dropped with its direction, and does not carry into the next bar")
    func noCarryAcrossTheBarLine() throws {
        let score = try F.score(measures: [
            F.half("C") + F.quarter("D") + Self.note("E", beams: ["begin"], stem: "down")
                + Self.note("F", beams: ["continue"], stem: "down"),
            Self.note("G", beams: ["continue"]) + Self.note("A", beams: ["end"]) + F.half("B") + F.quarter("C"),
        ])
        #expect(Self.modes(score, measure: 0) == [.auto, .auto, .none, .none])
        #expect(Self.chords(score, measure: 0).map(\.beamStemDirection) == [nil, nil, nil, nil])
        #expect(Self.chords(score, measure: 0).map(\.stemDirection) == [nil, nil, nil, nil])
        #expect(Self.modes(score, measure: 1) == [.none, .none, .auto, .auto])
    }
}
