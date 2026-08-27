import SheetMusicCore
import SheetMusicFoundation

/// Where each side of a `<Spanner type="GuitarBend">` points.
///
/// The model is presence-only — `Note.guitarBend` on the begin note,
/// `Note.guitarBendBack` on the end note, with no pointer between them — so
/// the partner has to be re-derived from structure on the way out, the same
/// way ties are (`MSCXEncoder+Chord+GraceTies.swift`). Ties can pair by pitch;
/// a bend cannot, since changing the pitch is the entire point of one. What
/// decides it instead is *position*, and the rule is a single sounding order:
///
///     … previous chord │ before-graces → main notes → after-graces │ next …
///
/// A bend always runs to the immediately next sounding item, and its end side
/// always names the immediately previous one. So:
///
/// | begin side sits on | forward partner |
/// | --- | --- |
/// | a same-note type (`SLIGHT_BEND` / `DIP` / `SCOOP`) | itself — zero delta |
/// | a before-grace | the next before-grace, else the parent chord |
/// | a main note | the first after-grace, else the next chord |
/// | an after-grace | the next after-grace, else the chord after the parent |
///
/// and the end side mirrors it. "Else" fires when the candidate carries no
/// matching flag, which keeps a chord whose graces have nothing to do with
/// bends on the plain neighbour-chord path.
///
/// ## What this cannot see
///
/// * **Which note of a chord.** `<notes>` is left at its elided `0`, i.e. both
///   endpoints are assumed to rank alike within their chords. Ties recover the
///   rank by pitch (`MSCXLocationNoteIndex`); a bend has no such handle, and
///   all six vendored fixtures are single-note throughout.
/// * **Two bends on one note.** `guitarBendBack` is a `Bool`, so a note that
///   both ends a bend *and* carries a same-note bend is read as the latter.
extension Chord {
    /// The `<next>` endpoint for a note of this (non-grace) chord.
    func guitarBendForwardEndpoint(
        for note: Note,
        neighbourChord: TieLocation?,
    ) -> TieEndpoint? {
        guard let bend = note.guitarBend else { return nil }
        if bend.type.mscxBeginsAndEndsOnSameNote {
            return TieEndpoint(.graceZeroDelta)
        }
        if let first = graceNotesAfter.first, first.notes.contains(where: \.guitarBendBack) {
            return TieEndpoint(.graceIndexed(mscxGraceIndex(ofAfterGraceAt: 0)))
        }
        return neighbourChord.map { TieEndpoint($0) }
    }

    /// The `<prev>` endpoint for a note of this (non-grace) chord.
    ///
    /// `previousChordTrailingBendGrace` is the previous chord's
    /// `mscxTrailingAfterGraceBendIndex` — set only when that chord's
    /// last-sounding after-grace begins a bend, in which case the source is
    /// that grace rather than the chord itself and the location needs both
    /// halves. See `TieLocation.graceOfDistantChord`.
    func guitarBendBackEndpoint(
        for note: Note,
        neighbourChord: TieLocation?,
        previousChordTrailingBendGrace: Int?,
    ) -> TieEndpoint? {
        guard note.guitarBendBack else { return nil }
        if note.guitarBend?.type.mscxBeginsAndEndsOnSameNote == true {
            return TieEndpoint(.graceZeroDelta)
        }
        if let last = graceNotesBefore.last,
           last.notes.contains(where: { $0.guitarBend != nil })
        {
            return TieEndpoint(.graceIndexed(
                mscxGraceIndex(ofBeforeGraceAt: graceNotesBefore.count - 1),
            ))
        }
        guard let neighbourChord else { return nil }
        return TieEndpoint(
            previousChordTrailingBendGrace.map(neighbourChord.addressingGrace)
                ?? neighbourChord,
        )
    }

    /// The `<grace>` ordinal of this chord's last-sounding after-grace when
    /// that grace begins a bend — the one thing a *following* chord needs to
    /// know about this one to write its own `<prev>`. `nil` whenever the plain
    /// chord-to-chord location is the right answer.
    var mscxTrailingAfterGraceBendIndex: Int? {
        guard let last = graceNotesAfter.last,
              last.notes.contains(where: { $0.guitarBend != nil })
        else { return nil }
        return mscxGraceIndex(ofAfterGraceAt: graceNotesAfter.count - 1)
    }
}

extension GraceChord {
    /// The `<next>` endpoint for a note of this grace chord.
    ///
    /// `listIndex` is this grace's index within the parent's own
    /// `graceNotesBefore` / `graceNotesAfter` — *sounding* order, not file
    /// order — and `awayFromParent` is the parent chord's neighbour-chord
    /// delta, which a grace shares because it shares the parent's tick.
    func guitarBendForwardEndpoint(
        for note: Note,
        parentChord: Chord?,
        listIndex: Int,
        awayFromParent: TieLocation?,
    ) -> TieEndpoint? {
        guard let bend = note.guitarBend else { return nil }
        if bend.type.mscxBeginsAndEndsOnSameNote {
            return TieEndpoint(.graceZeroDelta)
        }
        if let sibling = siblingEndpoint(
            parentChord: parentChord,
            siblingIndex: listIndex + 1,
            matching: { $0.guitarBendBack },
        ) {
            return sibling
        }
        // A before-grace sounds immediately ahead of its parent, so its
        // forward partner is the parent itself: zero delta. An after-grace's
        // is the chord after the parent.
        return graceType.isAfter
            ? awayFromParent.map { TieEndpoint($0) }
            : TieEndpoint(.graceZeroDelta)
    }

    /// The `<prev>` endpoint for a note of this grace chord — the mirror of
    /// `guitarBendForwardEndpoint`.
    ///
    /// Not covered: a before-grace whose bend is *ended* by it and started on
    /// an after-grace of the previous chord. That is the combined form
    /// `Chord.guitarBendBackEndpoint` handles for main notes, but reaching it
    /// from here needs the previous chord, which grace encoding has no
    /// visibility into. No vendored fixture writes that figure.
    func guitarBendBackEndpoint(
        for note: Note,
        parentChord: Chord?,
        listIndex: Int,
        awayFromParent: TieLocation?,
    ) -> TieEndpoint? {
        guard note.guitarBendBack else { return nil }
        if note.guitarBend?.type.mscxBeginsAndEndsOnSameNote == true {
            return TieEndpoint(.graceZeroDelta)
        }
        if let sibling = siblingEndpoint(
            parentChord: parentChord,
            siblingIndex: listIndex - 1,
            matching: { $0.guitarBend != nil },
        ) {
            return sibling
        }
        return graceType.isAfter
            ? TieEndpoint(.graceZeroDelta)
            : awayFromParent.map { TieEndpoint($0) }
    }

    /// The endpoint naming the sibling grace at `siblingIndex` of the same
    /// parent run, when that sibling exists and carries the matching half of
    /// a bend. `<grace>` is an absolute ordinal within the parent's *file*
    /// run, so the sounding index is mapped through `Chord.mscxGraceIndex`.
    private func siblingEndpoint(
        parentChord: Chord?,
        siblingIndex: Int,
        matching predicate: (Note) -> Bool,
    ) -> TieEndpoint? {
        guard let parentChord else { return nil }
        let siblings = graceType.isAfter
            ? parentChord.graceNotesAfter
            : parentChord.graceNotesBefore
        guard siblings.indices.contains(siblingIndex),
              siblings[siblingIndex].notes.contains(where: predicate)
        else { return nil }
        return TieEndpoint(.graceIndexed(
            graceType.isAfter
                ? parentChord.mscxGraceIndex(ofAfterGraceAt: siblingIndex)
                : parentChord.mscxGraceIndex(ofBeforeGraceAt: siblingIndex),
        ))
    }
}
