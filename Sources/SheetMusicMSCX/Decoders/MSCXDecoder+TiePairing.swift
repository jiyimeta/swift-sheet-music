import SheetMusicCore
import SheetMusicFoundation

/// Drop tie sides that have no partner.
///
/// MuseScore writes a tie as two half-spanners — `<Spanner type="Tie">`
/// with `<next>` on the starting note and `<prev>` on the ending one —
/// and its reader pairs them by `<location>`, discarding whichever side
/// is left unmatched (`ConnectorInfoReader`). A file can carry an
/// unmatched side after an edit that removed the note on the other end:
/// 泡沫サタデーナイト.mscz has a dotted half whose outgoing `<next>`
/// names the quarter rest behind it, and MuseScore's own MIDI export
/// shows it plays that note as if the tie were not there.
///
/// This decoder reads the two sides positionally — `<next>` present means
/// `tieForward`, `<prev>` means `tieBack` — because the model's tie is
/// presence-only: `Note.tieForward` / `Note.tieBack` carry no pointer, and
/// `Voice.forwardTieLocation` can only ever name the immediately following
/// chord. Reading the location back would therefore buy nothing except the
/// one thing it is needed for here: knowing whether a partner exists at
/// all. So the check is done structurally instead, against the same
/// adjacency the encoder writes.
///
/// Why it matters downstream: `LayoutEngine.resolveTies` pairs the ends
/// itself and simply draws nothing for an unmatched one, but `MidiRenderer`
/// trusts the flag — `tieForward` suppresses the note-off, and
/// `resolveUnisonOverlap` then closes the never-released note-on at its own
/// tick. An unmatched `tieForward` silences its whole tie chain rather than
/// lengthening it.
enum MSCXTiePairing {
    /// A run of notes that a tie can start from or land on, in the order
    /// the tie chain walks them.
    private struct Group {
        /// Which chord in the staff, and which note run inside it.
        var measure: Int
        var voice: Int
        var element: Int
        var grace: GraceSlot?
        /// Indices into that run's notes, in note order.
        var forward: [Int]
        var back: [Int]
        /// No tie may cross from the preceding group into this one — a rest
        /// sits between them, or the voice is absent from the bars between.
        var severedFromPrevious: Bool
    }

    private enum GraceSlot {
        case before(Int)
        case after(Int)
    }

    /// Which half of a tie a note carries.
    private enum Side: String {
        case forward = "tieForward"
        case back = "tieBack"
    }

    /// Clear every `tieForward` / `tieBack` whose partner is missing.
    static func pruningUnpairedTies(in measures: [Measure]) -> [Measure] {
        var measures = measures
        let voiceCount = measures.map(\.voices.count).max() ?? 0
        for voiceIndex in 0 ..< voiceCount {
            let groups = collectGroups(in: measures, voiceIndex: voiceIndex)
            apply(unpaired(in: groups), to: &measures)
        }
        return measures
    }

    /// Walk one voice across the whole staff, collecting the note runs a tie
    /// can attach to.
    ///
    /// A rest severs the chain; so does a bar where the voice is absent. Key
    /// and clef changes — the very place a tie tends to cross — are not
    /// chords and pass through without breaking anything. Grace chords join
    /// the chain only when they carry a tie of their own: a tie from the
    /// previous chord reaches the main notes *through* untied graces, so an
    /// unconditional group would sever it.
    private static func collectGroups(
        in measures: [Measure], voiceIndex: Int,
    ) -> [Group] {
        var groups: [Group] = []
        var severed = true
        func append(
            measure: Int, element: Int, grace: GraceSlot?, notes: ChordNotes,
            skippableWhenUntied: Bool,
        ) {
            let forward = notes.indices.filter { notes[$0].tieForward != nil }
            let back = notes.indices.filter { notes[$0].tieBack != nil }
            if skippableWhenUntied, forward.isEmpty, back.isEmpty { return }
            groups.append(Group(
                measure: measure, voice: voiceIndex, element: element,
                grace: grace, forward: forward, back: back,
                severedFromPrevious: severed,
            ))
            severed = false
        }

        for measureIndex in measures.indices {
            guard voiceIndex < measures[measureIndex].voices.count else {
                severed = true
                continue
            }
            let elements = measures[measureIndex].voices[voiceIndex].elements
            for elementIndex in elements.indices {
                guard case let .chord(chord) = elements[elementIndex] else { continue }
                guard !chord.notes.isEmpty else {
                    severed = true // a rest
                    continue
                }
                for graceIndex in chord.graceNotesBefore.indices {
                    append(
                        measure: measureIndex, element: elementIndex,
                        grace: .before(graceIndex),
                        notes: chord.graceNotesBefore[graceIndex].notes,
                        skippableWhenUntied: true,
                    )
                }
                append(
                    measure: measureIndex, element: elementIndex, grace: nil,
                    notes: chord.notes, skippableWhenUntied: false,
                )
                for graceIndex in chord.graceNotesAfter.indices {
                    append(
                        measure: measureIndex, element: elementIndex,
                        grace: .after(graceIndex),
                        notes: chord.graceNotesAfter[graceIndex].notes,
                        skippableWhenUntied: true,
                    )
                }
            }
        }
        return groups
    }

    /// One entry per note whose tie side has no partner.
    private struct Unpaired {
        var group: Group
        var noteIndex: Int
        var side: Side
    }

    /// Pair adjacent groups first-come-first-served — the i-th tie out of a
    /// chord answers the i-th tie into the next one, which is the pairing
    /// `MidiRenderer.resolvingTiedPitches` already walks. Whatever is left
    /// over on either side of the edge has no partner.
    private static func unpaired(in groups: [Group]) -> [Unpaired] {
        var result: [Unpaired] = []
        for index in groups.indices {
            let connectedToNext = index + 1 < groups.count
                && !groups[index + 1].severedFromPrevious
            let backCount = connectedToNext ? groups[index + 1].back.count : 0
            for noteIndex in groups[index].forward.dropFirst(
                min(groups[index].forward.count, backCount),
            ) {
                result.append(Unpaired(
                    group: groups[index], noteIndex: noteIndex, side: .forward,
                ))
            }

            let connectedToPrevious = index > 0 && !groups[index].severedFromPrevious
            let forwardCount = connectedToPrevious ? groups[index - 1].forward.count : 0
            for noteIndex in groups[index].back.dropFirst(
                min(groups[index].back.count, forwardCount),
            ) {
                result.append(Unpaired(
                    group: groups[index], noteIndex: noteIndex, side: .back,
                ))
            }
        }
        return result
    }

    private static func apply(_ unpaired: [Unpaired], to measures: inout [Measure]) {
        for entry in unpaired {
            let group = entry.group
            measures[group.measure].voices[group.voice].elements
                .updateValue(at: group.element) { element in
                    guard case var .chord(chord) = element else { return }
                    switch group.grace {
                    case nil:
                        clear(entry.side, at: entry.noteIndex, in: &chord.notes)
                    case let .before(graceIndex):
                        chord.graceNotesBefore.updateValue(at: graceIndex) {
                            clear(entry.side, at: entry.noteIndex, in: &$0.notes)
                        }
                    case let .after(graceIndex):
                        chord.graceNotesAfter.updateValue(at: graceIndex) {
                            clear(entry.side, at: entry.noteIndex, in: &$0.notes)
                        }
                    }
                    element = .chord(chord)
                }
            mscxDecoderWarn(
                code: "mscx.tie.unpairedSide",
                message: "<Spanner type=\"Tie\"> has no partner on the other end;"
                    + " dropping \(entry.side.rawValue) — MuseScore discards an"
                    + " unmatched connector side the same way",
                location: "Staff/Measure[\(group.measure + 1)]/voice[\(group.voice)]",
            )
        }
    }

    private static func clear(_ side: Side, at noteIndex: Int, in notes: inout ChordNotes) {
        guard notes.indices.contains(noteIndex) else { return }
        notes.updateNote(at: noteIndex) { note in
            switch side {
            case .forward: note.tieForward = nil
            case .back: note.tieBack = nil
            }
        }
    }
}
