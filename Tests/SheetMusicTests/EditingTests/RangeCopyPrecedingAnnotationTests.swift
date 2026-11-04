import Foundation
@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

/// A mark belonging to the chord BEFORE a range — stored ahead of that chord, at its tick — stays behind when the range
/// is copied, on the clipboard as with `R`. MuseScore's clipboard starts at the range's first ChordRest segment
/// (`TWrite::writeSegments`, `rw/write/twrite.cpp:3501`) and writes the annotations of the segments it walks
/// (`:3527-3557`), so the segment of the chord before is never written. The clipboard document used to drop that chord
/// but keep its mark, which slid onto the document's first tick and pasted as the first copied chord's own.
@Suite("Range copy — a mark on the chord before the range")
struct RangeCopyPrecedingAnnotationTests {
    /// Every annotation kind `RangeCopySource.isCopyable(_:)` admits — all of it but the clef and the breath, which
    /// stand in segments of their own and have their own edge rules.
    enum Mark: String, CaseIterable, Sendable {
        case dynamic, fermata, chordSymbol, sticking, expression, capo, stringTunings, figuredBass, symbol, fretDiagram

        var element: VoiceElement {
            switch self {
            case .dynamic: .dynamic(Dynamic(subtype: "mf", velocity: 64))
            case .fermata: .fermata(Fermata(subtype: "fermataAbove"))
            case .chordSymbol: .harmony(Harmony(name: "C"))
            case .sticking: .sticking(Sticking(text: "R"))
            case .expression: .expression(ExpressionText(text: "dolce"))
            case .capo: .capo(Capo(fretPosition: 2, text: "Capo 2"))
            case .stringTunings: .stringTunings(StringTunings(text: "Drop D"))
            case .figuredBass: .figuredBass(FiguredBass(items: [FiguredBassItem(digit: 6)]))
            case .symbol: .symbol(EngravingSymbol(name: "ornamentTrill"))
            case .fretDiagram: .fretDiagram(FretDiagram())
            }
        }

        func matches(_ element: VoiceElement) -> Bool {
            switch (self, element) {
            case (.dynamic, .dynamic), (.fermata, .fermata), (.chordSymbol, .harmony), (.sticking, .sticking),
                 (.expression, .expression), (.capo, .capo), (.stringTunings, .stringTunings),
                 (.figuredBass, .figuredBass), (.symbol, .symbol), (.fretDiagram, .fretDiagram):
                true
            default: false
            }
        }
    }

    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func quarter(_ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    /// Bar 0: `[mark, C, D, E, F]` — the mark is C's. Bar 1: `[G, A, B, C]`, no marks.
    private static func score(_ mark: Mark) -> Score {
        Score(division: 480, parts: [
            Part(
                id: "1", trackName: "Flute", instrument: Instrument(id: "flute"),
                staves: [Staff(defaultClefType: "G", measures: [
                    Measure(voices: [Voice(elements: [
                        mark.element, quarter(60, 14), quarter(62, 16), quarter(64, 18), quarter(65, 13),
                    ])]),
                    Measure(voices: [Voice(elements: [
                        quarter(67, 15), quarter(69, 17), quarter(71, 19), quarter(72, 14),
                    ])]),
                ])],
            ),
        ])
    }

    private static func elements(_ score: Score, _ measure: Int) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[0].elements.values
    }

    private static func copyAndPaste(_ range: VoiceElementRange, at location: VoiceElementID, in score: inout Score)
        throws
    {
        let document = try #require(score.clipboardDocument(for: range))
        let text = try #require(String(data: MSCXEncoder.encode(document), encoding: .utf8))
        _ = try PasteRange(at: location, payload: text, readPayload: MSCXParser.parse).apply(to: &score)
    }

    @Test("⌘C/⌘V of D–F does not give the destination C's mark", arguments: Mark.allCases)
    func clipboardLeavesThePrecedingChordsMark(_ mark: Mark) throws {
        var score = Self.score(mark)
        try Self.copyAndPaste(
            VoiceElementRange(start: Self.slot(0, 2), end: Self.slot(0, 4)), at: Self.slot(1, 0), in: &score,
        )
        #expect(!Self.elements(score, 1).contains(where: mark.matches))
    }

    /// Positive control: the probe can see a carried mark at all — C's own mark comes along when C is copied.
    @Test("control: ⌘C/⌘V of C–E does carry C's own mark", arguments: Mark.allCases)
    func clipboardCarriesTheFirstChordsOwnMark(_ mark: Mark) throws {
        var score = Self.score(mark)
        try Self.copyAndPaste(
            VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 3)), at: Self.slot(1, 0), in: &score,
        )
        #expect(Self.elements(score, 1).contains(where: mark.matches))
    }

    /// Control on the other path: `R` walks the source's real ticks, so it should not show the leak.
    @Test("control: R of D–F does not give the copy C's mark", arguments: Mark.allCases)
    func duplicateLeavesThePrecedingChordsMark(_ mark: Mark) throws {
        var score = Self.score(mark)
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 2), end: Self.slot(0, 4)))
            .apply(to: &score)
        #expect(!Self.elements(score, 1).contains(where: mark.matches))
    }
}
