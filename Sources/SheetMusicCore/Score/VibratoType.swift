import Foundation

/// Vibrato line subtype. Controls which SMuFL glyph is repeated along
/// the vibrato marking and maps to the `<Vibrato><subtype>` token in
/// MuseScore's MSCX format.
/// C++: `mu::engraving::VibratoType` in `engraving/types/types.h:1172-1178`.
public enum VibratoType: String, Sendable, Equatable, CaseIterable {
    case guitarVibrato
    case guitarVibratoWide
    /// Sawtooth wave. MSCX token `vibratoSawtooth`.
    case sawtooth = "vibratoSawtooth"
    /// Wide sawtooth wave. MSCX token `vibratoSawtoothWide`.
    case sawtoothWide = "vibratoSawtoothWide"
}
