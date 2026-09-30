/// SMuFL family name constants. Lives in the Foundation-only Layout target so every layer — the layout engine, the
/// bridges and the Apple renderers alike — names "Bravura" through this one spelling, and none of them has to import
/// `SheetMusicLayoutApple` to do it.
public enum SMuFLFamily {
    public static let bravura = "Bravura"
}
