@testable import SheetMusicCore
import Testing

/// What a duplicated range carries BESIDES its notes and rests: the non-timed elements standing among them.
///
/// MuseScore's clipboard payload is every non-generated element of every in-range segment plus its annotations
/// (`twrite.cpp:3520-3617`), but the paste is narrower than the copy — it reads clef (`read460.cpp:704-715`),
/// breath (`717-728`) and the annotation list (`664-703`), and silently drops key signature, time signature,
/// barline and rehearsal mark (`739-744`). What the copy may carry is therefore decided by the READ side.
@Suite("DuplicateRange carried elements")
struct DuplicateRangeCarriedElementsTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    private static func voice(_ score: Score, _ measure: Int, _ index: Int = 0) -> Voice {
        score.parts[0].staves[0].measures[measure].voices[index]
    }

    private static func quarter(_ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    private static func score(_ measures: [Measure]) -> Score {
        Score(division: 480, parts: [
            Part(
                id: "1", trackName: "Flute", instrument: Instrument(id: "flute"),
                staves: [Staff(defaultClefType: "G", measures: measures)],
            ),
        ])
    }

    /// One 4/4 bar of four quarters carrying a mid-bar clef and dynamic at tick 480 and a key signature and a
    /// barline at tick 960 — one kind from each side of the paste's accept/drop line.
    private static func barWithNonTimedElements() -> Score {
        score([
            Measure(voices: [Voice(elements: [
                quarter(60, 14),
                .clef(Clef(concertClefType: "F")),
                .dynamic(Dynamic(subtype: "mf", velocity: 64)),
                quarter(62, 16),
                .keySignature(KeySignature(concertKey: 2)),
                .barLine(BarLine(subtype: "double")),
                quarter(64, 18),
                quarter(65, 19),
            ])]),
        ])
    }

    @Test("a copied bar brings its clef and dynamic along, at the same offsets, and nothing the paste drops")
    func carriesClefAndAnnotations() throws {
        var score = Self.barWithNonTimedElements()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 7)))
            .apply(to: &score)
        #expect(score.parts[0].staves[0].measures.count == 2)
        // The clef and the dynamic land one beat into the copy, exactly where they stood one beat into the
        // source; the key signature and the barline at beat 3 do not come along at all. Neither consumed any of
        // the destination bar's budget either — the four quarters still fill it.
        #expect(Self.voice(score, 1).elements == [
            Self.quarter(60, 14),
            .clef(Clef(concertClefType: "F")),
            .dynamic(Dynamic(subtype: "mf", velocity: 64)),
            Self.quarter(62, 16),
            Self.quarter(64, 18),
            Self.quarter(65, 19),
        ])
    }

    /// Two 4/4 bars of four quarters. Bar 0 (the source) opens with a chord symbol. Bar 1 (the destination)
    /// carries one at tick 0 — which the copy's own lands on — and one at tick 960, which it does not.
    private static func chordSymbolsOverTwoBars() -> Score {
        score([
            Measure(voices: [Voice(elements: [
                .harmony(Harmony(name: "C")),
                quarter(60, 14), quarter(62, 16), quarter(64, 18), quarter(65, 19),
            ])]),
            Measure(voices: [Voice(elements: [
                .harmony(Harmony(name: "Am")),
                quarter(72, 14), quarter(74, 16),
                .harmony(Harmony(name: "Dm")),
                quarter(76, 18), quarter(77, 19),
            ])]),
        ])
    }

    /// The drop branch MuseScore states at `cmd.cpp:1502` + `read460.cpp:656-661`: a destination chord symbol
    /// stands through the gap the copy opens EXCEPT where the copied material lands one of its own on the same
    /// tick. Both halves of that condition run here, in one bar.
    @Test("a destination chord symbol is replaced only where the copy brings one to the same tick")
    func replacesOnlyTheCoveredChordSymbol() throws {
        var score = Self.chordSymbolsOverTwoBars()
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 4)))
            .apply(to: &score)
        let names = Self.voice(score, 1).elements.values.compactMap { element -> String? in
            guard case let .harmony(harmony) = element else { return nil }
            return harmony.name
        }
        // "Am" stood at tick 0, where the copy lands its own "C", so it goes; "Dm" stood at tick 960, which the
        // copy covers but brings no symbol to, so it stays.
        #expect(names == ["C", "Dm"])
        #expect(Self.voice(score, 1).elements == [
            .harmony(Harmony(name: "C")),
            Self.quarter(60, 14), Self.quarter(62, 16),
            .harmony(Harmony(name: "Dm")),
            Self.quarter(64, 18), Self.quarter(65, 19),
        ])
    }
}
