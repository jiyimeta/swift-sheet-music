import SheetMusicFoundation
import Wirelet

/// Self-describing binary format that ferries layout output across the JNI
/// boundary. Little-endian throughout. Both the Swift encoder and the Kotlin
/// decoder must agree on the magic + version; mismatches are fail-fast.
///
/// ### Wire layout (v6)
///
/// ```text
/// u32 magic       = 0x534D4450 ("SMDP")
/// u32 version     = 6
/// i32 pageCount
/// [page] × pageCount:
///     f64 widthMM
///     f64 heightMM
///     i32 commandCount
///     [command] × commandCount   ← @WireFormatChoice discriminator + payload
/// ```
///
/// The page list, page struct, command sum-type, and the `FontID` enum
/// inside `glyph` / `text` commands all derive their byte layout from the
/// `@WireFormat` family of macros — magic / version are validated by
/// `DrawProgramCodec` after the structural decode.
///
/// v4 swapped the hand-written opcode bytes (0x01…0x08) and `UInt16`
/// string length for the macro's declaration-order discriminator (0…7)
/// and `Int32` length prefix. Older decoders reject v4 with
/// `unsupportedVersion`; v3 readers and v4 readers are not wire-compatible.
///
///
/// v5 appended `.stretchedGlyph` (discriminator 8) for the system braces
/// at the left edge of each system — a non-uniformly stretched SMuFL glyph
/// the uniform `glyph` command can't express.
///
/// v6 appended three state/style opcodes (`setRotation`, `setDash`,
/// `italicText`, discriminators 9…11) so the bridge can draw arpeggios,
/// glissando labels, dashed ottava lines, and italic tuplet / rehearsal
/// text. Appending at the tail keeps existing discriminators 0…8 stable,
/// so older streams decode unchanged on a v6 reader; the version field
/// still gates an older decoder against a newer stream (a new opcode
/// would otherwise be an unknown discriminator).
///
/// v7 appended `setTextStyle` (discriminator 12), a state opcode
/// carrying a bold / italic bitmask. Before it the wire could not say
/// "bold" at all, so every renderer but Apple's drew MuseScore's bold
/// roles — tempo marks, rehearsal marks, instrument-change text — in
/// regular weight, and sized their frames from regular-weight metrics.
/// `italicText` (11) is superseded by it and no longer emitted; it stays
/// in the enum because removing a case renumbers nothing but deleting a
/// wire case is still a break for any decoder that handles it.
public enum DrawProgram {
    public static let magic: UInt32 = 0x534D_4450 // "SMDP"
    public static let version: UInt32 = 7

    @WireFormatEnum
    public enum FontID: UInt8, Sendable, CaseIterable, Equatable {
        case textRoman = 0x00 // body text (Edwin / system serif)
        case smufl = 0x01 // music glyphs (Bravura / Edwin SMuFL)
    }
}

/// One page worth of draw commands. The shape mirrors how the Kotlin
/// renderer paints — paint everything in `commands` onto a canvas sized
/// `widthMM × heightMM`.
@WireFormat
public struct EncodablePage: Sendable, Equatable {
    public var widthMM: Double
    public var heightMM: Double
    public var commands: [DrawCommand]

    public init(widthMM: Double, heightMM: Double, commands: [DrawCommand]) {
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.commands = commands
    }
}

/// One painter command. The encoded discriminator is the case's
/// declaration order (`moveTo` = 0 … `italicText` = 11). Reorder with
/// care: changes here are wire-breaking across the Kotlin boundary. Only
/// ever *append* new cases at the tail so existing discriminators hold.
@WireFormatChoice
public enum DrawCommand: Sendable, Equatable {
    case moveTo(x: Double, y: Double)
    case lineTo(x: Double, y: Double)
    case stroke(width: Double)
    case fillRect(x: Double, y: Double, w: Double, h: Double)
    case glyph(
        codepoint: UInt32,
        x: Double,
        y: Double,
        size: Double,
        fontId: DrawProgram.FontID,
    )
    case text(
        text: String,
        x: Double,
        y: Double,
        size: Double,
        fontId: DrawProgram.FontID,
    )
    /// Set the active paint color as a packed ARGB value
    /// (0xAARRGGBB). Affects every subsequent stroke / fill /
    /// glyph / text until the next `.setColor`.
    case setColor(argb: UInt32)
    /// Cubic Bezier curve from the current path point to (x, y) with
    /// control points (cx1, cy1) and (cx2, cy2).
    case cubicTo(
        cx1: Double, cy1: Double,
        cx2: Double, cy2: Double,
        x: Double, y: Double,
    )
    /// A SMuFL glyph stretched non-uniformly to fit a vertical span — the
    /// system brace at a system's left edge. The renderer measures the
    /// glyph's natural bounding box at `fontSize`, scales Y so the box
    /// spans `[topY, bottomY]`, scales X by `xScale` (MuseScore's brace
    /// `magx`), and positions the box's right edge at `rightEdgeX`. This
    /// mirrors `StaffRenderer.smuflGlyphPathStretched`; the uniform
    /// `glyph` command can't express the non-uniform stretch a brace needs.
    case stretchedGlyph(
        codepoint: UInt32,
        rightEdgeX: Double,
        topY: Double,
        bottomY: Double,
        fontSize: Double,
        xScale: Double,
        fontId: DrawProgram.FontID,
    )
    /// Rotate the canvas by `radians` about the pivot (document mm) for
    /// every subsequent command, until reset with `radians == 0`. A
    /// state opcode like `setColor`: emit the non-zero rotation, draw the
    /// rotated content, then emit `setRotation(0, 0, 0)` to restore.
    /// Used for arpeggio wiggles (90°) and glissando labels (gliss angle).
    case setRotation(radians: Double, pivotX: Double, pivotY: Double)
    /// Dash pattern for subsequent stroked paths, in document mm.
    /// `(0, 0)` clears it (solid). State opcode; reset after the dashed
    /// stroke. Used for the ottava line.
    case setDash(onMM: Double, offMM: Double)
    /// Italic text run — same payload as `text`, but the renderer slants
    /// the glyphs.
    ///
    /// SUPERSEDED by `setTextStyle` in v7 and no longer emitted. Kept so
    /// the discriminators after it do not move, and so a renderer that
    /// still handles it keeps compiling. A new emit site belongs in
    /// `setTextStyle` — one style channel, not two.
    case italicText(
        text: String,
        x: Double,
        y: Double,
        size: Double,
        fontId: DrawProgram.FontID,
    )
    /// Font style for every subsequent `text` and `glyph`, until the next
    /// `setTextStyle`. A state opcode, like `setColor` / `setDash` /
    /// `setRotation`: emit the style, draw, then emit `setTextStyle(0)`.
    ///
    /// `flags` is a bitmask — bit 0 bold, bit 1 italic — rather than two
    /// booleans, so a third trait (MuseScore styles also carry underline
    /// and strike) costs no wire change.
    ///
    /// This exists because the wire had no way to say "bold" at all, and
    /// MuseScore's own defaults make tempo marks, rehearsal marks and
    /// instrument-change text bold (`TextStyleType.museScoreDefault`).
    /// The Apple renderer has always applied them through
    /// `ResolvedTextStyle`; every other renderer drew regular weight.
    case setTextStyle(flags: UInt8)
}

extension DrawCommand {
    /// Bit positions in `setTextStyle`'s mask.
    public enum TextStyleFlag {
        public static let bold: UInt8 = 1 << 0
        public static let italic: UInt8 = 1 << 1
        /// The neutral style — what a renderer starts each page in, and what an emitter restores
        /// after a styled run.
        public static let none: UInt8 = 0
    }
}

/// Top-level encode / decode for a draw-program payload. The byte layout
/// is `magic | version | [EncodablePage]`; both header fields are
/// validated against the constants in `DrawProgram` after the structural
/// decode so format / version drift surfaces as a typed error instead of
/// a silent mis-parse.
public enum DrawProgramCodec {
    public enum DecodeError: Error, Equatable {
        case badMagic(UInt32)
        case unsupportedVersion(UInt32)
    }

    public static func encode(pages: [EncodablePage]) -> Data {
        DrawProgramWire(
            magic: DrawProgram.magic,
            version: DrawProgram.version,
            pages: pages,
        ).encodeToData()
    }

    public static func decode(_ data: Data) throws -> [EncodablePage] {
        let wire = try DrawProgramWire(decoding: data)
        guard wire.magic == DrawProgram.magic else {
            throw DecodeError.badMagic(wire.magic)
        }
        guard wire.version == DrawProgram.version else {
            throw DecodeError.unsupportedVersion(wire.version)
        }
        return wire.pages
    }
}

@WireFormat
package struct DrawProgramWire {
    var magic: UInt32
    var version: UInt32
    var pages: [EncodablePage]
}
