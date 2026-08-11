import Foundation

/// Trill line subtype. Selects the SMuFL glyphs MuseScore repeats
/// along the marking and maps to the `<Trill><subtype>` token in the
/// MSCX format.
/// C++: `mu::engraving::TrillType` in `engraving/types/types.h:1168`;
/// the MSCX tokens come from `TRILL_TYPES` in `typesconv.cpp:3166`.
public enum TrillType: String, Sendable, Equatable, CaseIterable {
    /// `tr` sigil followed by a wiggle line.
    case trill
    case upprall
    case downprall
    /// Wiggle line with no leading sigil.
    case prallprall
}
