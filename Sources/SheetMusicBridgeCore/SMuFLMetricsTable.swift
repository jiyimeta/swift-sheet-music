import SheetMusicFoundation
import SheetMusicLayout

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

/// Glyph-metrics table measured from Bravura at a fixed reference point
/// size — on Android by `BravuraMetricsBuilder.kt` from `Paint.getTextPath` /
/// `Path.computeBounds` at runtime, for the browser by
/// `Tools/GenBravuraMetrics` from CoreText at build time. Wire layout:
///
/// ```text
/// u32 magic         = 0x534D4654 ("SMFT")
/// u32 version       = 3
/// f64 referenceSize
/// f32 ascent          (positive, above the baseline)
/// f32 descent         (positive, below the baseline)
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
/// v3 added `ascent` and `descent`. `(ascent − descent) / 2` is how
/// `ArticulationGlyphMetrics`, `FermataGlyphMetrics`, `BreathGlyphMetrics`,
/// `ChordLineGeometry` and `LayoutElementShape` put a glyph's ink on its
/// baseline, and a v2 table had nothing for the provider to answer with, so
/// it fell back to `StubFontMetricsProvider`'s 0.85 / 0.25 em — 1.2 sp off
/// Bravura's symmetric 2.012 em, on every platform that installs a table.
///
/// The layout is a flat byte cursor — magic, version, referenceSize, the
/// two vertical metrics, an `Int32` glyph count, then `count` fixed-size
/// entries. It is NOT `@WireFormat`/protobuf framing: the producers
/// hand-write the bytes, so `decode` hand-parses them to match. (A brief
/// `@WireFormat` migration decoded this with the macro, which silently
/// failed — the macro's tag/varint/length-delimited framing never matched
/// the flat producer, so the table never installed.) The `version` field
/// guards against accidental mix-and-match builds via `unsupportedVersion`.
package struct SMuFLMetricsTable {
    struct Entry {
        let advance: Double
        let bboxX: Double
        let bboxY: Double
        let bboxW: Double
        let bboxH: Double
    }

    static let magic: UInt32 = 0x534D_4654
    static let version: UInt32 = 3

    let referenceSize: Double
    /// Bravura's ascent and descent in points at `referenceSize`, both
    /// positive magnitudes as `FontMetricsProvider` reports them.
    let ascent: Double
    let descent: Double
    let entries: [UInt32: Entry]

    enum DecodeError: Error, Equatable {
        case badMagic(UInt32)
        case unsupportedVersion(UInt32)
        case truncated
    }

    /// Parse the flat little-endian byte layout written by Android's
    /// `BravuraMetricsBuilder.kt` and `Tools/GenBravuraMetrics` (a raw byte
    /// buffer, NOT protobuf-style `@WireFormat` framing). The producers
    /// hand-roll the bytes, so the reader is hand-written to match them
    /// field-for-field — `magic | version | referenceSize | ascent | descent |
    /// count | [entry × count]` per the wire-layout doc above. (This used to go
    /// through `@WireFormat`, but that macro emits tag/varint/length-
    /// delimited framing the hand-written producer never matched, so the
    /// decode silently failed and the metrics table was never installed.)
    package static func decode(_ data: Data) throws -> SMuFLMetricsTable {
        var cursor = 0
        func readU32() throws -> UInt32 {
            guard cursor + 4 <= data.count else { throw DecodeError.truncated }
            let base = data.index(data.startIndex, offsetBy: cursor)
            var v: UInt32 = 0
            for i in 0 ..< 4 {
                v |= UInt32(data[data.index(base, offsetBy: i)]) << (8 * i)
            }
            cursor += 4
            return v
        }
        func readU64() throws -> UInt64 {
            guard cursor + 8 <= data.count else { throw DecodeError.truncated }
            let base = data.index(data.startIndex, offsetBy: cursor)
            var v: UInt64 = 0
            for i in 0 ..< 8 {
                v |= UInt64(data[data.index(base, offsetBy: i)]) << (8 * i)
            }
            cursor += 8
            return v
        }
        func readF32() throws -> Double {
            try Double(Float(bitPattern: readU32()))
        }
        func readF64() throws -> Double {
            try Double(bitPattern: readU64())
        }

        let magicValue = try readU32()
        guard magicValue == magic else { throw DecodeError.badMagic(magicValue) }
        let versionValue = try readU32()
        guard versionValue == version else {
            throw DecodeError.unsupportedVersion(versionValue)
        }
        let referenceSize = try readF64()
        let ascent = try readF32()
        let descent = try readF32()
        let count = try readU32()
        var entries: [UInt32: Entry] = [:]
        entries.reserveCapacity(Int(count))
        for _ in 0 ..< count {
            let cp = try readU32()
            let entry = try Entry(
                advance: readF32(),
                bboxX: readF32(),
                bboxY: readF32(),
                bboxW: readF32(),
                bboxH: readF32(),
            )
            entries[cp] = entry
        }
        return SMuFLMetricsTable(
            referenceSize: referenceSize, ascent: ascent, descent: descent, entries: entries,
        )
    }
}

/// Factory that returns a `FontMetricsProvider` backed by the given
/// metrics table. The concrete `SMuFLMetricsTableProvider` is
/// `fileprivate` because its protocol witnesses use the `private
/// typealias CGFloat/CGRect` above to disambiguate on Android, and
/// Swift forbids `internal` methods from returning a `private` type.
/// Returning the existential erases the concrete type so callers
/// elsewhere in the module never need to name it.
package func makeSMuFLMetricsTableProvider(
    table: SMuFLMetricsTable,
) -> any FontMetricsProvider {
    SMuFLMetricsTableProvider(table: table)
}

/// `FontMetricsProvider` that serves Bravura glyph metrics — the face's
/// ascent and descent as well as per-glyph boxes and advances — from a
/// measured table. Falls back to a `StubFontMetricsProvider` for non-Bravura
/// faces (e.g. Edwin text widths) and for codepoints not present in the
/// table.
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
        guard isBravura(font) else { return stub.ascent(font: font) }
        return CGFloat(table.ascent * scale(font))
    }

    func descent(font: LayoutFont) -> CGFloat {
        guard isBravura(font) else { return stub.descent(font: font) }
        return CGFloat(table.descent * scale(font))
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
