#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

extension LayoutDocument {
    /// Finds an engraved mark first, then resolves a blank editor through the same baseline
    /// placement as engraving. All addresses belong to this displayed document; callers read
    /// authored properties from their full score before passing the resulting value context.
    public func textEntryOrigin(
        kind: TextInputPlanner.Kind, at anchor: VoiceElementID, text: String,
        placementStyle: TextPlacementStyles = TextPlacementStyles(),
        elementProperties: ElementProperties = .default,
        textProperties: TextProperties = TextProperties(),
    ) -> CGPoint? {
        let engraved: CGPoint?
        switch kind {
        case .staffText: engraved = staffTextOrigin(at: anchor, style: .staffText)
        case .systemText: engraved = staffTextOrigin(at: anchor, style: .systemText)
        case .chordSymbol: engraved = harmonyOrigin(at: anchor)
        case .rehearsalMark: engraved = rehearsalMarkTextOrigin(at: anchor)
        }
        if let engraved { return engraved }
        guard text.trimmingWhitespaceAndNewlines().isEmpty,
              let timedOrigin = timedElementOrigin(at: anchor) else { return nil }
        let role: TextPlacementRole
        let textStyle: TextStyleType
        switch kind {
        case .staffText: (role, textStyle) = (.staffText, .staffText)
        case .systemText: (role, textStyle) = (.systemText, .systemText)
        case .chordSymbol: (role, textStyle) = (.harmonyA, .chordSymbolA)
        case .rehearsalMark: (role, textStyle) = (.rehearsalMark, .rehearsalMark)
        }
        for system in systems {
            guard let measure = system.measures.first(where: { $0.measureIndex == anchor.measureIndex }),
                  let anchorStaff = system.flatIndex(for: anchor.staff) else { continue }
            let index = kind == .systemText || kind == .rehearsalMark ? 0 : anchorStaff
            guard system.staffOrigins.indices.contains(index) else { continue }
            let padding = kind == .rehearsalMark ? RehearsalMarkFrame.paddingSp(sp: system.sp) : 0
            let x = kind == .rehearsalMark
                ? system.origin.x + measure.origin.x + system.sp * 0.5 + padding
                : timedOrigin.x
            let point = LayoutEngine.placedTextOrigin(
                text: "", role: role, properties: elementProperties, style: placementStyle, x: x,
                lineGeometry: system.geometry(atFlatIndex: index), metrics: metrics,
                font: TextInkGeometry.font(
                    for: textStyle, overrides: kind == .chordSymbol ? textProperties : TextProperties(),
                    metrics: metrics,
                ), center: kind == .chordSymbol,
            )
            return CGPoint(x: point.x, y: point.y + system.origin.y + system.staffOrigins[index].y - 2 * system.sp)
        }
        return nil
    }
}
