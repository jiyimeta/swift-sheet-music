import SheetMusicFoundation

/// SMuFL codepoint selector for chord-articulation glyphs: the staccato,
/// staccatissimo (plain, stroke, wedge), tenuto, accent, marcato, stress and
/// soft-accent families with their combined forms, plus the technique marks
/// MuseScore files under Articulations (brass mutes, harmonic, bow marks).
///
/// MuseScore stores each articulation with an explicit anchor side;
/// the above/below pairs share a shape mirrored across the baseline,
/// so the renderer just picks the variant with the matching anchor
/// and renders at the placement-supplied `origin`. A technique mark has
/// one form and always sits above, so both sides name the same glyph.
public enum ArticulationGlyph {
    public static func codepoint(
        kind: LayoutElement.ArticulationKind, isAbove: Bool,
    ) -> UInt32 {
        let (above, below) = pair(for: kind)
        return isAbove ? above : below
    }

    private typealias C = SMuFLCodepoint

    private static func pair(for kind: LayoutElement.ArticulationKind) -> (UInt32, UInt32) {
        switch kind {
        case .staccato: (C.articStaccatoAbove, C.articStaccatoBelow)
        case .staccatissimo: (C.articStaccatissimoAbove, C.articStaccatissimoBelow)
        case .tenuto: (C.articTenutoAbove, C.articTenutoBelow)
        case .accent: (C.articAccentAbove, C.articAccentBelow)
        case .marcato: (C.articMarcatoAbove, C.articMarcatoBelow)
        case .accentStaccato: (C.articAccentStaccatoAbove, C.articAccentStaccatoBelow)
        case .marcatoStaccato: (C.articMarcatoStaccatoAbove, C.articMarcatoStaccatoBelow)
        case .tenutoStaccato: (C.articTenutoStaccatoAbove, C.articTenutoStaccatoBelow)
        case .tenutoAccent: (C.articTenutoAccentAbove, C.articTenutoAccentBelow)
        case .marcatoTenuto: (C.articMarcatoTenutoAbove, C.articMarcatoTenutoBelow)
        case .staccatissimoStroke: (C.articStaccatissimoStrokeAbove, C.articStaccatissimoStrokeBelow)
        case .staccatissimoWedge: (C.articStaccatissimoWedgeAbove, C.articStaccatissimoWedgeBelow)
        case .stress: (C.articStressAbove, C.articStressBelow)
        case .unstress: (C.articUnstressAbove, C.articUnstressBelow)
        case .softAccent: (C.articSoftAccentAbove, C.articSoftAccentBelow)
        case .softAccentStaccato: (C.articSoftAccentStaccatoAbove, C.articSoftAccentStaccatoBelow)
        case .softAccentTenuto: (C.articSoftAccentTenutoAbove, C.articSoftAccentTenutoBelow)
        case .softAccentTenutoStaccato: (C.articSoftAccentTenutoStaccatoAbove, C.articSoftAccentTenutoStaccatoBelow)
        case .muteOpen: (C.brassMuteOpen, C.brassMuteOpen)
        case .muteClosed: (C.brassMuteClosed, C.brassMuteClosed)
        case .harmonic: (C.stringsHarmonic, C.stringsHarmonic)
        case .upBow: (C.stringsUpBow, C.stringsUpBow)
        case .downBow: (C.stringsDownBow, C.stringsDownBow)
        case .laissezVibrer: (C.articLaissezVibrerAbove, C.articLaissezVibrerBelow)
        }
    }
}
