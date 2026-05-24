import Foundation
import SheetMusicLayout
import SheetMusicWireFormat

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGFloat`,
    /// `CGRect`, clashing with SheetMusicLayout's stubs. Anchor to the
    /// Layout definitions so `FontMetricsProvider` conformance and
    /// `InkBounds` initialization resolve to the protocol's expected types.
    ///
    /// Using `private typealias` keeps these file-scoped — module-scope
    /// `typealias CGFloat` collides with the same pattern in
    /// `LayoutBridge+*.swift`. The struct / provider stay `internal` so
    /// `JNISymbols.swift` can still reach them.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// Glyph-metrics table populated from Android `Paint.getTextPath` /
/// `Path.computeBounds` at a fixed reference point size. Wire layout:
///
/// ```text
/// u32 magic         = 0x534D4654 ("SMFT")
/// u32 version       = 2
/// f64 referenceSize
/// i32 glyphCount
/// [entry] × glyphCount:
///     u32 codepoint
///     f32 advance
///     f32 bboxX
///     f32 bboxY
///     f32 bboxW
///     f32 bboxH
/// ```
///
/// All little-endian. The values stored are in points at `referenceSize`;
/// the provider rescales to the requested `pointSize` at lookup.
///
/// v2 swapped the hand-written byte cursor for `@WireFormat`. Array
/// count is now an `Int32` length prefix (was `UInt32`) — byte layout
/// is identical for any non-negative count, but a version bump
/// surfaces accidental mix-and-match builds as
/// `unsupportedVersion`.
struct SMuFLMetricsTable {
    struct Entry {
        let advance: Double
        let bboxX: Double
        let bboxY: Double
        let bboxW: Double
        let bboxH: Double
    }

    static let magic: UInt32 = 0x534D_4654
    static let version: UInt32 = 2

    let referenceSize: Double
    let entries: [UInt32: Entry]

    enum DecodeError: Error, Equatable {
        case badMagic(UInt32)
        case unsupportedVersion(UInt32)
    }

    static func decode(_ data: Data) throws -> SMuFLMetricsTable {
        let wire = try SMuFLMetricsWire(decoding: data)
        guard wire.magic == magic else { throw DecodeError.badMagic(wire.magic) }
        guard wire.version == version else {
            throw DecodeError.unsupportedVersion(wire.version)
        }
        var entries: [UInt32: Entry] = [:]
        entries.reserveCapacity(wire.entries.count)
        for entry in wire.entries {
            entries[entry.codepoint] = Entry(
                advance: Double(entry.advance),
                bboxX: Double(entry.bboxX),
                bboxY: Double(entry.bboxY),
                bboxW: Double(entry.bboxW),
                bboxH: Double(entry.bboxH),
            )
        }
        return SMuFLMetricsTable(
            referenceSize: wire.referenceSize,
            entries: entries,
        )
    }
}

// Kotlin codecs are intentionally skipped: `BravuraMetricsBuilder.kt`
// hand-rolls the on-wire bytes directly with a ByteBuffer (it consumes
// raw Android Paint output) and never goes through a generated codec.
// Emitting one would produce dead code that drifts from the model class
// in `audio.model.SMuFLMetrics`.

@WireFormat(kotlin: .skip)
struct SMuFLMetricsWire {
    var magic: UInt32
    var version: UInt32
    var referenceSize: Double
    var entries: [SMuFLMetricsEntryWire]
}

@WireFormat(kotlin: .skip)
struct SMuFLMetricsEntryWire {
    var codepoint: UInt32
    var advance: Float
    var bboxX: Float
    var bboxY: Float
    var bboxW: Float
    var bboxH: Float
}

/// Factory that returns a `FontMetricsProvider` backed by the given
/// metrics table. The concrete `SMuFLMetricsTableProvider` is
/// `fileprivate` because its protocol witnesses use the `private
/// typealias CGFloat/CGRect` above to disambiguate on Android, and
/// Swift forbids `internal` methods from returning a `private` type.
/// Returning the existential erases the concrete type so callers
/// elsewhere in the module never need to name it.
func makeSMuFLMetricsTableProvider(
    table: SMuFLMetricsTable,
) -> any FontMetricsProvider {
    SMuFLMetricsTableProvider(table: table)
}

/// `FontMetricsProvider` that serves Bravura glyph metrics from a table
/// captured on the Android side. Falls back to a `StubFontMetricsProvider`
/// for non-Bravura faces (e.g. Edwin text widths) and for codepoints not
/// present in the table.
private struct SMuFLMetricsTableProvider: FontMetricsProvider {
    private let table: SMuFLMetricsTable
    private let stub = StubFontMetricsProvider()

    init(table: SMuFLMetricsTable) {
        self.table = table
    }

    private func isBravura(_ font: LayoutFont) -> Bool {
        font.face == SMuFLFamily.bravura
    }

    private func scale(_ font: LayoutFont) -> Double {
        Double(font.pointSize) / table.referenceSize
    }

    func ascent(font: LayoutFont) -> CGFloat {
        stub.ascent(font: font)
    }

    func descent(font: LayoutFont) -> CGFloat {
        stub.descent(font: font)
    }

    func glyphPathBoundingBox(
        font: LayoutFont, codepoint: UInt16,
    ) -> CGRect? {
        guard isBravura(font),
              let entry = table.entries[UInt32(codepoint)]
        else {
            return stub.glyphPathBoundingBox(font: font, codepoint: codepoint)
        }
        let s = scale(font)
        return CGRect(
            x: CGFloat(entry.bboxX * s),
            y: CGFloat(entry.bboxY * s),
            width: CGFloat(entry.bboxW * s),
            height: CGFloat(entry.bboxH * s),
        )
    }

    func typographicWidth(
        text: String, font: LayoutFont,
    ) -> CGFloat {
        guard isBravura(font), !text.isEmpty else {
            return stub.typographicWidth(text: text, font: font)
        }
        let s = scale(font)
        var total: Double = 0
        for scalar in text.unicodeScalars {
            if let entry = table.entries[scalar.value] {
                total += entry.advance * s
            } else {
                total += Double(font.pointSize) * 0.5
            }
        }
        return CGFloat(total)
    }

    func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        guard isBravura(font), !text.isEmpty else {
            return stub.inkBounds(text: text, font: font)
        }
        let s = scale(font)
        var pen: Double = 0
        var minX: Double = 0
        var maxX: Double = 0
        var seenAny = false
        for scalar in text.unicodeScalars {
            guard let entry = table.entries[scalar.value] else {
                pen += Double(font.pointSize) * 0.5
                continue
            }
            let left = pen + entry.bboxX * s
            let right = left + entry.bboxW * s
            if !seenAny {
                minX = left
                maxX = right
                seenAny = true
            } else {
                if left < minX { minX = left }
                if right > maxX { maxX = right }
            }
            pen += entry.advance * s
        }
        if !seenAny {
            return InkBounds(leftBearing: 0, width: 0)
        }
        return InkBounds(
            leftBearing: CGFloat(minX),
            width: CGFloat(maxX - minX),
        )
    }
}
