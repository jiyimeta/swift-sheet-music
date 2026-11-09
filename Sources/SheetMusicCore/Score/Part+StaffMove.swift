import SheetMusicFoundation

extension Part {
    /// The move a chord or rest written with `staffMove` (`Chord.staffMove`) on staff `staffIndex` of this part is
    /// drawn with: `staffMove` itself when the staff it names can take the chord, 0 otherwise.
    ///
    /// MuseScore's `ChordRest::checkStaffMoveValidity` (`dom/chordrest.cpp:1302-1336`), which its 4.1+ readers run on
    /// every `<staffMove>` and its layout runs again per measure (`rendering/score/measurelayout.cpp:932-944`): the
    /// target staff has to exist inside the part, be visible (`Staff::visible`, here `Staff.isVisibleInScore`) and
    /// be of the same staff-type group as the chord's own (pitched, percussion, tablature). Its linked-staff check has
    /// nothing to compare here — this model has no linked staves. MuseScore 3 and 4.0 files were read with the part
    /// check alone (`rw/read400/tread.cpp:2471-2475`, a move out of the part reads as 0), which this includes.
    ///
    /// The value MuseScore remembers for a move it could not honor (`m_storedStaffMove`, re-applied once the target
    /// becomes valid) is simply `Chord.staffMove`, which keeps what the file says: only the drawing reads this.
    public func effectiveStaffMove(_ staffMove: Int, fromStaff staffIndex: Int) -> Int {
        guard staffMove != 0, staves.indices.contains(staffIndex) else { return 0 }
        let target = staffIndex + staffMove
        guard staves.indices.contains(target) else { return 0 }
        let home = staves[staffIndex]
        let other = staves[target]
        guard other.isVisibleInScore, other.group == home.group else { return 0 }
        return staffMove
    }

    /// Whether any chord or rest of this part is drawn on another of its staves — the question every pass that has a
    /// slower cross-staff path asks first, so a part without one keeps the per-staff path it always had.
    public var hasEffectiveStaffMoves: Bool {
        guard staves.count > 1 else { return false }
        for staffIndex in staves.indices {
            for measure in staves[staffIndex].measures {
                for voice in measure.voices {
                    for element in voice.elements {
                        if case let .chord(chord) = element, chord.staffMove != 0,
                           effectiveStaffMove(chord.staffMove, fromStaff: staffIndex) != 0
                        {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }
}

extension Score {
    /// `Part.effectiveStaffMove(_:fromStaff:)` for `chord`, written on the staff at `staff`; 0 for an address the
    /// score does not have.
    public func effectiveStaffMove(of chord: Chord, at staff: StaffAddress) -> Int {
        guard chord.staffMove != 0, parts.indices.contains(staff.partIndex) else { return 0 }
        return parts[staff.partIndex].effectiveStaffMove(chord.staffMove, fromStaff: staff.staffIndexInPart)
    }

    /// Every chord and rest of `staff` — once staff `oldIndex` of its part — moved onto a sibling staff
    /// (`Chord.staffMove`) re-expressed against the staves `filtered(hidingStaves:)` keeps: the same staff under its
    /// new index, or no move at all when that staff is gone, so the chord is drawn on its own staff as MuseScore
    /// draws a chord whose target staff is hidden (`ChordRest::checkStaffMoveValidity`). The move is relative, and
    /// left as it was it would name whichever staff took the hidden one's place.
    static func remapStaffMoves(in staff: inout Staff, from oldIndex: Int, keptIndexByOld: [Int: Int]) {
        guard let newIndex = keptIndexByOld[oldIndex] else { return }
        for measureIndex in staff.measures.indices {
            for voiceIndex in staff.measures[measureIndex].voices.indices {
                let elements = staff.measures[measureIndex].voices[voiceIndex].elements
                for elementIndex in elements.indices {
                    guard case var .chord(chord) = elements[elementIndex], chord.staffMove != 0 else { continue }
                    let remapped = keptIndexByOld[oldIndex + chord.staffMove].map { $0 - newIndex } ?? 0
                    guard remapped != chord.staffMove else { continue }
                    chord.staffMove = remapped
                    staff.measures[measureIndex].voices[voiceIndex].elements
                        .updateValue(at: elementIndex) { $0 = .chord(chord) }
                }
            }
        }
    }
}
