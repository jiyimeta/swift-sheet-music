import SheetMusicFoundation

/// Resolves a `ScoreTextID` to the `ElementProperties` it addresses, and writes them back, for
/// `SetElementOffset` and `SetElementAutoplace`.
///
/// This switch used to be copied in each command that needed it, encoding the same four lookup rules: a
/// lyric by verse inside its anchor chord, staff and system text by lane slot, harmony by harmony slot, and
/// a rehearsal mark by its lane index. `SetElementPlacement` was moved onto this shared helper.
/// `SetElementColor`, `SetTextFont` and `SetTextVisible` still carry their own copies of the same switch —
/// that was a deliberate scoping decision for this change, not an oversight, and routing them through here
/// too is an intended follow-up rather than completed work.
///
/// Refusals are NOT thrown here. `EditCommand.refused` stamps the calling command's type name as the refused
/// operation, so `update` reports absence as `false` and lets the caller throw with its own name.
enum TextElementProperties {
    /// Nil means the carrier is absent. A present carrier whose properties are entirely inherited still returns
    /// properties — the planner must distinguish these so clearing a missing target is refused rather than
    /// skipped as a no-op.
    static func current(_ text: ScoreTextID, in score: Score) -> ElementProperties? {
        switch text {
        case let .lyric(anchor, verse):
            return SetLyric.current(at: anchor, verse: verse, in: score)?.elementProperties
        case let .staffText(anchor, style):
            return SetStaffText.laneMark(at: anchor, isSystemText: style == .systemText, in: score)?
                .elementProperties
        case let .harmony(anchor):
            return SetChordSymbol.current(at: anchor, in: score)?.elementProperties
        case let .rehearsalMark(index):
            return RehearsalMarkLane.mark(in: score, measureIndex: index)?.elementProperties
        }
    }

    /// The voice slot a command addressing this text reports as its affected location. A rehearsal mark belongs
    /// to the system lane and has no voice slot of its own, so it reports the first slot of its measure on the
    /// first staff — the address `SetElementPlacement` has always reported for it.
    static func anchor(of text: ScoreTextID) -> VoiceElementID {
        switch text {
        case let .lyric(anchor, _), let .staffText(anchor, _), let .harmony(anchor):
            return anchor
        case let .rehearsalMark(index):
            return VoiceElementID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: index, voiceIndex: 0, elementIndex: 0,
            )
        }
    }

    /// Applies `change` to the addressed text's properties. Returns false when the carrier is absent, which is
    /// the caller's cue to throw its own `.targetNotFound`.
    @discardableResult
    static func update(
        _ text: ScoreTextID, in score: inout Score, _ change: (inout ElementProperties) -> Void,
    ) -> Bool {
        switch text {
        case let .lyric(anchor, verse):
            guard case var .chord(chord)? = score[anchor], chord.lyrics.indices.contains(verse) else {
                return false
            }
            change(&chord.lyrics[verse].elementProperties)
            score[anchor] = .chord(chord)
        case let .staffText(anchor, style):
            guard let slot = SetStaffText.laneSlot(
                at: anchor, isSystemText: style == .systemText, in: score,
            ), case var .staffText(mark) = score.systemMeasures[slot.measureIndex]
                .elements[slot.elementIndex].element
            else { return false }
            change(&mark.elementProperties)
            score.systemMeasures.updateValue(at: slot.measureIndex) {
                $0.elements.updateValue(at: slot.elementIndex) { $0.element = .staffText(mark) }
            }
        case let .harmony(anchor):
            guard let slot = SetChordSymbol.harmonySlot(at: anchor, in: score),
                  case var .harmony(harmony)? = score[slot]
            else { return false }
            change(&harmony.elementProperties)
            score[slot] = .harmony(harmony)
        case let .rehearsalMark(index):
            guard score.systemMeasures.indices.contains(index),
                  let slot = RehearsalMarkLane.markIndex(in: score.systemMeasures[index]),
                  case var .rehearsalMark(mark) = score.systemMeasures[index].elements[slot].element
            else { return false }
            change(&mark.elementProperties)
            score.systemMeasures.updateValue(at: index) {
                $0.elements.updateValue(at: slot) { $0.element = .rehearsalMark(mark) }
            }
        }
        return true
    }
}
