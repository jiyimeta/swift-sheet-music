import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutDocument {
    /// Absolute document-coord stem origin for the chord at
    /// `voiceElementID`. Searches every system / measure / element
    /// and matches by `(measureIndex, voiceIndex, elementIndex)`.
    ///
    /// Returns `nil` when the location resolves to a non-chord element
    /// (e.g. a rest at that index) or when the index is out of range.
    public func chordStemOrigin(
        at id: VoiceElementID,
    ) -> CGPoint? {
        for system in systems {
            for measure in system.measures
                where measure.measureIndex == id.measureIndex
            {
                for el in measure.elements {
                    guard case let .chord(
                        notes, _, _, stemOrigin,
                        _, _, _, voiceIdx,
                    ) = el
                    else { continue }
                    guard voiceIdx == id.voiceIndex,
                          let firstNote = notes.first,
                          firstNote.noteID.staff == id.staff,
                          firstNote.noteID.elementIndex == id.elementIndex
                    else { continue }
                    return CGPoint(
                        x: system.origin.x + measure.origin.x + stemOrigin.x,
                        y: system.origin.y + measure.origin.y + stemOrigin.y,
                    )
                }
            }
        }
        return nil
    }

    /// Y (in document coords) where verse-0 lyrics are drawn for
    /// the chord at `voiceElementID`. Used to anchor an inline lyric
    /// editor exactly where the rendered glyph sits.
    ///
    /// Strategy:
    /// 1. If the chord already has a lyric textMark in the layout,
    ///    return that mark's `origin.y` — exact match.
    /// 2. Else fall back to the placement engine's per-system
    ///    baseline: 6 sp below the staff top (staff height = 4 sp,
    ///    plus a 2-sp lyric drop). This matches the un-ratcheted
    ///    `chordLyricCenterY` in `LayoutEngine+Placement`.
    public func lyricLineY(
        at voiceElementID: VoiceElementID,
    ) -> CGFloat? {
        let measureIndex = voiceElementID.measureIndex
        for system in systems {
            for measure in system.measures
                where measure.measureIndex == measureIndex
            {
                guard let staffIndex = system
                    .flatIndex(for: voiceElementID.staff),
                    system.staffOrigins.indices.contains(staffIndex)
                else { return nil }
                // Look for an existing lyric mark adjacent to the
                // chord. The placement engine emits all of a
                // measure's lyrics at the same Y (within a system),
                // so any lyric in this measure tells us the
                // ratcheted lyric line.
                for el in measure.elements {
                    if case let .textMark(.lyrics, _, p) = el {
                        return system.origin.y
                            + measure.origin.y + p.y
                    }
                }
                let staffTop = system.origin.y
                    + system.staffOrigins[staffIndex].y
                let sp = system.sp
                return staffTop + sp * 6
            }
        }
        return nil
    }
}
