import SheetMusicCore

/// The engraving element sitting under a point during a hit-test.
///
/// `ScoreHitTester.hitTest(at:)` returns one of these. The library
/// does not dictate what a click "means" — it just reports what was
/// hit, so the app can decide its own selection / interaction policy
/// (MuseScore-style beam-length editing, "clicking the stem selects
/// the note", "clicking the beam selects the run", etc.).
///
/// For `.stem`, `.flag`, and `.beam`, the associated `notes` array
/// lists every notehead that shares the stem / flag / beam run. For
/// a chord this is all of its notes; for a beam run it is every
/// notehead on every chord under that beam.
///
/// ## The priority ladder — first match wins
///
/// `ScoreHitTester.hitTest(at:)` tries, in order:
///
/// **notehead → rest → beam → flag → stem → tuplet → clef → text.**
///
/// This is the one place that order is written down; `hitTest`'s own doc points here, because the copy it
/// used to carry went stale. Each rung earns its position: beam precedes stem so a click on the beam bar
/// resolves to `.beam` rather than the stem endpoint beneath it, and flag precedes stem so the flag curve
/// resolves to `.flag` rather than the stem it sits on top of. Tuplet is late so a click on a notehead
/// inside the bracket still selects the note, and clef is later still (its header column overlaps no note
/// geometry, so its position is mostly cosmetic).
///
/// ## Engraved text is tried LAST
///
/// The four text cases at the bottom of this enum are reported only after every rung above has declined the
/// point, so a syllable can never steal a click that is plainly on a note.
///
/// How much that ordering currently buys was measured rather than assumed, and the answer is: nothing yet,
/// by a hair. The skyline leaves the lyric line a constant **2.6 sp** below the lowest notehead — at every
/// pitch and staff size tried, since both distances scale with the spatium — against a combined reach of
/// 1.2 sp (the notehead's hit radius) + 1 sp (half a syllable's box) + 0.25 sp
/// (`ScoreHitTester.textHitTolerance`) = **2.45 sp**. The stem-down case clears by less still, about 0.1 sp.
/// So under today's autoplace no point in a laid-out score is claimed by both passes, and the ordering is
/// defence-in-depth: any change to those clearances, to the hit tolerances, or to the lyrics font puts them
/// in contact. `ScoreHitTesterTextTests` pins both halves — the disjointness in a real layout, and the
/// ordering itself against a synthetic overlap, since a real one cannot currently be produced.
///
/// Each text case carries the identity the layout element already holds, so a hit round-trips back to the
/// command that edits it: `SetLyric` takes the `anchor` + `verse`, `SetStaffText` the `anchor` + `style`,
/// `SetChordSymbol` the `anchor`, and `SetRehearsalMark` the `measureIndex` (a rehearsal mark is a system
/// element addressed by bar, so it has no voice element to name). Text whose layout element carries no
/// identity is not reported at all: an instrument-change instruction and a `<Swing>` marking reach the page
/// through `.staffText` but no text-entry command can address them.
public enum ScoreHitTarget: Hashable, Sendable {
    case note(NoteID)
    case rest(RestID)
    case stem(notes: [NoteID])
    case flag(notes: [NoteID])
    case beam(notes: [NoteID])
    /// Tuplet bracket / number area. Hit-target for clicking the
    /// "3" / "5" label or the bracket line that spans the tuplet.
    case tuplet(TupletID)
    /// Selectable clef glyph. Only emitted for clefs whose
    /// `LayoutElement.clef.anchor` is non-nil — continuation-system
    /// header clef restatements are not hit-targets.
    case clef(ClefAnchor)
    /// An engraved lyric syllable. `anchor` is the chord that owns it, `verse` its lyric-array index — the
    /// two arguments `SetLyric` takes.
    case lyric(anchor: VoiceElementID, verse: Int)
    /// Free-form staff or system text. The two are ONE layout case separated by `style`, and a host needs to
    /// know which it clicked to open the right kind of caret, so the style travels with the target.
    case staffText(anchor: VoiceElementID, style: TextStyleType)
    /// A chord symbol. `anchor` is the chord or rest the symbol names, not the harmony element's own index.
    case harmony(anchor: VoiceElementID)
    /// A rehearsal mark, including its frame: the box is what a reader aims at, and a click on the border of
    /// a boxed "A" means the mark. Addressed by bar, like `SetRehearsalMark`.
    case rehearsalMark(measureIndex: Int)
}
