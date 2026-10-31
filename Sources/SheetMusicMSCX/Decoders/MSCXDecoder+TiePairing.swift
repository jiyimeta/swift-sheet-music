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
/// The model's tie is presence-only — `Note.tieForward` / `Note.tieBack`
/// carry no pointer — so every consumer pairs the two ends by the same
/// rules: the voice's own adjacency, `CrossVoiceTies` for a tie into
/// another voice of the staff, and `DetachedTies` for a tie into another
/// staff of the part or past the chords in between. This pass keeps a
/// side exactly when those rules give it a partner, so what is kept is
/// what layout, playback and the writer will pair. The file's own word
/// on each side's partner (`MSCXTieSide`) is used twice: a detached link
/// the file contradicts is not taken, and a side that is dropped is
/// reported under a code naming the shape of its tie.
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
        var grace: MSCXTieSide.Grace?
        /// Indices into that run's notes, in note order.
        var forward: [Int]
        var back: [Int]
        /// No tie may cross from the preceding group into this one — a rest
        /// sits between them, or the voice is absent from the bars between.
        var severedFromPrevious: Bool
    }

    /// Clear every `tieForward` / `tieBack` of the part whose staves hold `staves` that has no partner, reporting each.
    ///
    /// `sides` is what the file wrote about each tie side (`Voice.DecodeResult.tieSides`, addressed down to the staff).
    static func pruningUnpairedTies(in staves: [[Measure]], sides: [MSCXTieSide]) -> [[Measure]] {
        var staves = staves
        let file = FileSides(sides)
        // Each round clears what it finds and looks again: a side dropped here can free, or take away, the partner of
        // another. Every round clears at least one flag, so this ends; the bound is a guard, not a budget.
        for _ in 0 ..< 16 {
            let detached = DetachedTies.links(in: staves)
            // A detached tie the file names a different partner for is not one the file has: MuseScore would leave
            // its forward side unmatched.
            var cleared = detached.filter { !file.agrees($0, in: staves) }.map { link in
                Unpaired(
                    staff: link.from.staff, measure: link.from.measure, voice: link.from.voice,
                    element: link.from.element, grace: nil, noteIndex: link.from.note, side: .forward,
                )
            }
            if cleared.isEmpty {
                cleared = unpairedInVoices(of: staves, detached: detached)
            }
            guard !cleared.isEmpty else { break }
            for entry in cleared {
                report(entry, in: staves, file: file)
            }
            apply(cleared, to: &staves)
        }
        return staves
    }

    /// The tie sides no rule pairs, staff by staff and voice by voice.
    ///
    /// A tie MuseScore made into another voice (`CrossVoiceTies`) or another staff or past other chords
    /// (`DetachedTies`) has its partner there; its two ends are taken out of their voices' own pairing first, so they
    /// neither count as unmatched nor take the place of a tie that does stay in the voice.
    private static func unpairedInVoices(of staves: [[Measure]], detached: [DetachedTies.Link]) -> [Unpaired] {
        var result: [Unpaired] = []
        for (staffIndex, measures) in staves.enumerated() {
            let links = CrossVoiceTies.links(in: measures)
            let elsewhere = ElsewhereEnds(
                forward: Set(links.map(\.from) + detached.filter { $0.from.staff == staffIndex }.map(\.from.inStaff)),
                back: Set(links.map(\.to) + detached.filter { $0.to.staff == staffIndex }.map(\.to.inStaff)),
            )
            let voiceCount = measures.map(\.voices.count).max() ?? 0
            for voiceIndex in 0 ..< voiceCount {
                let groups = collectGroups(in: measures, voiceIndex: voiceIndex, elsewhere: elsewhere)
                result += unpaired(in: groups, staff: staffIndex)
            }
        }
        return result
    }

    /// The notes whose tie leaves or reaches another voice or staff — each side by itself, since one note can end a
    /// tie from elsewhere and start one in its own voice.
    private struct ElsewhereEnds {
        var forward: Set<CrossVoiceTies.End>
        var back: Set<CrossVoiceTies.End>
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
        in measures: [Measure], voiceIndex: Int, elsewhere: ElsewhereEnds,
    ) -> [Group] {
        var groups: [Group] = []
        var severed = true
        func append(
            measure: Int, element: Int, grace: MSCXTieSide.Grace?, notes: ChordNotes,
            skippableWhenUntied: Bool,
        ) {
            func end(_ note: Int) -> CrossVoiceTies.End {
                CrossVoiceTies.End(measure: measure, voice: voiceIndex, element: element, note: note)
            }
            let forward = notes.indices.filter {
                notes[$0].tieForward != nil && (grace != nil || !elsewhere.forward.contains(end($0)))
            }
            let back = notes.indices.filter {
                notes[$0].tieBack != nil && (grace != nil || !elsewhere.back.contains(end($0)))
            }
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

    /// One note whose tie side has no partner.
    private struct Unpaired {
        var staff: Int
        var measure: Int
        var voice: Int
        var element: Int
        var grace: MSCXTieSide.Grace?
        var noteIndex: Int
        var side: MSCXTieSide.Side
    }

    /// Pair adjacent groups first-come-first-served — the i-th tie out of a
    /// chord answers the i-th tie into the next one, which is the pairing
    /// `MidiRenderer.resolvingTiedPitches` already walks. Whatever is left
    /// over on either side of the edge has no partner.
    private static func unpaired(in groups: [Group], staff: Int) -> [Unpaired] {
        var result: [Unpaired] = []
        func entry(_ group: Group, _ noteIndex: Int, _ side: MSCXTieSide.Side) -> Unpaired {
            Unpaired(
                staff: staff, measure: group.measure, voice: group.voice, element: group.element,
                grace: group.grace, noteIndex: noteIndex, side: side,
            )
        }
        for index in groups.indices {
            let connectedToNext = index + 1 < groups.count
                && !groups[index + 1].severedFromPrevious
            let backCount = connectedToNext ? groups[index + 1].back.count : 0
            for noteIndex in groups[index].forward.dropFirst(
                min(groups[index].forward.count, backCount),
            ) {
                result.append(entry(groups[index], noteIndex, .forward))
            }

            let connectedToPrevious = index > 0 && !groups[index].severedFromPrevious
            let forwardCount = connectedToPrevious ? groups[index - 1].forward.count : 0
            for noteIndex in groups[index].back.dropFirst(
                min(groups[index].back.count, forwardCount),
            ) {
                result.append(entry(groups[index], noteIndex, .back))
            }
        }
        return result
    }

    private static func apply(_ unpaired: [Unpaired], to staves: inout [[Measure]]) {
        for entry in unpaired {
            guard staves.indices.contains(entry.staff),
                  staves[entry.staff].indices.contains(entry.measure),
                  staves[entry.staff][entry.measure].voices.indices.contains(entry.voice)
            else { continue }
            staves[entry.staff][entry.measure].voices[entry.voice].elements
                .updateValue(at: entry.element) { element in
                    guard case var .chord(chord) = element else { return }
                    switch entry.grace {
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
        }
    }

    private static func clear(_ side: MSCXTieSide.Side, at noteIndex: Int, in notes: inout ChordNotes) {
        guard notes.indices.contains(noteIndex) else { return }
        notes.updateNote(at: noteIndex) { note in
            switch side {
            case .forward: note.tieForward = nil
            case .back: note.tieBack = nil
            }
        }
    }

    /// The notes of the run `entry` names, when it still exists.
    private static func notes(of entry: Unpaired, in staves: [[Measure]]) -> ChordNotes? {
        guard staves.indices.contains(entry.staff),
              staves[entry.staff].indices.contains(entry.measure),
              staves[entry.staff][entry.measure].voices.indices.contains(entry.voice),
              staves[entry.staff][entry.measure].voices[entry.voice].elements.indices.contains(entry.element),
              case let .chord(chord) = staves[entry.staff][entry.measure].voices[entry.voice].elements[entry.element]
        else { return nil }
        switch entry.grace {
        case nil:
            return chord.notes
        case let .before(index):
            return chord.graceNotesBefore.indices.contains(index) ? chord.graceNotesBefore[index].notes : nil
        case let .after(index):
            return chord.graceNotesAfter.indices.contains(index) ? chord.graceNotesAfter[index].notes : nil
        }
    }

    // MARK: - Reporting

    private static func report(_ entry: Unpaired, in staves: [[Measure]], file: FileSides) {
        guard let notes = notes(of: entry, in: staves), notes.indices.contains(entry.noteIndex) else { return }
        let pitch = notes[entry.noteIndex].pitch
        let address = MSCXTieSide.Address(
            staff: entry.staff, measure: entry.measure, voice: entry.voice, element: entry.element,
            grace: entry.grace, pitch: pitch,
        )
        let shape = MSCXUnpairedTieShape(
            file.side(at: address, entry.side), side: entry.side, measures: staves[entry.staff],
        )
        mscxDecoderWarn(
            code: shape.code,
            message: shape.message(side: entry.side, pitch: pitch),
            location: "Staff[\(entry.staff + 1)]/Measure[\(entry.measure + 1)]/voice[\(entry.voice)]",
        )
    }

    // MARK: - The file's word

    /// The tie sides the file wrote, by where each sits.
    private struct FileSides {
        private struct Key: Hashable {
            var address: MSCXTieSide.Address
            var side: MSCXTieSide.Side
        }

        private var byKey: [Key: MSCXTieSide] = [:]

        init(_ sides: [MSCXTieSide]) {
            for side in sides {
                let key = Key(address: side.address, side: side.side)
                if byKey[key] == nil { byKey[key] = side }
            }
        }

        func side(at address: MSCXTieSide.Address, _ side: MSCXTieSide.Side) -> MSCXTieSide? {
            byKey[Key(address: address, side: side)]
        }

        /// Whether the file names the two ends of `link` as each other's partner — or says nothing either way.
        func agrees(_ link: DetachedTies.Link, in staves: [[Measure]]) -> Bool {
            guard let from = side(at: link.from, .forward, in: staves),
                  let to = side(at: link.to, .back, in: staves)
            else { return true }
            let verdicts = [from.names(to), to.names(from)].compactMap(\.self)
            return verdicts.isEmpty || verdicts.contains(true)
        }

        private func side(
            at end: DetachedTies.End, _ side: MSCXTieSide.Side, in staves: [[Measure]],
        ) -> MSCXTieSide? {
            guard staves.indices.contains(end.staff),
                  staves[end.staff].indices.contains(end.measure),
                  staves[end.staff][end.measure].voices.indices.contains(end.voice),
                  staves[end.staff][end.measure].voices[end.voice].elements.indices.contains(end.element),
                  case let .chord(chord) = staves[end.staff][end.measure].voices[end.voice].elements[end.element],
                  chord.notes.indices.contains(end.note)
            else { return nil }
            return self.side(at: MSCXTieSide.Address(
                staff: end.staff, measure: end.measure, voice: end.voice, element: end.element, grace: nil,
                pitch: chord.notes[end.note].pitch,
            ), side)
        }
    }
}

extension MSCXTieSide {
    /// Whether what this side says about its partner points at `other` — nil when it says nothing that can be checked
    /// against it.
    func names(_ other: MSCXTieSide) -> Bool? {
        switch (partner, other.partner) {
        case let (.location(location), _):
            guard address.grace == nil, other.address.grace == nil, location.grace == nil else { return nil }
            return address.staff + location.staves == other.address.staff
                && address.voice + location.voices == other.address.voice
                && address.measure + location.measures == other.address.measure
                && start + location.fractions == other.start
        case let (.legacyID(id?), .legacyID(otherID?)):
            return id == otherID
        case let (.museScore5(eid), .museScore5(otherEID)):
            return eid == otherEID
        default:
            return nil
        }
    }
}
