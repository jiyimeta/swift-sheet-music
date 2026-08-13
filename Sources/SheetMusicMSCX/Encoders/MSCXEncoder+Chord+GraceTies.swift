import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Chord {
    /// For each of this chord's own notes carrying `tieBack`, look for
    /// a pitch-matching note among `graceNotesBefore` whose own
    /// `tieForward` is set — the "tied acciaccatura into its main
    /// note" figure, mirrored here from the grace side's own
    /// `TieLocation.graceZeroDelta` (see `GraceChord.encode`). Returns
    /// `notes`-index → `TieLocation.graceIndexed` overrides for
    /// `encodeAsChord` to prefer over the ordinary chord-to-chord
    /// location `Voice.backwardTieLocation` would otherwise compute —
    /// which names the *previous real chord* as the tie's partner,
    /// the wrong one entirely when the tie is actually to one of this
    /// chord's own graces.
    ///
    /// This project's tie model is presence-only
    /// (`Note.tieForward`/`tieBack` carry no pointer to their partner
    /// note), so pairing is done by pitch. `Chord.notes` and each
    /// individual `GraceChord.notes` are separately pitch-unique
    /// (`ChordNotes`'s type-level invariant), but two *different*
    /// grace chords in `graceNotesBefore` can carry the same pitch, so
    /// a match is used only when unambiguous: exactly one grace note,
    /// across all of `graceNotesBefore`, at this pitch with
    /// `tieForward` set. A chord without `graceNotesBefore`, or whose
    /// graces carry no matching tie, returns an empty map — a chord
    /// that reaches `encodeAsChord` through this path with no override
    /// produces byte-identical output to before this fix.
    ///
    /// **Scope: single-note chords only.** MuseScore's endpoint match
    /// (`ConnectorInfo::connect`, `dom/connector.cpp:91-122`) compares
    /// full `Location` equality, which includes `m_note`
    /// (`Location::operator==`, `dom/location.cpp:264-274`) — the tied
    /// note's own index within its chord (`Location::note`,
    /// `dom/location.cpp:214-231`), carried through `toAbsolute`
    /// unchanged as a plain per-endpoint offset (`:65-76`), not a
    /// delta between the two sides. Neither this override nor the
    /// grace side's own encoding (`GraceChord.encode`) emits a
    /// `<notes>` element, so the match MuseScore computes for that
    /// field is always `0 - 0`. That's correct whenever both the tied
    /// main note and the tied grace note are the only note in their
    /// respective chords (`Location::note` itself special-cases
    /// `notes.size() == 1` to `0` regardless of storage order) — the
    /// overwhelmingly common case this fix targets. For a multi-note
    /// main chord whose tied note sits at note-index ≥ 1 (or a
    /// multi-note grace chord likewise), the real index is nonzero,
    /// `0 - 0` doesn't match it, and MuseScore still drops the tie —
    /// not a regression, since the pre-fix bare `<prev/>`/`<next/>`
    /// failed those cases identically, but a complete fix needs
    /// `<notes>` deltas computed on both tie sides, which is a
    /// separate, non-trivial change and not done here.
    ///
    /// The returned index is the grace chord's position within
    /// `graceNotesBefore` (0-based), which equals MuseScore's own
    /// `<grace>` ordinal (`Location::graceIndex`,
    /// `dom/location.cpp:199-208`) *provided* the chord immediately
    /// preceding this one in the voice carries no `graceNotesAfter` of
    /// its own. MuseScore's read algorithm
    /// (`rw/read460/measureread.cpp:261-286`) buffers every
    /// consecutive grace-type `<Chord>` and attaches the *whole run*
    /// to the next normal chord it finds — before/after is not
    /// distinguished for attachment, only for rendering and playback
    /// timing, so any of the previous chord's `graceNotesAfter` that
    /// this project wrote (per `Voice.emitElement`) immediately ahead
    /// of this chord would be counted first in that combined run,
    /// shifting the true index. Not accounted for here: doing so needs
    /// the previous chord's own grace list threaded into this
    /// function, and the shift only *matters* once a separate bug,
    /// new in this same release's grace-writing commit, is understood
    /// — `Voice.emitElement` places `graceNotesAfter` chords *after*
    /// their own owner, which is not where MuseScore's own writer puts
    /// them (confirmed against a genuine MuseScore Studio fixture —
    /// see `TieLocation.graceIndexed`'s doc comment) — so an
    /// after-grace's true read-time tick doesn't match the chord it
    /// was meant to decorate in the first place, independent of any
    /// tie. That is a larger, separate fix; this function's index is
    /// correct for the common case (no after-grace on the immediately
    /// preceding chord) and documented as a known gap otherwise — see
    /// the release report.
    ///
    /// There is deliberately no mirror `graceNotesAfter` /
    /// `tieForward` function (a main note tying forward into its own
    /// trailing grace, e.g. a tied Nachschlag): that direction's
    /// grace note inherits the *same* misplacement bug just described,
    /// which does not merely shift an index but changes which chord
    /// MuseScore actually attaches the grace — and therefore its
    /// read-time tick — to. A computed `.graceIndexed` location there
    /// would look confident and be wrong; the ordinary (already
    /// non-reconnecting) location is left in place instead, per
    /// "prefer leaving the ordinary location rather than guessing."
    func graceBeforeTieBackLocations() -> [Int: TieLocation] {
        guard !graceNotesBefore.isEmpty else { return [:] }
        var overrides: [Int: TieLocation] = [:]
        for (noteIndex, note) in notes.enumerated() {
            guard note.tieBack != nil else { continue }
            var matchedGraceIndex: Int?
            var matchCount = 0
            for (graceIndex, grace) in graceNotesBefore.enumerated() {
                let hasMatch = grace.notes.contains {
                    $0.pitch == note.pitch && $0.tieForward != nil
                }
                guard hasMatch else { continue }
                matchCount += 1
                matchedGraceIndex = graceIndex
            }
            guard matchCount == 1, let matchedGraceIndex else { continue }
            overrides[noteIndex] = .graceIndexed(matchedGraceIndex)
        }
        return overrides
    }
}
