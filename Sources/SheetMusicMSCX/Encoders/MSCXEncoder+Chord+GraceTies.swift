import SheetMusicCore
import SheetMusicFoundation

extension Chord {
    /// Per-note `<prev>` overrides for the "tied acciaccatura into its
    /// main note" figure: a note of this chord whose `tieBack` actually
    /// targets one of this chord's own `graceNotesBefore`, not the
    /// previous real chord `Voice.backwardTieLocation` would otherwise
    /// name — the wrong partner entirely.
    ///
    /// Returns `notes`-index → `TieEndpoint` for `encodeAsChord` to
    /// prefer over the ordinary chord-to-chord location.
    ///
    /// This project's tie model is presence-only
    /// (`Note.tieForward`/`tieBack` carry no pointer to their partner
    /// note), so pairing is done by pitch. `Chord.notes` and each
    /// individual `GraceChord.notes` are separately pitch-unique
    /// (`ChordNotes`'s type-level invariant), but two *different* grace
    /// chords can carry the same pitch, so a match is used only when
    /// unambiguous: exactly one grace note, across the whole list, at
    /// this pitch with the matching tie side set. A chord without
    /// graces, or whose graces carry no matching tie, returns an empty
    /// map and encodes byte-identically to a chord that never had any.
    func graceBeforeTieBackEndpoints() -> [Int: TieEndpoint] {
        graceTieEndpoints(
            graces: graceNotesBefore,
            fileOrdinal: mscxGraceIndex(ofBeforeGraceAt:),
            graceSideHasTie: { $0.tieForward != nil },
            mainSideHasTie: { $0.tieBack != nil },
        )
    }

    /// The mirror of `graceBeforeTieBackEndpoints()` for a tied
    /// Nachschlag — a note of this chord tying *forward* into one of its
    /// own `graceNotesAfter`. Same by-pitch matching, same ambiguity
    /// rule; only the tie side and the grace list differ.
    ///
    /// This direction was deliberately left out before the after-grace
    /// placement fix: an after-grace used to be written *behind* its
    /// owner, so MuseScore attached it to the following chord and a
    /// computed `<grace>` ordinal would have named a grace of the wrong
    /// parent. With `Chord.mscxFileOrderedGraces` putting every grace
    /// ahead of its owner, the ordinal is now well defined.
    func graceAfterTieForwardEndpoints() -> [Int: TieEndpoint] {
        graceTieEndpoints(
            graces: graceNotesAfter,
            fileOrdinal: mscxGraceIndex(ofAfterGraceAt:),
            graceSideHasTie: { $0.tieBack != nil },
            mainSideHasTie: { $0.tieForward != nil },
        )
    }

    /// Shared body of the two directions above.
    ///
    /// The emitted `<grace>` is the partner's ordinal within the file
    /// run, which is MuseScore's `Location::graceIndex`
    /// (`dom/location.cpp:199-208`) — an **absolute** field, untouched
    /// by `Location::toRelative` — so it is `fileOrdinal(matchIndex)`,
    /// not a delta. `<notes>` is the opposite: a delta between the two
    /// endpoints' own note indices. See `TieEndpoint`.
    private func graceTieEndpoints(
        graces: [GraceChord],
        fileOrdinal: (Int) -> Int,
        graceSideHasTie: (Note) -> Bool,
        mainSideHasTie: (Note) -> Bool,
    ) -> [Int: TieEndpoint] {
        guard !graces.isEmpty else { return [:] }
        var overrides: [Int: TieEndpoint] = [:]
        for (noteIndex, note) in notes.enumerated() {
            guard mainSideHasTie(note) else { continue }
            var matchedGraceIndex: Int?
            var matchCount = 0
            for (graceIndex, grace) in graces.enumerated() {
                let hasMatch = grace.notes.contains {
                    $0.pitch == note.pitch && graceSideHasTie($0)
                }
                guard hasMatch else { continue }
                matchCount += 1
                matchedGraceIndex = graceIndex
            }
            guard matchCount == 1, let matchedGraceIndex else { continue }
            overrides[noteIndex] = TieEndpoint(
                .graceIndexed(fileOrdinal(matchedGraceIndex)),
                notesDelta: MSCXLocationNoteIndex.index(
                    ofPitch: note.pitch, in: graces[matchedGraceIndex].notes,
                ) - MSCXLocationNoteIndex.index(ofPitch: note.pitch, in: notes),
            )
        }
        return overrides
    }
}
