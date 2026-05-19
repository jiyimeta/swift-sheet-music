/// SMuFL family name constants. Lives in the Foundation-only Layout
/// target so internal code (BraceMetrics, FermataGlyphMetrics,
/// HarmonyRendering) can reference "Bravura" without importing
/// `SheetMusicLayoutApple`. The Apple-side `BravuraFont.familyName`
/// is kept for external consumers and resolves to the same string.
public enum SMuFLFamily {
    public static let bravura = "Bravura"
}
