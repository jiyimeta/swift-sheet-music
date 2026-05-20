import Foundation

/// SMuFL codepoint selector for chord-articulation glyphs (staccato,
/// staccatissimo, tenuto, accent, marcato, plus the accent+staccato
/// and marcato+staccato combined variants).
///
/// MuseScore stores each articulation with an explicit anchor side;
/// the above/below pairs share a shape mirrored across the baseline,
/// so the renderer just picks the variant with the matching anchor
/// and renders at the placement-supplied `origin`.
public enum ArticulationGlyph {
    public static func codepoint(
        kind: LayoutElement.ArticulationKind, isAbove: Bool,
    ) -> UInt32 {
        switch (kind, isAbove) {
        case (.staccato, true): return SMuFLCodepoint.articStaccatoAbove
        case (.staccato, false): return SMuFLCodepoint.articStaccatoBelow
        case (.staccatissimo, true): return SMuFLCodepoint.articStaccatissimoAbove
        case (.staccatissimo, false): return SMuFLCodepoint.articStaccatissimoBelow
        case (.tenuto, true): return SMuFLCodepoint.articTenutoAbove
        case (.tenuto, false): return SMuFLCodepoint.articTenutoBelow
        case (.accent, true): return SMuFLCodepoint.articAccentAbove
        case (.accent, false): return SMuFLCodepoint.articAccentBelow
        case (.marcato, true): return SMuFLCodepoint.articMarcatoAbove
        case (.marcato, false): return SMuFLCodepoint.articMarcatoBelow
        case (.accentStaccato, true):
            return SMuFLCodepoint.articAccentStaccatoAbove
        case (.accentStaccato, false):
            return SMuFLCodepoint.articAccentStaccatoBelow
        case (.marcatoStaccato, true):
            return SMuFLCodepoint.articMarcatoStaccatoAbove
        case (.marcatoStaccato, false):
            return SMuFLCodepoint.articMarcatoStaccatoBelow
        }
    }
}
