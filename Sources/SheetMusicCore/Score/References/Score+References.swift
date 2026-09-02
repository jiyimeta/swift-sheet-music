import SheetMusicFoundation

/// Resolution of the reference family (`MeasureRef`, `PartRef`, `VoiceRef`) against a `Score`. Commands and
/// planners reach the model only through these, so that SP0 rewires resolution in one place per reference kind.
///
/// Setters follow `subscript(id: VoiceElementID)`'s convention: a `nil` value or an out-of-range target is ignored
/// rather than trapped on, so a command's range check stays in its own `apply`.
extension Score {
    /// The staff that carries every measure-level flag — layout breaks, markers, jumps and repeat flags — the way
    /// MuseScore writes them under `writeSystemElements` on the first staff only. Layout reads breaks from
    /// `staves.first`; `MeasureFlagsHoist` keeps the flags here across part removals and moves.
    public static let canonicalStaff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// Whether `ref` names a measure column the score has.
    public func contains(_ ref: MeasureRef) -> Bool {
        ref.measureIndex >= 0 && ref.measureIndex < MeasureStructure.measureCount(of: self)
    }

    public subscript(part ref: PartRef) -> Part? {
        get {
            parts.indices.contains(ref.partIndex) ? parts[ref.partIndex] : nil
        }
        set {
            guard let newValue, parts.indices.contains(ref.partIndex) else { return }
            parts[ref.partIndex] = newValue
        }
    }

    public subscript(measure ref: MeasureRef, staff address: StaffAddress) -> Measure? {
        get {
            guard let staff = self[address], staff.measures.indices.contains(ref.measureIndex) else { return nil }
            return staff.measures[ref.measureIndex]
        }
        set {
            guard let newValue, parts.indices.contains(address.partIndex),
                  parts[address.partIndex].staves.indices.contains(address.staffIndexInPart),
                  parts[address.partIndex].staves[address.staffIndexInPart].measures.indices
                      .contains(ref.measureIndex)
            else { return }
            parts[address.partIndex].staves[address.staffIndexInPart].measures[ref.measureIndex] = newValue
        }
    }

    public subscript(voice ref: VoiceRef) -> Voice? {
        get {
            guard let measure = self[measure: MeasureRef(measureIndex: ref.measureIndex), staff: ref.staff],
                  measure.voices.indices.contains(ref.voiceIndex)
            else { return nil }
            return measure.voices[ref.voiceIndex]
        }
        set {
            guard let newValue,
                  var measure = self[measure: MeasureRef(measureIndex: ref.measureIndex), staff: ref.staff],
                  measure.voices.indices.contains(ref.voiceIndex)
            else { return }
            measure.voices[ref.voiceIndex] = newValue
            self[measure: MeasureRef(measureIndex: ref.measureIndex), staff: ref.staff] = measure
        }
    }

    /// The system-lane entry for a column, or `nil` while the lane is shorter than the score (an in-memory score
    /// leaves it empty; `RehearsalMarkLane.pad` grows it on first write).
    public subscript(system ref: MeasureRef) -> SystemMeasure? {
        get {
            systemMeasures.indices.contains(ref.measureIndex) ? systemMeasures[ref.measureIndex] : nil
        }
        set {
            guard let newValue, systemMeasures.indices.contains(ref.measureIndex) else { return }
            systemMeasures[ref.measureIndex] = newValue
        }
    }
}
