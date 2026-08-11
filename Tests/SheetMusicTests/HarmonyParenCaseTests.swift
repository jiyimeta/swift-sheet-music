import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// `<leftParen/>` / `<rightParen/>` / `<rootCase>` / `<baseCase>` were
/// decoded and round-tripped by the encoder but never reached
/// `HarmonyRendering`, so `(C7)` engraved as `C7`. MuseScore draws the
/// parentheses (`harmony.cpp:202,261`) and applies the note case in
/// `tpc2name` (`pitchspelling.cpp:372-381`).
@Suite("Harmony parentheses and note case")
struct HarmonyParenCaseTests {
    /// MuseScore TPC cycle-of-fifths values (`pitchspelling.h`):
    /// 13 = B♭, 15 = C, 17 = D.
    private func harmony(
        name: String = "7",
        rootTpc: Int? = 15,
        rootCase: NoteCase = .auto,
        bassTpc: Int? = nil,
        bassCase: NoteCase = .auto,
        leftParen: Bool = false,
        rightParen: Bool = false,
        harmonyType: HarmonyType = .standard,
    ) -> Harmony {
        Harmony(
            name: name,
            harmonyType: harmonyType,
            rootTpc: rootTpc,
            rootCase: rootCase,
            bassTpc: bassTpc,
            bassCase: bassCase,
            leftParen: leftParen,
            rightParen: rightParen,
        )
    }

    @Test func bothParensWrapTheSymbol() {
        #expect(HarmonyRendering.displayedName(
            for: harmony(leftParen: true, rightParen: true),
        ) == "(C7)")
    }

    @Test func aSingleParenIsDrawnOnItsOwnSide() {
        #expect(HarmonyRendering.displayedName(
            for: harmony(leftParen: true),
        ) == "(C7")
        #expect(HarmonyRendering.displayedName(
            for: harmony(rightParen: true),
        ) == "C7)")
    }

    @Test func parensWrapAWholeNameWithNoRootTpc() {
        #expect(HarmonyRendering.displayedName(
            for: harmony(
                name: "Bbmaj7", rootTpc: nil,
                leftParen: true, rightParen: true,
            ),
        ) == "(Bbmaj7)")
    }

    @Test func rootCaseAppliesToTheRootLetterOnly() {
        // `m7` stays lowercase-as-authored; only the root letter is
        // re-cased, matching `tpc2name`'s `s.toLower()` on the note
        // name alone.
        #expect(HarmonyRendering.displayedName(
            for: harmony(name: "m7", rootCase: .lower),
        ) == "cm7")
        #expect(HarmonyRendering.displayedName(
            for: harmony(name: "m7", rootCase: .upper),
        ) == "Cm7")
    }

    @Test func rootCaseLeavesTheAccidentalAlone() {
        // TPC 13 = B flat → "Bb"; lowercasing must not touch the `b`
        // that stands for the flat, or the accidental substitution in
        // `parseSlices` would still fire but the letter would read as
        // "bb" (B double flat).
        #expect(HarmonyRendering.displayedName(
            for: harmony(name: "", rootTpc: 13, rootCase: .lower),
        ) == "bb")
        #expect(HarmonyRendering.displayedName(
            for: harmony(name: "", rootTpc: 13, rootCase: .upper),
        ) == "Bb")
    }

    @Test func bassCaseAppliesToTheSlashBass() {
        #expect(HarmonyRendering.displayedName(
            for: harmony(bassTpc: 17, bassCase: .lower),
        ) == "C7/d")
    }

    @Test func autoAndCapitalizeLeaveTheNameUntouched() {
        for noteCase in [NoteCase.auto, .capitalize] {
            #expect(HarmonyRendering.displayedName(
                for: harmony(name: "m7", rootCase: noteCase),
            ) == "Cm7")
        }
    }

    @Test func aLeadingParenDoesNotSwallowARomanNumeralAccidental() {
        // `parseSlices` recognizes a leading accidental only for roman
        // / nashville symbols, and only at index 0 — a wrapping paren
        // must not push `b` out of that position.
        let runs = HarmonyRendering.runs(
            for: harmony(
                name: "bVII", rootTpc: nil,
                leftParen: true, rightParen: true,
                harmonyType: .roman,
            ),
            metrics: StaffMetrics(staffSize: 28),
        )
        let accidentals = runs.filter {
            if case .accidental = $0.kind { return true } else { return false }
        }
        #expect(accidentals.count == 1)
    }
}
