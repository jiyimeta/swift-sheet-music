import Foundation
import SheetMusicCore
import SheetMusicLayout

/// Test-friendly mirror of one page's draw program. The production encoder
/// path consumes `LayoutDocument` directly via the `encode(layout:)` overload.
public struct EncodablePage: Sendable {
    public var widthMM: Double
    public var heightMM: Double
    public var commands: [DrawCommand]

    public init(widthMM: Double, heightMM: Double, commands: [DrawCommand]) {
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.commands = commands
    }
}

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
}

public enum DrawProgramEncoder {
    public static func encode(pages: [EncodablePage]) -> Data {
        var w = BinaryWriter()
        w.append(DrawProgram.magic)
        w.append(DrawProgram.version)
        w.append(UInt32(pages.count))
        for page in pages {
            encodePage(page, into: &w)
        }
        return w.data
    }

    /// Production entry point. Maps a `LayoutDocument` into draw commands.
    ///
    /// - Note: `LayoutDocument` does not expose a `pages` array or per-page
    ///   staff/glyph structs. Its shape is `systems: [LayoutSystem]` with
    ///   `staffOrigins` + `StaffMetrics` driving staff-line drawing, and
    ///   `LayoutElement` enum cases carrying note/glyph placement.
    ///   A full walk is deferred to Task 7 (LayoutBridge). This stub
    ///   preserves the public API so callers can bind to it now.
    public static func encode(layout _: LayoutDocument) -> Data {
        // TODO(Task-7): walk layout.systems to produce per-page draw commands.
        // The LayoutDocument has no pagination boundary — derive page breaks
        // from LayoutMeasure.pageBreak flags or a fixed page height budget.
        // Staff lines come from system.staffOrigins + document.metrics.
        // Glyphs come from LayoutElement cases (clef, note, rest, etc.).
        encode(pages: [])
    }

    private static func encodePage(_ page: EncodablePage, into w: inout BinaryWriter) {
        w.append(page.widthMM)
        w.append(page.heightMM)
        w.append(UInt32(page.commands.count))
        for cmd in page.commands {
            encodeCommand(cmd, into: &w)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func encodeCommand(_ cmd: DrawCommand, into w: inout BinaryWriter) {
        switch cmd {
        case let .moveTo(x, y):
            w.append(DrawProgram.Opcode.moveTo.rawValue)
            w.append(x)
            w.append(y)
        case let .lineTo(x, y):
            w.append(DrawProgram.Opcode.lineTo.rawValue)
            w.append(x)
            w.append(y)
        case let .stroke(width):
            w.append(DrawProgram.Opcode.stroke.rawValue)
            w.append(width)
        case let .fillRect(x, y, ww, h):
            w.append(DrawProgram.Opcode.fillRect.rawValue)
            w.append(x)
            w.append(y)
            w.append(ww)
            w.append(h)
        case let .glyph(cp, x, y, size, fontId):
            w.append(DrawProgram.Opcode.glyph.rawValue)
            w.append(cp)
            w.append(x)
            w.append(y)
            w.append(size)
            w.append(fontId.rawValue)
        case let .text(s, x, y, size, fontId):
            w.append(DrawProgram.Opcode.text.rawValue)
            w.append(utf8: s)
            w.append(x)
            w.append(y)
            w.append(size)
            w.append(fontId.rawValue)
        case let .setColor(argb):
            w.append(DrawProgram.Opcode.setColor.rawValue)
            w.append(argb)
        }
    }
}
