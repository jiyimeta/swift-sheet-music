import SheetMusicFoundation

/// A breath written at the HEAD of a bar — ahead of the bar's first chord, with nothing before it but the bar's
/// opening signatures and other breaths — stands at the tick where the bar before it ends, so it follows that bar's
/// last chord.
///
/// MuseScore writes a breath it adds into the chord's own bar, at the chord's end tick (`ChordRest::drop`,
/// `chordrest.cpp:207`), and that is where `SetBreath` writes one too. A file can still carry one at the head of the
/// next bar: MuseScore's element paste re-homes a pasted `<Breath>` by its tick alone (`read460.cpp:958`), without the
/// "a bar-start tick belongs to the bar before" correction its range paste and its linked-staff copy make
/// (`read460.cpp:719`, `edit.cpp:7321`), and its reader keeps a `<Breath>` in the bar it is written in
/// (`measureread.cpp:328`). This package keeps it where the file put it — it draws and plays there — and names it
/// the way those corrections do: by the chord ending the bar before. That is what lets `SetBreath(after:)` on that
/// chord replace and remove it, and what gives its engraved glyph an identity to select.
extension Voice {
    /// Indices of the breaths at the head of this voice — before its first element that is neither a breath nor a
    /// leading signature (`MeasureStructure.isLeadingSignature`), in order. Empty when the voice opens any other way.
    package var barHeadBreathIndices: [Int] {
        var indices: [Int] = []
        for index in elements.indices {
            let element = elements[index]
            if case .breath = element {
                indices.append(index)
            } else if !MeasureStructure.isLeadingSignature(element) {
                break
            }
        }
        return indices
    }

    /// The index of the chord or rest a breath at the head of the NEXT bar's same voice follows: this voice's last
    /// timed element — a rest owns a breath as a chord does, within a bar and across it (`SetBreath`). `nil` when the
    /// voice ends on a measure repeat or a location shift, or holds no chord or rest at all.
    package var barEndBreathOwnerIndex: Int? {
        for index in elements.indices.reversed() {
            switch elements[index] {
            case .chord:
                return index
            case .measureRepeat, .locationShift:
                return nil
            default:
                continue
            }
        }
        return nil
    }
}
