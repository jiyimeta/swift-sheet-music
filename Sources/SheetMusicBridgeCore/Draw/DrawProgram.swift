import SheetMusicFoundation
import Wirelet

/// Self-describing binary format that ferries layout output across the JNI
/// boundary. Little-endian throughout. Both the Swift encoder and the Kotlin
/// decoder must agree on the magic + version; mismatches are fail-fast.
///
/// ### Wire layout (v8)
///
/// ```text
/// u32 magic       = 0x534D4450 ("SMDP")
/// u32 version     = 8
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
/// v6 appended three state/style opcodes (`setRotation`, `setDash` and an italic text run, discriminators 9…11) so
/// the bridge can draw arpeggios, glissando labels, dashed ottava lines, and italic tuplet / rehearsal text. Appending
/// at the tail keeps existing discriminators 0…8 stable, so older streams decode unchanged on a v6 reader; the version
/// field still gates an older decoder against a newer stream (a new opcode would otherwise be an unknown
/// discriminator).
///
/// v7 appended `setTextStyle` (discriminator 12), a state opcode carrying a bold / italic bitmask. Before it the wire
/// could not say "bold" at all, so every renderer but Apple's drew MuseScore's bold roles — tempo marks, rehearsal
/// marks, instrument-change text — in regular weight, and sized their frames from regular-weight metrics.
///
/// v8 removed the italic text run v7 had superseded, so `setTextStyle` moved from 12 to 11, and appended `fillPath`
/// (12), the fill terminator beams are drawn with. It also added `FontID.system` and the `semibold` style bit, so a
/// text command names the face the layout measured it in. Removing a case renumbers what follows it, so the version
/// field is what keeps a v7 reader from taking v8's discriminators 11 and 12 for its own.
public enum DrawProgram {
    public static let magic: UInt32 = 0x534D_4450 // "SMDP"
    public static let version: UInt32 = 8

    /// The face a `glyph` / `text` / `stretchedGlyph` command is drawn in — the face the layout measured it in, which
    /// `TextFontMapping` derives from the resolved `LayoutFont`. Weight is not part of the id; it travels in
    /// `setTextStyle`.
    ///
    /// The codecs carry the raw value, and the Kotlin `FontID` enums map it by ordinal, so declaration order must
    /// match the raw values.
    @WireFormatEnum
    public enum FontID: UInt8, Sendable, CaseIterable, Equatable {
        case textRoman = 0x00 // body text (Edwin / system serif)
        case smufl = 0x01 // music glyphs (Bravura / Edwin SMuFL)
        /// The platform UI family — SF on Apple, Segoe UI on Windows. A reader without one draws the text face.
        case system = 0x02
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

/// One painter command. The encoded discriminator is the case's declaration order (`moveTo` = 0 … `setTextStyle` =
/// 11, `fillPath` = 12), and `DrawProgramFlat`'s opcodes mirror it. Reorder with care: changes here are wire-breaking
/// across the Kotlin and JavaScript boundaries. Only ever *append* new cases at the tail so existing discriminators
/// hold; removing one renumbers everything after it and needs a version bump in both encodings.
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
    /// Font style for every subsequent `text` and `glyph`, until the next
    /// `setTextStyle`. A state opcode, like `setColor` / `setDash` /
    /// `setRotation`: emit the style, draw, then emit `setTextStyle(0)`.
    ///
    /// `flags` is a bitmask (`TextStyleFlag`: bit 0 bold, bit 1 italic, bit 2 semibold) rather than booleans, so a
    /// further trait (MuseScore styles also carry underline and strike) costs no wire change.
    ///
    /// This exists because the wire had no way to say "bold" at all, and
    /// MuseScore's own defaults make tempo marks, rehearsal marks and
    /// instrument-change text bold (`TextStyleType.museScoreDefault`).
    /// The Apple renderer has always applied them through
    /// `ResolvedTextStyle`; every other renderer drew regular weight.
    case setTextStyle(flags: UInt8)
    /// Fill the path built since the last `moveTo` (by `lineTo` / `cubicTo`) and end it, as `stroke` does. The
    /// path closes implicitly and fills with the nonzero winding rule in the current `setColor`; `setDash` does not
    /// apply. No payload, so it fits the flat encoding's fixed record — a four-corner `fillQuad` would need eight
    /// doubles against its six slots. Beams are drawn with it (`moveTo`, three `lineTo`, `fillPath`).
    case fillPath
}

extension DrawCommand {
    /// Bit positions in `setTextStyle`'s mask. A reader tests each bit on its own, so one that does not know a bit
    /// ignores it and draws the rest.
    public enum TextStyleFlag {
        public static let bold: UInt8 = 1 << 0
        public static let italic: UInt8 = 1 << 1
        /// Weight 600. Weight precedence is bold (700) over semibold (600) over regular (400), so a mask carrying
        /// both draws bold. A reader that ignores the bit draws regular.
        public static let semibold: UInt8 = 1 << 2
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
