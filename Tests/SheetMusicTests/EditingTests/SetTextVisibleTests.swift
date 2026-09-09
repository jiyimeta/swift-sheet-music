@testable import SheetMusicCore
import Testing

/// `SetTextVisible` — the one command that shows or hides engraved text, over all four `ScoreTextID` kinds.
///
/// The claim worth testing is not that a flag flips: it is that the flag flips on the TEXT and on nothing else.
/// Every kind here hangs off (or sits next to) a chord that has a `visible` flag of its own, and aiming the
/// existing `SetElementVisible` at the anchor a click hands over would flip that one instead — which is exactly
/// what the Folino properties panel refused to do until this command existed.
@Suite("Set text visible")
struct SetTextVisibleTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let first = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
    private static let second = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)

    /// The fixture with one of each kind written onto it: a syllable and a chord symbol on the first chord, a
    /// staff text and a system text on the second, and a rehearsal mark on the bar.
    ///
    /// The chord symbol is written LAST on its chord for a reason worth stating: `SetChordSymbol` inserts the
    /// `.harmony` element immediately before the chord, so it shifts the chord's own element index. Writing it
    /// first would leave `first` naming the symbol rather than the chord it names.
    private static func populated() throws -> Score {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        _ = try SetLyric(at: first, verse: 0, text: "la", syllabic: .single).apply(to: &score)
        _ = try SetStaffText(anchor: second, text: "pizz.", isSystemText: false).apply(to: &score)
        _ = try SetStaffText(anchor: second, text: "Swing", isSystemText: true).apply(to: &score)
        _ = try SetRehearsalMark(measureIndex: 0, text: "A").apply(to: &score)
        _ = try SetChordSymbol(at: first, name: "Am7").apply(to: &score)
        return score
    }

    /// After the symbol insert above, the two chords have moved one slot to the right.
    private static let firstAfterSymbol = VoiceElementID(
        staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2,
    )
    private static let secondAfterSymbol = VoiceElementID(
        staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 3,
    )

    private static func ids() -> [ScoreTextID] {
        [
            .lyric(anchor: firstAfterSymbol, verse: 0),
            .staffText(anchor: secondAfterSymbol, style: .staffText),
            .staffText(anchor: secondAfterSymbol, style: .systemText),
            .harmony(anchor: firstAfterSymbol),
            .rehearsalMark(measureIndex: 0),
        ]
    }

    @Test("every kind reads visible to begin with, hides, and reads hidden")
    func hidesEveryKind() throws {
        var score = try Self.populated()
        for id in Self.ids() {
            #expect(SetTextVisible.current(id, in: score) == true, "\(id) should start visible")
            _ = try SetTextVisible(id, visible: false).apply(to: &score)
            #expect(SetTextVisible.current(id, in: score) == false, "\(id) should read hidden")
        }
    }

    @Test("the inverse restores the score exactly, for every kind")
    func inverseRestores() throws {
        for id in Self.ids() {
            var score = try Self.populated()
            let before = score
            let inverse = try SetTextVisible(id, visible: false).apply(to: &score)
            #expect(score != before, "\(id) should have changed the score")
            _ = try inverse.apply(to: &score)
            #expect(score == before, "\(id) should have restored the score")
        }
    }

    /// The finding this command exists for: hiding a syllable, a chord symbol or a mark leaves the chord it hangs
    /// from — and every other text on the bar — exactly as visible as it was.
    @Test("hiding a text touches nothing else")
    func hidingATextTouchesNothingElse() throws {
        var score = try Self.populated()
        for id in Self.ids() {
            _ = try SetTextVisible(id, visible: false).apply(to: &score)
        }
        guard case let .chord(anchored)? = score[Self.firstAfterSymbol],
              case let .chord(other)? = score[Self.secondAfterSymbol]
        else { Issue.record("expected two chords"); return }
        #expect(anchored.visible)
        #expect(other.visible)
        #expect(anchored.notes.filter(\.visible).count == anchored.notes.count)
        // The chord symbol's own element is the one that went hidden — and it is NOT the chord.
        let symbol = try #require(SetChordSymbol.current(at: Self.firstAfterSymbol, in: score))
        #expect(!symbol.visible)
    }

    /// A `ScoreTextID` naming a text the score does not carry is refused rather than applied to something near
    /// it. Four shapes of "not there": a verse the chord lacks, a beat with no text of that kind, a chord with no
    /// symbol, and a bar with no mark.
    @Test("a text the score does not carry is refused")
    func missingTextIsRefused() throws {
        let score = EditingFixtures.twoConsecutiveC4Chords()
        let missing: [ScoreTextID] = [
            .lyric(anchor: Self.first, verse: 0),
            .staffText(anchor: Self.first, style: .staffText),
            .harmony(anchor: Self.first),
            .rehearsalMark(measureIndex: 0),
        ]
        for id in missing {
            #expect(SetTextVisible.current(id, in: score) == nil, "\(id) should read as absent")
            var scratch = score
            #expect(throws: SheetMusicError.self) {
                try SetTextVisible(id, visible: false).apply(to: &scratch)
            }
            #expect(scratch == score, "\(id) must not have changed the score")
        }
    }

    /// A staff text and a system text at the same beat are two marks, and the id's `style` is what tells them
    /// apart — hiding one leaves the other alone.
    @Test("staff text and system text at one beat are hidden independently")
    func staffAndSystemTextAreIndependent() throws {
        var score = try Self.populated()
        let staffText = ScoreTextID.staffText(anchor: Self.secondAfterSymbol, style: .staffText)
        let systemText = ScoreTextID.staffText(anchor: Self.secondAfterSymbol, style: .systemText)
        _ = try SetTextVisible(staffText, visible: false).apply(to: &score)
        #expect(SetTextVisible.current(staffText, in: score) == false)
        #expect(SetTextVisible.current(systemText, in: score) == true)
    }

    /// A lyric on verse 1 is a different text from the one on verse 0, even on the same chord.
    @Test("verses are hidden independently")
    func versesAreIndependent() throws {
        var score = try Self.populated()
        _ = try SetLyric(at: Self.firstAfterSymbol, verse: 1, text: "lo", syllabic: .single).apply(to: &score)
        let verse0 = ScoreTextID.lyric(anchor: Self.firstAfterSymbol, verse: 0)
        let verse1 = ScoreTextID.lyric(anchor: Self.firstAfterSymbol, verse: 1)
        _ = try SetTextVisible(verse1, visible: false).apply(to: &score)
        #expect(SetTextVisible.current(verse0, in: score) == true)
        #expect(SetTextVisible.current(verse1, in: score) == false)
    }

    /// A rehearsal mark has no anchor, so `affectedLocation` falls back to the bar-addressing approximation the
    /// other bar-level commands report — the one thing about it a host reads is `measureIndex`.
    @Test("a rehearsal mark's affected location names its bar")
    func rehearsalMarkAffectedLocation() {
        let command = SetTextVisible(.rehearsalMark(measureIndex: 3), visible: false)
        #expect(command.affectedLocation.measureIndex == 3)
        #expect(command.affectedLocation.staff == StaffAddress(partIndex: 0, staffIndexInPart: 0))
    }
}
