extension Score {
    /// Clamp a key-signature value (sharps +, flats −) into the writable range `[-7, +7]` by enharmonic respelling
    /// (adding / removing 12 accidentals spells the same pitch set the other way). Brings a fifths-shifted key back to
    /// a notatable signature; e.g. `+8` (8 sharps, unwritable) → `-4` (A♭ major). Values already in range — including
    /// `±7` (C♯ / C♭ major) — are returned unchanged, so a deliberately sharp/flat context keeps its spelling.
    static func respelledKey(_ key: Int) -> Int {
        var k = key
        while k > 7 {
            k -= 12
        }
        while k < -7 {
            k += 12
        }
        return k
    }

    /// Returns a copy of the score transposed by `delta` semitones: every pitched note is shifted and every key
    /// signature re-spelled. A SINGLE global fifths offset (`φ ≡ 7·delta mod 12`) is chosen for the whole score and
    /// added to every key, so all modulation relationships are preserved by construction — the circle of fifths
    /// rotates uniformly. When no offset keeps every key inside the writable `[-7, +7]` range, `globalFifthsOffset`
    /// picks the offset that forces the *fewest measures* of music out of range, and the overflowing keys are
    /// respelled enharmonically. So a long D♭ section transposed +3 becomes E and the following B♭ section becomes
    /// C♯ (matching the sharp context), while a brief passing key is the one that respells.
    ///
    /// Each note's tonal pitch class shifts by `newKey − oldKey` (the same fifths the key moved), preserving its
    /// spelling relative to the key (a chromatic raise / lower stays a raise / lower; a diatonic note stays diatonic).
    /// The displayed accidental is recomputed against the destination key.
    ///
    /// Skipped, leaving pitch untouched: parts whose instrument `useDrumset` is true, and staves whose `group` is
    /// `"percussion"` (unpitched — transposing would re-map drum sounds). The active key per note is resolved at
    /// per-measure granularity via `activeKey(staff:measureIndex:)`. Grace notes transpose with their parent chord.
    ///
    /// Tick structure, note IDs, and element ordering are unchanged — only `pitch` / `tpc` / `accidental` and
    /// `KeySignature.concertKey` move — so playback cursors and seek positions stay valid against the transposed score.
    public func transposed(bySemitones delta: Int) -> Score {
        guard delta != 0 else { return self }
        let phi = globalFifthsOffset(bySemitones: delta)
        var copy = self
        for partIndex in copy.parts.indices {
            if copy.parts[partIndex].instrument.useDrumset { continue }
            for staffIndex in copy.parts[partIndex].staves.indices {
                if copy.parts[partIndex].staves[staffIndex].group == "percussion" {
                    continue
                }
                let address = StaffAddress(
                    partIndex: partIndex, staffIndexInPart: staffIndex,
                )
                let measures = copy.parts[partIndex].staves[staffIndex].measures
                for measureIndex in measures.indices {
                    let oldKey = activeKey(staff: address, measureIndex: measureIndex)
                    let newKey = Self.respelledKey(oldKey + phi)
                    let fifthsDelta = newKey - oldKey
                    let voices = copy.parts[partIndex].staves[staffIndex]
                        .measures[measureIndex].voices
                    for voiceIndex in voices.indices {
                        let elements = copy.parts[partIndex].staves[staffIndex]
                            .measures[measureIndex].voices[voiceIndex].elements
                        for elementIndex in elements.indices {
                            switch elements[elementIndex] {
                            case var .keySignature(k):
                                k.concertKey = Self.respelledKey(k.concertKey + phi)
                                copy.parts[partIndex].staves[staffIndex]
                                    .measures[measureIndex].voices[voiceIndex]
                                    .elements[elementIndex] = .keySignature(k)
                            case let .chord(c):
                                copy.parts[partIndex].staves[staffIndex]
                                    .measures[measureIndex].voices[voiceIndex]
                                    .elements[elementIndex] = .chord(Self.transposedChord(
                                        c, semitones: delta, fifthsDelta: fifthsDelta, key: newKey,
                                    ))
                            default:
                                break
                            }
                        }
                    }
                }
            }
        }
        return copy
    }

    /// Choose the single fifths offset (`≡ 7·delta mod 12`) added to every key signature. Among the ≤3 candidate
    /// offsets, picks the one that forces the fewest measures' worth of keys out of the writable `[-7, +7]` range
    /// (so a longer / more prominent key keeps its natural spelling and a brief passing modulation is the one
    /// respelled). Ties break toward fewer total accidentals, then toward the smaller shift.
    private func globalFifthsOffset(bySemitones delta: Int) -> Int {
        let hist = keyDurationHistogram()
        let residue = ((7 * delta) % 12 + 12) % 12
        let candidates = [residue - 12, residue, residue + 12]
        var best = residue
        var bestCost = Int.max
        var bestLoad = Int.max
        for offset in candidates {
            var cost = 0
            var load = 0
            for (key, weight) in hist {
                let shifted = key + offset
                let respelled = Self.respelledKey(shifted)
                if respelled != shifted { cost += weight }
                load += abs(respelled) * weight
            }
            if (cost, load, abs(offset)) < (bestCost, bestLoad, abs(best)) {
                bestCost = cost
                bestLoad = load
                best = offset
            }
        }
        return best
    }

    /// Tally how many measures each key signature is in effect, walking the first pitched staff once (key signatures
    /// are uniform across staves in tonal scores, and a global transpose rotates them all the same way). Weights the
    /// offset choice toward keeping prominent keys spelled naturally. Empty when the score has no pitched measures.
    private func keyDurationHistogram() -> [Int: Int] {
        for part in parts where !part.instrument.useDrumset {
            for staff in part.staves where staff.group != "percussion" {
                var hist: [Int: Int] = [:]
                var runningKey = 0
                for measure in staff.measures {
                    if let leading = measure.voices.first {
                        for element in leading.elements {
                            if case let .keySignature(k) = element {
                                runningKey = k.concertKey
                            }
                        }
                    }
                    hist[runningKey, default: 0] += 1
                }
                return hist
            }
        }
        return [:]
    }

    /// Transpose every note (and grace note) of `chord`. Each note is spelled in **its own** measure's key, so it keeps
    /// its original accidental policy (a chromatic raise / lower of a scale degree stays a raise / lower of the
    /// transposed degree; a diatonic note stays diatonic). Ties across a key change therefore may end up with
    /// different spellings on each side (e.g. E♯ tied to F) — that is intentional; the layout pairs ties by pitch,
    /// not spelling, so they stay connected.
    private static func transposedChord(
        _ chord: Chord, semitones: Int, fifthsDelta: Int, key: Int,
    ) -> Chord {
        var c = chord
        c.notes = ChordNotes(c.notes.map {
            transposedNote($0, semitones: semitones, fifthsDelta: fifthsDelta, key: key)
        })
        c.graceNotesBefore = c.graceNotesBefore.map {
            transposedGrace($0, semitones: semitones, fifthsDelta: fifthsDelta, key: key)
        }
        c.graceNotesAfter = c.graceNotesAfter.map {
            transposedGrace($0, semitones: semitones, fifthsDelta: fifthsDelta, key: key)
        }
        return c
    }

    private static func transposedGrace(
        _ grace: GraceChord, semitones: Int, fifthsDelta: Int, key: Int,
    ) -> GraceChord {
        var g = grace
        g.notes = ChordNotes(grace.notes.map {
            Self.transposedNote($0, semitones: semitones, fifthsDelta: fifthsDelta, key: key)
        })
        return g
    }

    /// Transpose a single note by `semitones`, preserving its spelling relative to the key: the tonal pitch class
    /// shifts by `fifthsDelta` (= newKey − oldKey on the line of fifths), so a chromatic raise / lower of a scale
    /// degree stays a raise / lower of the transposed degree (e.g. B♭ in G major → C♭ in A♭ major at `+1`, never B♮).
    /// The displayed accidental is recomputed against `key`. Returns the note unchanged if the shifted pitch would
    /// leave the MIDI range `0…127`.
    private static func transposedNote(
        _ note: Note, semitones: Int, fifthsDelta: Int, key: Int,
    ) -> Note {
        let newPitch = note.pitch + semitones
        guard (0 ... 127).contains(newPitch) else { return note }
        var n = note
        n.pitch = newPitch
        n.tpc = note.tpc + fifthsDelta
        n.accidental = PitchSpelling.displayedAccidental(forTpc: n.tpc, in: key)
        return n
    }

    /// Authored opening clef rawType for the staff at `address`: the explicit measure-0 clef when one exists, otherwise
    /// the staff's `defaultClefType`. Returns nil when the address points outside the score or the staff declares no
    /// default. Callers (e.g. the Reader's clef-override picker) layer their own fallback on top. Shared by iOS and the
    /// Android JNI parts/staves descriptor so both surface the same "current clef".
    public func authoredClef(at address: StaffAddress) -> String? {
        guard let staff = self[address] else { return nil }
        if let first = staff.measures.first?.voices.first?.elements.first,
           case let .clef(c) = first
        {
            return c.concertClefType
        }
        return staff.defaultClefType
    }

    /// Returns a copy of the score with the staves at the given addresses removed from each `Part.staves`. Parts left
    /// without any visible staff are dropped entirely so labels and brackets do not render against an empty group.
    ///
    /// Indexing is positional: a `StaffAddress(partIndex, staffIndexInPart)` resolves to
    /// `parts[partIndex].staves[staffIndexInPart]` on the pre-filter score.
    ///
    /// `BracketItem`s anchor on the topmost staff of their group with a `span` count of staves below them (see
    /// `BracketItem` in SheetMusicCore). Naively dropping staves loses the bracket when the anchor is hidden and
    /// miscounts the span when an interior staff is hidden, so brackets are re-anchored here against the surviving
    /// staves before the layout engine sees them.
    public func filtered(hidingStaves addresses: Set<StaffAddress>) -> Score {
        guard !addresses.isEmpty else { return self }
        var copy = self
        var newParts: [Part] = []
        for (partIndex, part) in parts.enumerated() {
            let keep: [Bool] = part.staves.indices.map { staffIndex in
                !addresses.contains(StaffAddress(
                    partIndex: partIndex, staffIndexInPart: staffIndex,
                ))
            }
            guard keep.contains(true) else { continue }

            var keptStaves: [Staff] = []
            var newIndexFor: [Int: Int] = [:]
            for (origIndex, staff) in part.staves.enumerated() where keep[origIndex] {
                newIndexFor[origIndex] = keptStaves.count
                var stripped = staff
                stripped.brackets = []
                keptStaves.append(stripped)
            }

            for (origIndex, staff) in part.staves.enumerated() {
                for bracket in staff.brackets {
                    let endOriginal = min(
                        origIndex + bracket.span - 1,
                        part.staves.count - 1,
                    )
                    let surviving = (origIndex ... endOriginal).filter { keep[$0] }
                    guard let firstOriginal = surviving.first,
                          let anchor = newIndexFor[firstOriginal]
                    else { continue }
                    var rebased = bracket
                    rebased.span = surviving.count
                    keptStaves[anchor].brackets.append(rebased)
                }
            }

            var newPart = part
            newPart.staves = keptStaves
            newParts.append(newPart)
        }
        copy.parts = newParts
        return copy
    }

    /// Returns a copy of the score with each staff's opening clef rewritten according to `clefOverrides`. The map is
    /// keyed by the pre-`filtered(hidingStaves:)` staff address — apply this transform *before* filtering, otherwise
    /// the filter's reindex invalidates the keys.
    ///
    /// For each `(staff, rawType)`:
    /// - If the staff's measure 0, voice 0, element 0 is an explicit
    ///   `<Clef>` voice element, that element's `concertClefType` is
    ///   rewritten to `rawType`. The `transposingClefType` is cleared
    ///   so the override doesn't collide with a stale transpose.
    /// - Otherwise `Staff.defaultClefType = rawType`. The layout
    ///   engine synthesizes the opening clef from this when no
    ///   explicit measure-0 clef is present.
    ///
    /// Mid-score clef changes (any explicit `<Clef>` element at position other than measure 0 / voice 0 / element 0)
    /// are not touched.
    ///
    /// Overrides targeting staves that don't exist in this score are skipped silently — no error, no crash.
    public func applying(clefOverrides: [StaffAddress: String]) -> Score {
        guard !clefOverrides.isEmpty else { return self }
        var copy = self
        for (address, rawType) in clefOverrides {
            guard copy.parts.indices.contains(address.partIndex) else { continue }
            guard copy.parts[address.partIndex].staves.indices
                .contains(address.staffIndexInPart) else { continue }
            let p = address.partIndex
            let s = address.staffIndexInPart
            if let firstElement = copy.parts[p].staves[s]
                .measures.first?.voices.first?.elements.first,
                case .clef = firstElement
            {
                copy.parts[p].staves[s].measures[0].voices[0].elements[0] =
                    .clef(Clef(concertClefType: rawType))
            } else {
                copy.parts[p].staves[s].defaultClefType = rawType
            }
        }
        return copy
    }
}
