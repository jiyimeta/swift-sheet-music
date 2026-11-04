import Foundation
@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

/// The breath after a range's LAST chord is part of what the range copies. A breath stands right after the chord it
/// follows, on that chord's end tick, so for the last chord it stands on the range's own end tick.
///
/// MuseScore ends a range at the segment after its last chord — the next ChordRest, Clef or EndBarLine segment
/// (`Score::selectRange`, `dom/score.cpp:3496, 3598-3599`) — and writes the clipboard up to, not including, that
/// segment (`TWrite::writeSegments`, `rw/write/twrite.cpp:3501`). A Breath segment sorts ahead of all three at its tick
/// (`dom/segment.h:41-66`), so it is written; at a bar's end it lives in that bar, ahead of the end barline
/// (`editing/edit.cpp:7319-7324`), and is written there too. The paste puts it back in the bar it closes
/// (`rw/read460/read460.cpp:716-728`), replacing the destination's breath at that tick. The breath at the range's
/// START tick closes the chord BEFORE the range and stays behind — `DuplicateRangeCarriedElementsTests` guards that
/// for `R`, and this suite for the clipboard.
@Suite("Range copy — the breath after the last chord")
struct RangeCopyEndBreathTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let comma = VoiceElement.breath(Breath(kind: .breathMark(.comma), pause: 0))
    private static let tick = VoiceElement.breath(Breath(kind: .breathMark(.tick), pause: 0))

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func range(_ start: VoiceElementID, _ end: VoiceElementID) -> VoiceElementRange {
        VoiceElementRange(start: start, end: end)
    }

    private static func quarter(_ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    private static let c4 = quarter(60, 14)
    private static let d4 = quarter(62, 16)
    private static let e4 = quarter(64, 18)
    private static let f4 = quarter(65, 13)
    private static let g4 = quarter(67, 15)
    private static let a4 = quarter(69, 17)
    private static let b4 = quarter(71, 19)
    private static let c5 = quarter(72, 14)

    /// One 4/4 bar per argument, each one voice.
    private static func score(_ bars: [VoiceElement]...) -> Score {
        Score(division: 480, parts: [
            Part(
                id: "1", trackName: "Flute", instrument: Instrument(id: "flute"),
                staves: [Staff(defaultClefType: "G", measures: bars.map { Measure(voices: [Voice(elements: $0)]) })],
            ),
        ])
    }

    private static func elements(_ score: Score, _ measure: Int) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[0].elements.values
    }

    /// The ⌘C half of the host recipe: the clipboard document for `range`, encoded the way a host encodes it.
    private static func copy(_ range: VoiceElementRange, in score: Score) throws -> String {
        let document = try #require(score.clipboardDocument(for: range))
        return try #require(String(data: MSCXEncoder.encode(document), encoding: .utf8))
    }

    /// The ⌘V half: the document pasted at `location` through the reader a host wires in.
    private static func paste(_ text: String, at location: VoiceElementID, into score: inout Score) throws {
        _ = try PasteRange(at: location, payload: text, readPayload: MSCXParser.parse).apply(to: &score)
    }

    // MARK: - R

    @Test("R carries the breath after the range's last chord")
    func duplicateCarriesTheEndBreath() throws {
        var score = Self.score([Self.c4, Self.d4, Self.comma, Self.e4, Self.f4])
        _ = try DuplicateRange(over: Self.range(Self.slot(0, 0), Self.slot(0, 1))).apply(to: &score)
        // The comma closing the source's D stays where it was: the copy lands on the tick it stands on, and a
        // breath there is not something the copy brings.
        #expect(Self.elements(score, 0) == [Self.c4, Self.d4, Self.comma, Self.c4, Self.d4, Self.comma])
    }

    @Test("R of a bar ending on a breath carries it to the copy's bar end, replacing the breath already there")
    func duplicateCarriesTheBarEndBreath() throws {
        var score = Self.score(
            [Self.c4, Self.d4, Self.e4, Self.f4, Self.comma],
            [Self.g4, Self.a4, Self.b4, Self.c5, Self.tick],
        )
        _ = try DuplicateRange(over: Self.range(Self.slot(0, 0), Self.slot(0, 3))).apply(to: &score)
        // One breath at the bar's end, the copied one: MuseScore's paste writes it through `undoChangeElement`.
        #expect(Self.elements(score, 1) == [Self.c4, Self.d4, Self.e4, Self.f4, Self.comma])
        #expect(score.parts[0].staves[0].measures.count == 2)
    }

    @Test("R of the score's last bar ending on a breath appends one bar and closes it with the breath")
    func duplicateCarriesTheBreathEndingTheScore() throws {
        var score = Self.score([Self.c4, Self.d4, Self.e4, Self.f4, Self.comma])
        _ = try DuplicateRange(over: Self.range(Self.slot(0, 0), Self.slot(0, 3))).apply(to: &score)
        #expect(score.parts[0].staves[0].measures.count == 2)
        #expect(Self.elements(score, 1) == [Self.c4, Self.d4, Self.e4, Self.f4, Self.comma])
    }

    // MARK: - ⌘C / ⌘V

    @Test("a pasted copy carries the breath after its last chord, replacing the destination's breath at that tick")
    func pasteCarriesTheEndBreath() throws {
        var score = Self.score(
            [Self.c4, Self.d4, Self.comma, Self.e4, Self.f4],
            [Self.g4, Self.a4, Self.tick, Self.b4, Self.c5],
        )
        let text = try Self.copy(Self.range(Self.slot(0, 0), Self.slot(0, 1)), in: score)
        try Self.paste(text, at: Self.slot(1, 0), into: &score)
        #expect(Self.elements(score, 1) == [Self.c4, Self.d4, Self.comma, Self.b4, Self.c5])
    }

    @Test("a copy does not carry the breath of a chord after the range")
    func pasteLeavesTheBreathOfTheNextChord() throws {
        // The comma closes E, which the range does not cover. The clipboard document trims E away, and the comma
        // must go with it rather than slide onto the copy's end tick, where it would read as D's own.
        var score = Self.score(
            [Self.c4, Self.d4, Self.e4, Self.comma, Self.f4],
            [Self.g4, Self.a4, Self.b4, Self.c5],
        )
        let text = try Self.copy(Self.range(Self.slot(0, 0), Self.slot(0, 1)), in: score)
        try Self.paste(text, at: Self.slot(1, 0), into: &score)
        #expect(Self.elements(score, 1) == [Self.c4, Self.d4, Self.b4, Self.c5])
    }

    @Test("a copy does not carry the breath standing on its first tick")
    func pasteLeavesTheStartBreath() throws {
        // The comma closes C, the chord before the range.
        var score = Self.score(
            [Self.c4, Self.comma, Self.d4, Self.e4, Self.f4],
            [Self.g4, Self.a4, Self.b4, Self.c5],
        )
        let text = try Self.copy(Self.range(Self.slot(0, 2), Self.slot(0, 4)), in: score)
        try Self.paste(text, at: Self.slot(1, 0), into: &score)
        #expect(Self.elements(score, 1) == [Self.d4, Self.e4, Self.f4, Self.c5])
    }

    @Test("a paste ending on a barline closes that bar with the breath, not the next one")
    func pasteEndingOnABarlineClosesThatBar() throws {
        var score = Self.score(
            [Self.c4, Self.d4, Self.comma, Self.e4, Self.f4],
            [Self.g4, Self.a4, Self.b4, Self.c5],
            [Self.g4, Self.a4, Self.b4, Self.c5],
        )
        let text = try Self.copy(Self.range(Self.slot(0, 0), Self.slot(0, 1)), in: score)
        try Self.paste(text, at: Self.slot(1, 2), into: &score)
        #expect(Self.elements(score, 1) == [Self.g4, Self.a4, Self.c4, Self.d4, Self.comma])
        #expect(Self.elements(score, 2) == [Self.g4, Self.a4, Self.b4, Self.c5])
    }

    // MARK: - ⌘X / ⌘V

    @Test("cut and paste moves the breath after the range's last chord")
    func cutAndPasteMovesTheEndBreath() throws {
        var score = Self.score(
            [Self.c4, Self.d4, Self.comma, Self.e4, Self.f4],
            [Self.g4, Self.a4, Self.b4, Self.c5],
        )
        let range = Self.range(Self.slot(0, 0), Self.slot(0, 1))
        let text = try Self.copy(range, in: score)
        _ = try DeleteRange(over: range).apply(to: &score)
        try Self.paste(text, at: Self.slot(1, 0), into: &score)
        #expect(Self.elements(score, 0) == [.rest(duration: .half), Self.e4, Self.f4])
        #expect(Self.elements(score, 1) == [Self.c4, Self.d4, Self.comma, Self.b4, Self.c5])
    }

    @Test("cut and paste of a bar ending on a breath moves it to the end of the score's last bar, appending nothing")
    func cutAndPasteMovesTheBarEndBreath() throws {
        var score = Self.score(
            [Self.c4, Self.d4, Self.e4, Self.f4, Self.comma],
            [Self.g4, Self.a4, Self.b4, Self.c5],
        )
        let range = Self.range(Self.slot(0, 0), Self.slot(0, 3))
        let text = try Self.copy(range, in: score)
        _ = try DeleteRange(over: range).apply(to: &score)
        try Self.paste(text, at: Self.slot(1, 0), into: &score)
        #expect(Self.elements(score, 0) == [.rest(duration: .measure)])
        #expect(Self.elements(score, 1) == [Self.c4, Self.d4, Self.e4, Self.f4, Self.comma])
        #expect(score.parts[0].staves[0].measures.count == 2)
    }
}
