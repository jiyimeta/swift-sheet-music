#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Pre-laid-out chord symbol. Rendering source of truth: the `runs`
/// array is built once at layout time so the renderer just walks
/// them; wrap / page-break decisions can read `width` without
/// re-measuring text.
public struct LayoutHarmony: Sendable, Equatable {
    public var harmony: Harmony
    /// Anchor x in system-relative coords (before `harmony.offsetX`
    /// is applied). The anchor is the chord/rest at the same tick.
    public var anchorX: Double
    /// Default y in staff-top-relative coords (before
    /// `harmony.offsetY`). Negative = above the staff top.
    public var y: Double
    public var runs: [HarmonyRun]
    /// Total typeset width across all runs, in points.
    public var width: Double
    /// The chord or rest this symbol names — the `VoiceElementID` `SetChordSymbol` takes, not the index of the
    /// `.harmony` voice element itself. The symbol sits immediately before the element it names in the voice
    /// stream (`AdjacentElementSlot`), so this is recovered at emission as the timed element starting at the
    /// symbol's own tick. Carrying it is what lets a caret address one of two symbols with the same name in a
    /// bar. `nil` when no timed element starts at that tick, which is the `<location>`-shifted case no
    /// text-entry command can reach either.
    public var anchor: VoiceElementID?

    public init(
        harmony: Harmony,
        anchorX: Double,
        y: Double,
        runs: [HarmonyRun],
        width: Double,
        anchor: VoiceElementID?,
    ) {
        self.harmony = harmony
        self.anchorX = anchorX
        self.y = y
        self.runs = runs
        self.width = width
        self.anchor = anchor
    }
}

/// One typesetting run inside a `LayoutHarmony`. Either a string
/// drawn in the harmony's text font, or a single SMuFL accidental
/// glyph drawn in Bravura.
public struct HarmonyRun: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        case accidental(HarmonyAccidental)
    }

    public var kind: Kind
    /// Text content for `.text` runs; ignored for `.accidental`.
    public var content: String
    /// Typeset advance in points (just this run).
    public var advance: Double
    /// Origin X relative to the harmony's anchor point, in points.
    public var x: Double

    public init(
        kind: Kind, content: String, advance: Double, x: Double,
    ) {
        self.kind = kind
        self.content = content
        self.advance = advance
        self.x = x
    }
}

/// The four accidentals that can appear inside a chord symbol's
/// name. Mapped to Bravura SMuFL codepoints at draw time. Kept in
/// the layout module (not the UI module) so layout-time width
/// measurement and renderer dispatch agree on a single typed enum.
public enum HarmonyAccidental: Sendable, Equatable {
    case flat
    case doubleFlat
    case sharp
    case doubleSharp

    /// SMuFL Bravura codepoint. Mirrors `SMuFLGlyph.accidental*`
    /// in `SheetMusicUI` (kept duplicated to avoid the layout →
    /// UI dependency).
    public var codepoint: Character {
        switch self {
        case .flat: "\u{E260}"
        case .doubleFlat: "\u{E264}"
        case .sharp: "\u{E262}"
        case .doubleSharp: "\u{E263}"
        }
    }
}
