import Foundation
import SheetMusicCore

/// Pick the SMuFL flag glyph for an unbeamed note of the given duration
/// and stem direction.
///
/// `nil` for stemless durations (whole, measure rest, sub-eighth
/// fractions that don't map to a standard flag count). Renderers
/// branching on this only emit a flag when the result is non-nil and
/// the chord is not part of a beam group.
public enum FlagGlyph {
    public static func codepoint(
        duration: NoteDuration, stem: StemDirection,
    ) -> UInt32? {
        switch (duration, stem) {
        case (.eighth, .up): SMuFLCodepoint.flag8thUp
        case (.eighth, .down): SMuFLCodepoint.flag8thDown
        case (.sixteenth, .up): SMuFLCodepoint.flag16thUp
        case (.sixteenth, .down): SMuFLCodepoint.flag16thDown
        case (.thirtySecond, .up): SMuFLCodepoint.flag32ndUp
        case (.thirtySecond, .down): SMuFLCodepoint.flag32ndDown
        case (.sixtyFourth, .up): SMuFLCodepoint.flag64thUp
        case (.sixtyFourth, .down): SMuFLCodepoint.flag64thDown
        default: nil
        }
    }
}
