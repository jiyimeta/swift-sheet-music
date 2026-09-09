import SheetMusicFoundation

/// The identity of one piece of engraved text, as a selectable item.
///
/// The four cases, their labels and their payloads are deliberately identical to the four text cases of
/// `ScoreHitTarget` (`SheetMusicLayout`), so a hit becomes a selection without a translation table:
/// `ScoreHitTarget.textID` is a straight re-wrap, and every identity here is the same one the command that
/// edits the text takes — `SetLyric` the `anchor` + `verse`, `SetStaffText` the `anchor` + `style`,
/// `SetChordSymbol` the `anchor`, `SetRehearsalMark` the `measureIndex`.
///
/// It exists as its own type rather than as four more cases on `ScoreItemID` for two reasons. The four
/// positional accessors `ScoreItemID` publishes (`staff` / `measureIndex` / `voiceIndex` / `elementIndex`)
/// have to answer for every case, and only ONE of the four text kinds — the rehearsal mark — answers them
/// differently, so nesting keeps that single approximation in one place instead of spreading it across four
/// branches of four switches. And every exhaustive `switch` over `ScoreItemID` elsewhere in the engine gains
/// one arm rather than four.
///
/// ## A text selection is per element, never per row
///
/// A `.lyric` names ONE syllable — the anchor's syllable in that verse — not the verse row it sits in.
/// That follows MuseScore, where `Lyrics` is a single `EngravingItem` parented to a `ChordRest` with
/// `m_verse` as a plain row index (`dom/lyrics.h`), selection is a set of such items, and
/// `EngravingItem::curColor` tints each selected item on its own (`dom/engravingitem.cpp`). Nothing in
/// MuseScore's click path groups a verse: selecting every syllable of a row is the explicit
/// "select similar" command, not what a click does.
///
/// The hyphen and melisma rules between syllables are NOT part of the selection either, for the same
/// reason: MuseScore draws them from `LyricsLineSegment`, a separate item with its own `curColor`
/// (`rendering/score/tdraw.cpp`), so they keep their ink color while the syllable they connect is blue.
public enum ScoreTextID: Hashable, Sendable {
    /// One engraved lyric syllable: the chord that owns it, and its lyric-array index.
    case lyric(anchor: VoiceElementID, verse: Int)
    /// Free-form staff or system text. `style` separates the two, which are one layout element.
    case staffText(anchor: VoiceElementID, style: TextStyleType)
    /// A chord symbol. `anchor` is the chord or rest the symbol names.
    case harmony(anchor: VoiceElementID)
    /// A rehearsal mark, addressed by bar: it is a system element with no voice element to name.
    case rehearsalMark(measureIndex: Int)

    /// The voice element this text hangs from, or `nil` for a rehearsal mark — which has none, and is the
    /// reason `ScoreItemID`'s positional accessors need an approximation for one of these four.
    public var anchor: VoiceElementID? {
        switch self {
        case let .lyric(anchor, _): return anchor
        case let .staffText(anchor, _): return anchor
        case let .harmony(anchor): return anchor
        case .rehearsalMark: return nil
        }
    }
}
