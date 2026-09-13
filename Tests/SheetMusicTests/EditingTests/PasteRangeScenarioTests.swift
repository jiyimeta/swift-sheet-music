@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

/// The end-to-end scenarios the clipboard spec lists (`2026-09-13-clipboard-copy-paste-design.md` §8): the ones
/// that pin what ⌘C and ⌘V do together, rather than what one pass of the engine does on its own.
///
/// Kept apart from `PasteRangeTests` because each of these builds a whole musical situation — a bar carrying four
/// different kinds at once, two separate documents, a paste that runs off the end of the score — and reads as a
/// story rather than as one assertion about one rule.
@Suite("PasteRange scenarios")
struct PasteRangeScenarioTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func voice(_ score: Score, _ measure: Int) throws -> Voice {
        try #require(score[flute]).measures[measure].voices[0]
    }

    private static func payloadText(_ range: VoiceElementRange, in score: Score) throws -> String {
        let payload = try #require(RangeCopyPayload.score(for: range, in: score))
        return try #require(String(data: MSCXEncoder.encode(payload), encoding: .utf8))
    }

    private static func paste(_ text: String, at location: VoiceElementID) -> PasteRange {
        PasteRange(at: location, payload: text, readPayload: MSCXParser.parse)
    }

    private static func quarter(_ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    // MARK: - §8 test 3 — a bar carrying one of everything, onto a bar that is not empty either

    @Test("a bar's triplet, slur, mid-bar clef and dynamic all land, and the destination's own are dealt with")
    func carriesEveryKindOntoAnOccupiedBar() throws {
        var score = RangeCopyPayloadTests.richFourBarFixture()
        let geometry = RangeCopyGeometry(staff: Self.flute, in: score)
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 2), end: Self.slot(0, 8)), in: score,
        )
        _ = try Self.paste(text, at: Self.slot(2, 1)).apply(to: &score)

        let landed = try Self.voice(score, 2)
        // The mid-bar clef travels (MuseScore's paste reads one, `read460.cpp:704-715`) and stands at the same
        // offset into the bar it stood at in the source.
        #expect(landed.elements.values.contains(.clef(Clef(concertClefType: "F"))))
        // The destination's own dynamic is cleared under the span and the copied one takes its place: exactly
        // one dynamic in the bar, and it is the copy's.
        let dynamics = landed.elements.values.compactMap { element -> String? in
            guard case let .dynamic(dynamic) = element else { return nil }
            return dynamic.subtype
        }
        #expect(dynamics == ["f"])
        // The triplet survives whole — it fits the destination bar, which is the only condition on it.
        #expect(landed.tuplets.count == 1)
        let span = try #require(landed.tupletSpans.first)
        #expect((span.normalNotes, span.actualNotes) == (2, 3))
        #expect(span.endIndex - span.startIndex + 1 == 3)
        // The slur lay wholly inside the range, so it is re-anchored at the destination rather than dropped.
        let slurs = landed.elements.values.compactMap { element -> [Spanner]? in
            guard case let .chord(chord) = element, !chord.spanners.isEmpty else { return nil }
            return chord.spanners
        }
        #expect(slurs.count == 1)
        #expect(slurs.first?.first?.kind == .slur)
        // Nothing changed the bar's length.
        #expect(landed.elements.values.reduce(0) {
            $0 + $1.cursorAdvance(division: 480, in: Fraction(numerator: 4, denominator: 4))
        } == 1920)

        // The hairpin that reached from bar 1 into the pasted span is SHORTENED to the span's near edge, not
        // removed (`edit.cpp:3689-3700`). Bar 2 starts at absolute tick 3840, which is where the paste begins.
        let crossing = try Self.voice(score, 1).elements.values.compactMap { element -> Spanner? in
            guard case let .spanner(spanner) = element else { return nil }
            return spanner
        }
        #expect(crossing.count == 1)
        let hairpin = try #require(crossing.first)
        #expect(RangeCopySpanners.endTick(
            of: hairpin, anchoredAt: ScoreTickPosition(measure: 1, tick: 0), geometry: geometry, division: 480,
        ) == 3840)
    }

    // MARK: - §8 test 2 — the payload is self-contained

    @Test("a payload copied out of one score pastes into a different one")
    func pastesIntoADifferentScore() throws {
        // The whole reason the payload is a `.mscx` DOCUMENT rather than a fragment addressed against the score
        // it came from. Every other paste test pastes back into the score it copied from, which would pass just
        // as well if the payload secretly depended on it.
        let source = RangeCopyPayloadTests.threeBarsOfQuarters()
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)), in: source,
        )

        // A different document: another part id, another instrument, another clef, its own bars.
        var destination = Score(division: 480, parts: [
            Part(
                id: "77", trackName: "Cello", instrument: Instrument(id: "cello"),
                staves: [Staff(defaultClefType: "F", measures: [
                    Measure(voices: [Voice(elements: [
                        .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                        .rest(duration: .measure),
                    ])]),
                    Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
                ])],
            ),
        ])
        let before = destination
        let target = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        _ = try Self.paste(text, at: VoiceElementID(
            staff: target, measureIndex: 1, voiceIndex: 0, elementIndex: 0,
        )).apply(to: &destination)

        #expect(try #require(destination[target]).measures[1].voices[0].elements == [
            Self.quarter(60, 14), Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 13),
        ])
        // And the source score never took part: nothing about it was consulted at paste time.
        #expect(destination != before)
        #expect(try #require(destination[target]).measures.count == 2)
    }

    // MARK: - §8 test 4 — a paste longer than what is left of the score

    @Test("a paste that runs past the last bar appends the bars it needs")
    func appendsMeasuresPastTheEnd() throws {
        var score = RangeCopyPayloadTests.threeBarsOfQuarters()
        // Two whole bars copied, landed on the LAST bar — one bar of room for two bars of material.
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(1, 3)), in: score,
        )
        _ = try Self.paste(text, at: Self.slot(2, 0)).apply(to: &score)

        #expect(try #require(score[Self.flute]).measures.count == 4)
        #expect(try Self.voice(score, 2).elements == [
            Self.quarter(60, 14), Self.quarter(62, 16), Self.quarter(64, 18), Self.quarter(65, 13),
        ])
        #expect(try Self.voice(score, 3).elements == [
            Self.quarter(67, 15), Self.quarter(69, 17), Self.quarter(71, 19), Self.quarter(72, 14),
        ])
    }

    @Test("undoing a paste that appended bars takes the bars away again")
    func undoRemovesTheAppendedMeasures() throws {
        var score = RangeCopyPayloadTests.threeBarsOfQuarters()
        let before = score
        let text = try Self.payloadText(
            VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(1, 3)), in: score,
        )
        let inverse = try Self.paste(text, at: Self.slot(2, 0)).apply(to: &score)
        #expect(try #require(score[Self.flute]).measures.count == 4)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }
}
