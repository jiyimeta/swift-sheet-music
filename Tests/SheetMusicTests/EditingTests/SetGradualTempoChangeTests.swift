import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `SetGradualTempoChange` over three bars of a 4/4 score at ♩ = 80: the line it writes and its undo, the label it
/// draws, the tempo map's ramp across it, and its MSCX form. The placement and refusals it shares with every line
/// spanner are `LineSpannerCommandTests`' row.
@Suite("SetGradualTempoChange")
struct SetGradualTempoChangeTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let eighty = 80.0 / 60

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    /// Bar 0's first rest (element 1, after the meter) through bar 2's last rest: three whole bars.
    private static let threeBars = VoiceElementRange(start: slot(0, 1), end: slot(2, 3))

    /// Four bars of quarter rests, bar 0 opening with its 4/4, at ♩ = 80.
    private static func score() -> Score {
        TempoMapFixtures.score(measures: 4, lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: eighty))])
    }

    /// The element the command inserted: bar 0, right after the meter, ahead of the first rest.
    private static func line(in score: Score) throws -> Spanner {
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        try #require(elements.count == 6, "exactly one element inserted")
        let spanner: Spanner? = switch elements[1] {
        case let .spanner(found): found
        default: nil
        }
        return try #require(spanner)
    }

    /// Every begin side on the staff, in score order.
    private static func beginSides(in score: Score) -> [Spanner] {
        score.parts[0].staves[0].measures.flatMap { measure in
            measure.voices.flatMap(\.elements.values).compactMap { element -> Spanner? in
                guard case let .spanner(spanner) = element, !spanner.isEndMarker else { return nil }
                return spanner
            }
        }
    }

    @Test("over three bars: one rit. before the first rest, ending on bar 3's downbeat; undo is exact")
    func writesThreeBarsAndUndoes() throws {
        var score = Self.score()
        let before = score
        let inverse = try SetGradualTempoChange(over: Self.threeBars, type: .ritardando, factor: 0.5)
            .apply(to: &score)
        let line = try Self.line(in: score)
        #expect(line.kind == .gradualTempoChange)
        #expect(line.rawType == "GradualTempoChange")
        #expect(line.gradualTempoChange == Spanner.GradualTempoChangePayload(type: .ritardando, factor: 0.5))
        #expect(line.beginText == "rit.")
        #expect(line.continueText == "(rit.)")
        #expect(line.endText == nil)
        #expect(!line.isEndMarker)
        // The last rest ends on bar 2's bar line, which MuseScore's `<next>` writer files under bar 3 at offset 0.
        #expect(line.nextMeasuresOffset == 3)
        #expect(line.nextFractionsOffset == nil)
        #expect(score.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
        _ = try inverse.apply(to: &score)
        #expect(score == before, "undo is exact")
    }

    @Test("no factor keeps the type's default; the label is the palette's; an undefined change has none")
    func defaultFactorAndLabels() throws {
        var score = Self.score()
        _ = try SetGradualTempoChange(over: Self.threeBars, type: .accelerando).apply(to: &score)
        let accel = try Self.line(in: score)
        #expect(accel.gradualTempoChange?.factor == nil)
        #expect(accel.gradualTempoChange?.effectiveFactor == 1.33)
        #expect(accel.lineLabels.begin == "accel.")
        #expect(accel.lineLabels.continuation == "(accel.)")
        #expect(accel.lineLabels.end == nil)

        var bare = Self.score()
        _ = try SetGradualTempoChange(over: Self.threeBars, type: .undefined).apply(to: &bare)
        let undefined = try Self.line(in: bare)
        #expect(undefined.beginText == nil)
        #expect(undefined.continueText == nil)
        #expect(undefined.lineLabels.begin == nil)
    }

    @Test("the tempo map ramps from ♩ = 80 to 80 × factor across the three bars, and no further")
    func rampsAcrossTheSpan() throws {
        var score = Self.score()
        _ = try SetGradualTempoChange(over: Self.threeBars, type: .ritardando, factor: 0.5).apply(to: &score)
        let map = score.resolvedTempoMap()
        let start = try #require(map.point(inForceAtMeasure: 0, tickInMeasure: 0))
        #expect(start.role == .marking)
        #expect(abs(start.beatsPerSecond - Self.eighty) < 1e-9)
        // 5760 ticks in max(8, 5760 / 480) = 12 steps of 480; the step at offset 0 stands on the marking and is not
        // written, so twelve remain, the last on bar 3's downbeat.
        let steps = map.points.filter { $0.role == .ramp }
        try #require(steps.count == 12)
        let speeds = steps.map(\.beatsPerSecond)
        #expect(zip(speeds.dropFirst(), speeds).allSatisfy { $0 < $1 }, "falls at every step")
        let last = try #require(steps.last)
        #expect(last.measureIndex == 3)
        #expect(last.tickInMeasure == 0)
        #expect(abs(last.beatsPerSecond - Self.eighty * 0.5) < 1e-6)
        let barEnd = try #require(map.point(inForceAtMeasure: 3, tickInMeasure: 1919))
        #expect(barEnd.role == .ramp)
        #expect(barEnd.beatsPerSecond == last.beatsPerSecond)
    }

    @Test("MSCX writes a <GradualTempoChange> with its type and factor, and reads it back")
    func encodesAsMSCX() throws {
        var score = Self.score()
        _ = try SetGradualTempoChange(over: Self.threeBars, type: .ritardando, factor: 0.5).apply(to: &score)
        let written = try Self.line(in: score)
        let payload = try #require(written.encode().first("GradualTempoChange"))
        // `TWrite::write(const GradualTempoChange*)`'s order: type, factor, then the line texts.
        #expect(payload.children.map(\.name) == ["tempoChangeType", "tempoChangeFactor", "beginText", "continueText"])
        #expect(payload.first("tempoChangeType")?.text == "ritardando")
        #expect(payload.first("tempoChangeFactor")?.text == "0.5")

        let data = try MSCXEncoder.encode(score)
        let xml = try #require(String(bytes: data, encoding: .utf8))
        for fragment in [
            "<Spanner type=\"GradualTempoChange\">", "<tempoChangeType>ritardando</tempoChangeType>",
            "<tempoChangeFactor>0.5</tempoChangeFactor>", "<beginText>rit.</beginText>",
            "<continueText>(rit.)</continueText>", "<measures>3</measures>",
        ] {
            #expect(xml.contains(fragment), "missing \(fragment)")
        }
        let reread = try #require(Self.beginSides(in: MSCXParser.parse(data)).first)
        #expect(reread.kind == .gradualTempoChange)
        #expect(reread.gradualTempoChange == written.gradualTempoChange)
        #expect(reread.beginText == "rit.")
        #expect(reread.continueText == "(rit.)")
        #expect(reread.nextMeasuresOffset == 3)
        #expect(reread.nextFractionsOffset == nil)
    }
}
