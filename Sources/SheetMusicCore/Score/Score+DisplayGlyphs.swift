import SheetMusicFoundation

/// The two glyph decisions the display transforms in `Score+DisplayTransforms.swift` make on top of moving pitches:
/// which clef a staff shows, and which accidental a moved note shows.
extension Score {
    /// Authored opening clef rawType for the staff at `address`: the explicit measure-0 clef when one exists, otherwise
    /// the staff's `defaultClefType`. Returns nil when the address points outside the score or the staff declares no
    /// default. Callers (e.g. the Reader's clef-override picker) layer their own fallback on top. Shared by iOS and the
    /// Android JNI parts/staves descriptor so both surface the same "current clef".
    ///
    /// An explicit clef answers with its `writtenClefType` — the one `writtenPitchView()` draws, and the same choice
    /// the MSCX decoder makes for `defaultClefType` (transposing default first).
    public func authoredClef(at address: StaffAddress) -> String? {
        guard let staff = self[address] else { return nil }
        if let first = staff.measures.first?.voices.first?.elements.first,
           case let .clef(c) = first
        {
            return c.writtenClefType
        }
        return staff.defaultClefType
    }

    /// Whether any clef element would draw differently once switched to its `writtenClefType`. Lets
    /// `writtenPitchView()` keep returning `self` for the common score that carries no such clef.
    func containsClefWithADistinctWrittenType() -> Bool {
        parts.contains { part in
            part.staves.contains { staff in
                staff.measures.contains { measure in
                    measure.voices.contains { voice in
                        voice.elements.contains { element in
                            guard case let .clef(clef) = element else { return false }
                            return clef.writtenClefType != clef.concertClefType
                        }
                    }
                }
            }
        }
    }

    /// Rewrite every clef element's `concertClefType` — the field layout reads — to its `writtenClefType`, in place.
    mutating func showWrittenClefs() {
        for partIndex in parts.indices {
            parts.updateValue(at: partIndex) { partValue in
                for staffIndex in partValue.staves.indices {
                    partValue.staves.updateValue(at: staffIndex) { staffValue in
                        for measureIndex in staffValue.measures.indices {
                            for voiceIndex in staffValue.measures[measureIndex].voices.indices {
                                let elements = staffValue.measures[measureIndex].voices[voiceIndex].elements
                                for elementIndex in elements.indices {
                                    guard case var .clef(clef) = elements[elementIndex],
                                          clef.writtenClefType != clef.concertClefType
                                    else { continue }
                                    clef.concertClefType = clef.writtenClefType
                                    staffValue.measures[measureIndex].voices[voiceIndex].elements
                                        .updateValue(at: elementIndex) { $0 = .clef(clef) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The glyph a transposed note shows: one exactly when the note had one, spelling its NEW alteration.
    ///
    /// Whether a note needs a glyph is decided by the bar — the key signature, overridden by every earlier
    /// accidental on the same staff line (`MeasureAccidentals`) — and `Note.accidental` stores that decision. A
    /// measure's notes and its key all move by the same interval, so lines stay lines and every alteration keeps its
    /// relation to the key: the set of notes that need a glyph is the same set. Re-deriving it from the key alone
    /// cannot see the bar, and drops the ♭ an A♭ needs after an A♮ earlier in the same bar.
    ///
    /// A glyph the tpc cannot spell (microtonal, a courtesy combination) passes through as stored, and an
    /// alteration no single glyph spells falls back to the key's answer.
    static func transposedAccidental(_ stored: Accidental?, tpc: Int, key: Int) -> Accidental? {
        guard let stored else { return nil }
        guard stored.isSpelledByTpc else { return stored }
        return PitchSpelling.accidental(spellingAlterationOf: tpc)
            ?? PitchSpelling.displayedAccidental(forTpc: tpc, in: key)
    }
}
