import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Where each side of a `<Spanner type="Glissando">` points.
///
/// `LayoutEngine.collectGlissandi` pairs note `i` with note
/// `min(i, next.notes.count - 1)` of the immediately next real chord in the
/// voice. The encoder repeats that insertion-order rule, then converts both
/// notes to MuseScore's pitch-ranked `Location::note` indices through
/// `MSCXLocationNoteIndex`. The begin side writes target rank minus source
/// rank; every matching end side writes the exact negation.
///
/// Both sides need a real `<location>`. MuseScore's
/// `ConnectorInfoReader::readEndpointLocation` leaves an empty `<next>` or
/// `<prev>` at the `measure == INT_MIN` sentinel, so neither endpoint is
/// recognized and the connector is discarded. MuseScore's `Note::write`
/// likewise emits the forward side before every backward side on a note.
///
/// This deliberately sees only the same neighbouring chord/rest data used by
/// guitar bends. When the neighbour is a rest or its notes are unknown, a
/// begin side still points at that neighbour with a zero note delta, while no
/// end side can be reconstructed. It does not look ahead past rests.
extension Chord {
    /// The `<next>` endpoint for a note of this non-grace chord.
    func glissandoForwardEndpoint(
        forNoteAt noteIndex: Int,
        neighbourChord: TieLocation?,
        nextChordNotes: ChordNotes?,
    ) -> TieEndpoint? {
        guard notes.indices.contains(noteIndex),
              notes[noteIndex].glissando != nil,
              let neighbourChord
        else { return nil }

        guard let nextChordNotes, !nextChordNotes.isEmpty else {
            return TieEndpoint(neighbourChord)
        }
        let targetIndex = min(noteIndex, nextChordNotes.count - 1)
        let sourceRank = MSCXLocationNoteIndex.index(
            ofPitch: notes[noteIndex].pitch,
            in: notes,
        )
        let targetRank = MSCXLocationNoteIndex.index(
            ofPitch: nextChordNotes[targetIndex].pitch,
            in: nextChordNotes,
        )
        return TieEndpoint(neighbourChord, notesDelta: targetRank - sourceRank)
    }

    /// Every `<prev>` endpoint landing on one note of this non-grace chord.
    func glissandoBackEndpoints(
        forNoteAt noteIndex: Int,
        neighbourChord: TieLocation?,
        previousChordNotes: ChordNotes?,
    ) -> [TieEndpoint] {
        guard notes.indices.contains(noteIndex),
              let neighbourChord,
              let previousChordNotes,
              !previousChordNotes.isEmpty
        else { return [] }

        let targetRank = MSCXLocationNoteIndex.index(
            ofPitch: notes[noteIndex].pitch,
            in: notes,
        )
        return previousChordNotes.enumerated().compactMap { sourceIndex, sourceNote in
            guard sourceNote.glissando != nil,
                  min(sourceIndex, notes.count - 1) == noteIndex
            else { return nil }
            let sourceRank = MSCXLocationNoteIndex.index(
                ofPitch: sourceNote.pitch,
                in: previousChordNotes,
            )
            return TieEndpoint(
                neighbourChord,
                notesDelta: sourceRank - targetRank,
            )
        }
    }
}

extension Note {
    /// The begin side followed by every reconstructed end side, matching
    /// MuseScore 3.6.2 `Note::write` (`spannerFor` then `spannerBack`).
    /// A missing forward endpoint preserves the historical bare `<next/>`.
    func glissandoSpanners(
        forwardEndpoint: TieEndpoint?,
        backEndpoints: [TieEndpoint],
        options: MSCXEncoderOptions,
    ) -> [XMLTreeNode] {
        var result: [XMLTreeNode] = []
        if let glissando {
            result.append(glissandoSpanner(
                glissando,
                endpoint: forwardEndpoint,
                options: options,
            ))
        }
        result += backEndpoints.map { glissandoBackSpanner(endpoint: $0) }
        return result
    }

    private func glissandoSpanner(
        _ glissando: Glissando,
        endpoint: TieEndpoint?,
        options: MSCXEncoderOptions,
    ) -> XMLTreeNode {
        XMLTreeNode(
            name: "Spanner",
            attributes: ["type": "Glissando"],
            children: [
                glissando.encode(options: options),
                XMLTreeNode(
                    name: "next",
                    children: endpoint.map { [locationElement(from: $0)] } ?? [],
                ),
            ],
        )
    }

    /// The payload-free end side. `decodeConnectors` intentionally ignores
    /// this shape: only a begin side with a `<Glissando>` child creates model
    /// state, and `Spanner` is consumed rather than preserved on `Note`.
    private func glissandoBackSpanner(endpoint: TieEndpoint) -> XMLTreeNode {
        XMLTreeNode(
            name: "Spanner",
            attributes: ["type": "Glissando"],
            children: [XMLTreeNode(
                name: "prev",
                children: [locationElement(from: endpoint)],
            )],
        )
    }
}
