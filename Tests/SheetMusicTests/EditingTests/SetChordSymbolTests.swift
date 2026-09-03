import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("SetChordSymbol")
struct SetChordSymbolTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func elements(_ score: Score, _ measure: Int) -> [VoiceElement] {
        score.parts[0].staves[0].measures[measure].voices[0].elements
    }

    @Test("a symbol is inserted right before its chord, with nil tpcs")
    func insertsBeforeAChord() throws {
        var score = EditingFixtures.parityFixture() // m0: [ts, C4, D4, r, r]
        _ = try SetChordSymbol(at: Self.slot(0, 2), name: "Dm7", harmonyType: .standard).apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        #expect(elements[2] == .harmony(Harmony(name: "Dm7")))
        #expect(elements[3] == .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])))
        #expect(SetChordSymbol.current(at: Self.slot(0, 3), in: score)?.name == "Dm7")
    }

    @Test("a symbol is inserted before a rest too — a lead sheet's ordinary shape")
    func insertsBeforeARest() throws {
        var score = EditingFixtures.parityFixture() // m3: [r measure]
        _ = try SetChordSymbol(at: Self.slot(3, 0), name: "bVII", harmonyType: .roman).apply(to: &score)
        let elements = Self.elements(score, 3)
        #expect(elements == [.harmony(Harmony(name: "bVII", harmonyType: .roman)), .rest(duration: .measure)])
        #expect(SetChordSymbol.current(at: Self.slot(3, 1), in: score)?.harmonyType == .roman)
    }

    @Test("a file-authored symbol is replaced in place: parens and offsets survive, the tpcs do not")
    func replacesInPlace() throws {
        var score = EditingFixtures.parityFixture()
        score.parts[0].staves[0].measures[0].voices[0].elements.insert(
            .harmony(Harmony(name: "m7", rootTpc: 13, bassTpc: 12, leftParen: true, rightParen: true, offsetX: 1)),
            at: 1,
        )
        // [ts, harmony, C4, D4, r, r]
        _ = try SetChordSymbol(at: Self.slot(0, 2), name: " Cmaj7 ", harmonyType: .standard).apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        #expect(elements[1] == .harmony(Harmony(name: "Cmaj7", leftParen: true, rightParen: true, offsetX: 1)))
    }

    @Test("the symbol is found past a dynamic in the same run")
    func findsThroughTheRun() throws {
        var score = EditingFixtures.parityFixture()
        score.parts[0].staves[0].measures[0].voices[0].elements.insert(
            contentsOf: [.harmony(Harmony(name: "C")), .dynamic(Dynamic(subtype: "p", velocity: 49))], at: 1,
        )
        // [ts, harmony, dyn, C4, D4, r, r]
        _ = try SetChordSymbol(at: Self.slot(0, 3), name: nil, harmonyType: .standard).apply(to: &score)
        let elements = Self.elements(score, 0)
        #expect(elements.count == 6)
        #expect(elements[1] == .dynamic(Dynamic(subtype: "p", velocity: 49)))
    }

    @Test("nil removes the symbol; the inverses restore the score exactly")
    func clearAndUndo() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let writeInverse = try SetChordSymbol(at: Self.slot(0, 1), name: "C", harmonyType: .standard)
            .apply(to: &score)
        let written = score
        let clearInverse = try SetChordSymbol(at: Self.slot(0, 2), name: nil, harmonyType: .standard)
            .apply(to: &score)
        #expect(score == before)
        _ = try clearInverse.apply(to: &score)
        #expect(score == written)
        _ = try writeInverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a non-timed element, a missing element, empty text and a clear with nothing to clear are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let untimed = #expect(throws: SheetMusicError.self) {
            _ = try SetChordSymbol(at: Self.slot(0, 0), name: "C", harmonyType: .standard).apply(to: &score)
        }
        #expect(Self.reason(of: untimed) == .wrongElementKind(at: Self.slot(0, 0), expected: .chordOrRest))
        #expect(throws: SheetMusicError.self) {
            _ = try SetChordSymbol(at: Self.slot(0, 9), name: "C", harmonyType: .standard).apply(to: &score)
        }
        let empty = #expect(throws: SheetMusicError.self) {
            _ = try SetChordSymbol(at: Self.slot(0, 1), name: " \n ", harmonyType: .standard).apply(to: &score)
        }
        #expect(Self.reason(of: empty) == .emptyChordSymbol)
        let nothing = #expect(throws: SheetMusicError.self) {
            _ = try SetChordSymbol(at: Self.slot(0, 1), name: nil, harmonyType: .standard).apply(to: &score)
        }
        #expect(Self.reason(of: nothing) == .targetNotFound(Self.slot(0, 1)))
        #expect(score == before)
    }

    /// A command-written symbol carries no `<root>` / `<bass>`; the encoder omits both (`MSCXEncoder+Harmony.swift`,
    /// `chordContent`) and the decoder reads their absence back as `nil`, so the symbol survives a save exactly and
    /// a second encode is byte-identical — the shape the corpus 2-pass gate measures.
    @Test("a written symbol round-trips through MSCX and is a two-pass fixed point", arguments: [
        ("Am7", HarmonyType.standard), ("bVII", .roman), ("4", .nashville),
    ] as [(String, HarmonyType)])
    func roundTripsThroughMSCX(name: String, harmonyType: HarmonyType) throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetChordSymbol(at: Self.slot(3, 0), name: name, harmonyType: harmonyType).apply(to: &score)
        let first = try MSCXEncoder.encode(score)
        let parsed = try MSCXParser.parse(first)
        let reread = try #require(SetChordSymbol.current(at: Self.slot(3, 1), in: parsed))
        #expect(reread.name == name)
        #expect(reread.harmonyType == harmonyType)
        #expect(reread.rootTpc == nil)
        #expect(reread.bassTpc == nil)
        #expect(try MSCXEncoder.encode(parsed) == first)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
