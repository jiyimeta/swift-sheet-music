#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

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
                        _, _, _, voiceIdx, _, _, _,
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

    /// Y (in document coords) where `verse` lyrics are drawn for the
    /// chord at `voiceElementID`. Used to anchor an inline lyric editor
    /// exactly where the rendered glyph sits.
    ///
    /// Strategy:
    /// 1. Prefer an existing verse-0 lyric mark, whose Y is the exact
    ///    base shared across the measure.
    /// 2. If only a higher verse is present, derive the base by removing
    ///    that mark's indexed verse offset.
    /// 3. Else fall back to the placement engine's per-system
    ///    baseline: 6 sp below the staff top (staff height = 4 sp,
    ///    plus a 2-sp lyric drop). This matches the un-ratcheted
    ///    `chordLyricCenterY` in `LayoutEngine+Placement`.
    public func lyricLineY(
        at voiceElementID: VoiceElementID,
        verse: Int,
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
                var higherVerseMark: (y: CGFloat, verse: Int)?
                for el in measure.elements {
                    if case let .textMark(
                        .lyrics(_, markVerse, _), _, p,
                    ) = el {
                        let y = system.origin.y + measure.origin.y + p.y
                        if markVerse == 0 {
                            return y + CGFloat(verse) * system.sp
                                * lyricVerseStrideInSpatiums
                        }
                        if higherVerseMark == nil {
                            higherVerseMark = (y, markVerse)
                        }
                    }
                }
                if let mark = higherVerseMark {
                    let verseZeroY = mark.y - CGFloat(mark.verse) * system.sp
                        * lyricVerseStrideInSpatiums
                    return verseZeroY + CGFloat(verse) * system.sp
                        * lyricVerseStrideInSpatiums
                }
                let staffTop = system.origin.y
                    + system.staffOrigins[staffIndex].y
                let sp = system.sp
                return staffTop + sp * 6
                    + CGFloat(verse) * sp * lyricVerseStrideInSpatiums
            }
        }
        return nil
    }

    /// Y (in document coords) where verse-0 lyrics are drawn for the
    /// chord at `voiceElementID`.
    public func lyricLineY(
        at voiceElementID: VoiceElementID,
    ) -> CGFloat? {
        lyricLineY(at: voiceElementID, verse: 0)
    }
}
