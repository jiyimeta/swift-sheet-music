import SheetMusicCore
import SheetMusicFoundation

/// SMuFL codepoint selection for breath marks and caesuras.
///
/// Unlike `FermataGlyph`'s prefix-based fallback over MuseScore raw
/// subtype strings, breath kinds are a closed enum (`Breath.Kind`),
/// so the mapping is exhaustive and no fallback is needed.
public enum BreathGlyph {
    public static func codepoint(forKind kind: Breath.Kind) -> UInt32 {
        switch kind {
        case .breathMark(.comma): return SMuFLCodepoint.breathMarkComma
        case .breathMark(.tick): return SMuFLCodepoint.breathMarkTick
        case .breathMark(.upbow): return SMuFLCodepoint.breathMarkUpbow
        case .breathMark(.salzedo): return SMuFLCodepoint.breathMarkSalzedo
        case .caesura(.normal): return SMuFLCodepoint.caesura
        case .caesura(.short): return SMuFLCodepoint.caesuraShort
        case .caesura(.thick): return SMuFLCodepoint.caesuraThick
        case .caesura(.curved): return SMuFLCodepoint.caesuraCurved
        }
    }
}
