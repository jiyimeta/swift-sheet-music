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

    /// Final lyric row Y. An existing syllable wins; an empty editor can supply style
    /// and element properties without mixing a model address into the displayed document.
    /// Omitting that context retains the default-style fallback for existing callers.
    public func lyricLineY(
        at voiceElementID: VoiceElementID, verse: Int,
        placementStyle: TextPlacementStyles? = nil,
        elementProperties: ElementProperties = .default,
    ) -> CGFloat? {
        let style = placementStyle ?? TextPlacementStyles()
        let side = style.side(for: .lyrics, element: elementProperties)
        for system in systems {
            guard let measure = system.measures.first(where: { $0.measureIndex == voiceElementID.measureIndex }),
                  let staffIndex = system.flatIndex(for: voiceElementID.staff),
                  system.staffOrigins.indices.contains(staffIndex) else { continue }
            var candidates: [(verse: Int, side: Placement, y: CGFloat)] = []
            for el in measure.elements {
                guard case let .textMark(.lyrics(_, markVerse, anchor, metadata), _, point) = el,
                      anchor?.staff == voiceElementID.staff else { continue }
                let y = system.origin.y + measure.origin.y + point.y
                if anchor == voiceElementID, markVerse == verse { return y }
                candidates.append((markVerse, metadata?.side ?? .below, y))
            }
            if let exact = candidates
                .first(where: { $0.verse == verse && (placementStyle == nil || $0.side == side) })
            {
                return exact.y
            }
            let maxAboveVerse = system.measures.flatMap(\.elements).compactMap { element -> Int? in
                guard element.textPlacement?.side == .above,
                      element.textPlacement?.staff == voiceElementID.staff else { return nil }
                return element.textPlacement?.verse
            }.max() ?? 0
            if let nearest = candidates.filter({ $0.side == side })
                .min(by: { abs($0.verse - verse) < abs($1.verse - verse) }),
                side == .below || verse <= maxAboveVerse
            {
                return nearest.y + CGFloat(verse - nearest.verse) * system.sp * lyricVerseStrideInSpatiums
            }
            let position = style.position(for: .lyrics, side: side)
            let geometry = system.geometry(atFlatIndex: staffIndex)
            let edge = system.origin.y + system.staffOrigins[staffIndex].y
                + (side == .above ? 0 : geometry.height(sp: system.sp))
            let row = side == .above ? verse - max(verse, maxAboveVerse) : verse
            let baseline = CGPoint(
                x: 0,
                y: edge + CGFloat(position.y + (elementProperties.offset?.y ?? 0)) * system.sp
                    + CGFloat(row) * system.sp * lyricVerseStrideInSpatiums,
            )
            return LayoutEngine.textPlacementOrigin(
                text: "", font: TextInkGeometry.font(for: .lyricsOdd, metrics: metrics), baseline: baseline,
                center: true,
            ).y
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
