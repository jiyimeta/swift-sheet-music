extension Score {
    /// Transpose a key-signature accidental count (`-7…+7`, flats negative) by `delta` semitones along the circle of
    /// fifths. One semitone up = +7 positions (7 fifths). The result is normalized to `[-6, +6]` so the simpler
    /// enharmonic spelling wins (e.g. C +1 → Db (-5), not C# (+7)); adding/removing 12 accidentals is an enharmonic
    /// respelling of the same pitch set, so this never changes which pitches sound — only how the key is written.
    static func transposedKey(_ key: Int, bySemitones delta: Int) -> Int {
        var k = key + 7 * delta
        while k > 6 {
            k -= 12
        }
        while k < -6 {
            k += 12
        }
        return k
    }

    /// Returns a copy of the score with every pitched note shifted by `delta` semitones and every key signature
    /// transposed to match. Notes are re-spelled against the **destination** key via
    /// `Note.shifted(bySemitones:in:)`, so the engraving reads in the new key rather than as a wall of accidentals.
    ///
    /// Skipped, leaving pitch untouched:
    /// - parts whose instrument `useDrumset` is true, and
    /// - staves whose `group` is `"percussion"` (unpitched — transposing would re-map drum sounds).
    ///
    /// The active key per note is resolved at **per-measure** granularity via `activeKey(staff:measureIndex:)`,
    /// matching the coarsening the arrow-key transpose already uses; mid-measure key changes (rare) take effect from
    /// their measure start. Grace notes are transposed alongside their parent chord.
    ///
    /// Tick structure, note IDs, and element ordering are unchanged — only `pitch` / `tpc` / `accidental` and
    /// `KeySignature.concertKey` move — so playback cursors and seek positions stay valid against the transposed score.
    public func transposed(bySemitones delta: Int) -> Score {
        guard delta != 0 else { return self }
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
                    let newKey = Self.transposedKey(oldKey, bySemitones: delta)
                    let voices = copy.parts[partIndex].staves[staffIndex]
                        .measures[measureIndex].voices
                    for voiceIndex in voices.indices {
                        let elements = copy.parts[partIndex].staves[staffIndex]
                            .measures[measureIndex].voices[voiceIndex].elements
                        for elementIndex in elements.indices {
                            switch elements[elementIndex] {
                            case var .keySignature(k):
                                k.concertKey = Self.transposedKey(
                                    k.concertKey, bySemitones: delta,
                                )
                                copy.parts[partIndex].staves[staffIndex]
                                    .measures[measureIndex].voices[voiceIndex]
                                    .elements[elementIndex] = .keySignature(k)
                            case var .chord(c):
                                c.notes = ChordNotes(c.notes.map {
                                    $0.shifted(bySemitones: delta, in: newKey) ?? $0
                                })
                                c.graceNotesBefore = c.graceNotesBefore.map {
                                    Self.transposedGrace($0, delta: delta, key: newKey)
                                }
                                c.graceNotesAfter = c.graceNotesAfter.map {
                                    Self.transposedGrace($0, delta: delta, key: newKey)
                                }
                                copy.parts[partIndex].staves[staffIndex]
                                    .measures[measureIndex].voices[voiceIndex]
                                    .elements[elementIndex] = .chord(c)
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

    private static func transposedGrace(
        _ grace: GraceChord, delta: Int, key: Int,
    ) -> GraceChord {
        var g = grace
        g.notes = ChordNotes(grace.notes.map {
            $0.shifted(bySemitones: delta, in: key) ?? $0
        })
        return g
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
