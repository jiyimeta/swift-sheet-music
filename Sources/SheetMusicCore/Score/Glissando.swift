import Foundation

/// A glissando attached to a note, pointing at the next chord's note.
/// C++: `mu::engraving::Glissando` (subset).
///
/// MuseScore stores glissandi as `<Spanner type="Glissando">` elements
/// inside a `<Note>`, with a nested `<Glissando>` block carrying the
/// visual and playback properties below.
public struct Glissando: Sendable, Equatable {
    /// The pitch-sequence rule for playback. C++: `GlissandoStyle`.
    public enum Style: Sendable, Equatable {
        /// Every semitone between start and end pitch.
        case chromatic
        /// Scale-degree steps in the current key signature.
        case diatonic
        /// Only piano white keys (C D E F G A B) between start and end pitch.
        case whiteKeys
        /// Only piano black keys (C♯ D♯ F♯ G♯ A♯) between start and end pitch.
        case blackKeys
        /// Continuous pitch bend (no discrete note events).
        case portamento
    }

    /// The visual rendering of the glissando line. C++: `GlissandoType`.
    public enum VisualType: Sendable, Equatable {
        case straight
        case wavy
    }

    public var style: Style
    public var visualType: VisualType
    /// Bezier ease-in percentage (0…100). 0 means linear timing.
    public var easeIn: Int
    /// Bezier ease-out percentage (0…100). 0 means linear timing.
    public var easeOut: Int
    /// Optional label drawn along the glissando line (e.g. "gliss.").
    public var text: String?

    public init(
        style: Style = .chromatic,
        visualType: VisualType = .straight,
        easeIn: Int = 0,
        easeOut: Int = 0,
        text: String? = nil,
    ) {
        self.style = style
        self.visualType = visualType
        self.easeIn = easeIn
        self.easeOut = easeOut
        self.text = text
    }
}
