import Foundation
import SheetMusicWireFormat

/// Self-describing binary format that ferries layout output across the JNI
/// boundary. Little-endian throughout. Both the Swift encoder and the Kotlin
/// decoder must agree on the magic + version; mismatches are fail-fast.
///
/// ### Wire layout (v4)
///
/// ```text
/// u32 magic       = 0x534D4450 ("SMDP")
/// u32 version     = 4
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
public enum DrawProgram {
    public static let magic: UInt32 = 0x534D_4450 // "SMDP"
    public static let version: UInt32 = 4

    @WireFormatEnum(kotlin: .skip)
    public enum FontID: UInt8, Sendable, CaseIterable, Equatable {
        case textRoman = 0x00 // body text (Edwin / system serif)
        case smufl = 0x01 // music glyphs (Bravura / Edwin SMuFL)
    }
}

/// One page worth of draw commands. The shape mirrors how the Kotlin
/// renderer paints — paint everything in `commands` onto a canvas sized
/// `widthMM × heightMM`.
@WireFormat(kotlin: .skip)
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
/// declaration order (`moveTo` = 0 … `cubicTo` = 7). Reorder with care:
/// changes here are wire-breaking across the Kotlin boundary.
@WireFormatChoice(kotlin: .skip)
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
        String,
        x: Double,
        y: Double,
        size: Double,
        fontId: DrawProgram.FontID,
    )
    /// Set the active paint colour as a packed ARGB value
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

@WireFormat(kotlin: .skip)
struct DrawProgramWire {
    var magic: UInt32
    var version: UInt32
    var pages: [EncodablePage]
}
