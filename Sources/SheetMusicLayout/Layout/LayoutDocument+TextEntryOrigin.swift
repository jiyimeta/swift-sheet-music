#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutDocument {
    /// The final document-space origin of a chord stem or rest at `anchor`.
    /// Used only as a deterministic empty-editor fallback when no pending
    /// engraved text exists yet.
    public func timedElementOrigin(
        at anchor: VoiceElementID,
    ) -> CGPoint? {
        if let chord = chordStemOrigin(at: anchor) {
            return chord
        }
        let restID = RestID(
            staff: anchor.staff,
            measureIndex: anchor.measureIndex,
            voiceIndex: anchor.voiceIndex,
            elementIndex: anchor.elementIndex,
        )
        for system in systems {
            for measure in system.measures
                where measure.measureIndex == anchor.measureIndex
            {
                for element in measure.elements {
                    guard case let .rest(_, origin, _, candidate, _) = element,
                          candidate == restID
                    else { continue }
                    return absolute(
                        origin, in: system, measure: measure,
                    )
                }
            }
        }
        return nil
    }

    /// The final document-space origin of a staff- or system-text glyph.
    ///
    /// This is an example-grade lookup: text and role do not uniquely
    /// identify an element, so equal candidates are ranked by proximity to
    /// `anchor` and can still select the wrong one. Carrying element identity
    /// into layout is the durable fix.
    public func staffTextOrigin(
        at anchor: VoiceElementID,
        text: String,
        style: TextStyleType,
    ) -> CGPoint? {
        textEntryCandidate(
            in: anchor.measureIndex,
            nearestTo: timedAnchorX(at: anchor),
        ) { element in
            guard case let .staffText(
                candidate, origin, _, candidateStyle,
            ) = element,
                candidate == text,
                candidateStyle == style
            else { return nil }
            return origin
        }
    }

    /// The final document-space leading origin of a chord symbol.
    ///
    /// This has the same example-grade text-match limitation as
    /// `staffTextOrigin(at:text:style:)`; element identity is the durable fix.
    public func harmonyOrigin(
        at anchor: VoiceElementID,
        text: String,
    ) -> CGPoint? {
        textEntryCandidate(
            in: anchor.measureIndex,
            nearestTo: timedAnchorX(at: anchor),
        ) { element in
            guard case let .harmony(harmony) = element,
                  harmony.harmony.name == text
            else { return nil }
            return CGPoint(
                x: CGFloat(harmony.anchorX),
                y: CGFloat(harmony.y),
            )
        }
    }

    /// The final document-space origin of the rehearsal-mark text itself.
    ///
    /// A rehearsal mark's layout origin belongs to its frame. The renderer
    /// moves the bottom-leading text origin inward by the frame padding, so
    /// this accessor applies that same offset for an inline editing caret.
    public func rehearsalMarkTextOrigin(
        at anchor: VoiceElementID,
    ) -> CGPoint? {
        for system in systems {
            for measure in system.measures
                where measure.measureIndex == anchor.measureIndex
            {
                for element in measure.elements {
                    guard case let .rehearsalMark(
                        _, origin, _, _,
                    ) = element
                    else { continue }
                    let padding = RehearsalMarkFrame.paddingSp(sp: system.sp)
                    return absolute(
                        CGPoint(
                            x: origin.x + padding,
                            y: origin.y - padding,
                        ),
                        in: system,
                        measure: measure,
                    )
                }
            }
        }
        return nil
    }

    private func textEntryCandidate(
        in measureIndex: Int,
        nearestTo anchorX: CGFloat?,
        origin: (LayoutElement) -> CGPoint?,
    ) -> CGPoint? {
        var candidates: [CGPoint] = []
        for system in systems {
            for measure in system.measures
                where measure.measureIndex == measureIndex
            {
                candidates.append(contentsOf: measure.elements.compactMap {
                    guard let local = origin($0) else { return nil }
                    return absolute(local, in: system, measure: measure)
                })
            }
        }
        guard let anchorX else { return candidates.first }
        return candidates.min {
            abs($0.x - anchorX) < abs($1.x - anchorX)
        }
    }

    private func timedAnchorX(at anchor: VoiceElementID) -> CGFloat? {
        timedElementOrigin(at: anchor)?.x
    }

    private func absolute(
        _ origin: CGPoint,
        in system: LayoutSystem,
        measure: LayoutMeasure,
    ) -> CGPoint {
        CGPoint(
            x: system.origin.x + measure.origin.x + origin.x,
            y: system.origin.y + measure.origin.y + origin.y,
        )
    }
}
