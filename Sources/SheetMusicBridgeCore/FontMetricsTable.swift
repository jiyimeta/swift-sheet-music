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

/// Font-metrics table measured at a fixed reference point size — on Android
/// by `FontMetricsBuilder.kt` from `Paint.getTextPath` / `Path.computeBounds`
/// at runtime, for the browser by `Tools/GenFontMetrics` from CoreText at
/// build time. Wire layout:
///
/// ```text
/// u32 magic         = 0x534D4654 ("SMFT")
/// u32 version       = 4
/// f64 referenceSize
/// u32 faceCount
/// [face] × faceCount:
///     u32 nameByteCount
///     u8  name[nameByteCount]     (UTF-8, e.g. "Bravura", "Edwin")
///     f32 ascent                  (positive, above the baseline)
///     f32 descent                 (positive, below the baseline)
///     f32 leading                 (extra gap BETWEEN consecutive lines)
///     u32 glyphCount
///     [entry] × glyphCount:
///         u32 codepoint
///         f32 advance
///         f32 bboxX
///         f32 bboxY
///         f32 bboxW
///         f32 bboxH
/// ```
///
/// All little-endian. The values stored are in points at `referenceSize`;
/// the provider rescales to the requested `pointSize` at lookup.
///
/// v3 added the face's `ascent` and `descent`. `(ascent − descent) / 2` is
/// how `ArticulationGlyphMetrics`, `FermataGlyphMetrics`, `BreathGlyphMetrics`,
/// `ChordLineGeometry` and `LayoutElementShape` put a glyph's ink on its
/// baseline, and a v2 table had nothing for the provider to answer with, so
/// it fell back to `StubFontMetricsProvider`'s 0.85 / 0.25 em — 1.2 sp off
/// Bravura's symmetric 2.012 em, on every platform that installs a table.
///
/// v4 carries MORE THAN ONE FACE, because the same argument applies to text.
/// A v3 table measured Bravura alone, so every non-SMuFL face — Edwin, which
/// is what MuseScore's `Sid::*FontFace` defaults all name — answered from the
/// stub: 0.85 / 0.25 em against Edwin's measured 0.737 / 0.263, no line gap
/// against Edwin's 0.2 em, and a *bucket estimate* rather than a table for
/// every advance (`StubFontMetricsProvider.advanceEm`: digits 0.5, uppercase
/// 0.65, lowercase 0.5, punctuation 0.3). Every rehearsal-mark frame, harmony
/// width and lyric width on Android and in the browser was sized off those
/// averages. v4 therefore moves the vertical metrics into a per-face record,
/// adds `leading`, and keys the faces by name.
///
/// A face the table does not carry still falls through to the stub, and so
/// does a codepoint the face does not carry — Edwin has no CJK at all, so a
/// Japanese lyric is still measured by the stub's 1 em-per-ideograph estimate.
///
/// The layout is a flat byte cursor. It is NOT `@WireFormat`/protobuf framing:
/// the producers hand-write the bytes, so `decode` hand-parses them to match.
/// (A brief `@WireFormat` migration decoded this with the macro, which
/// silently failed — the macro's tag/varint/length-delimited framing never
/// matched the flat producer, so the table never installed.) The `version`
/// field guards against accidental mix-and-match builds via
/// `unsupportedVersion`.
package struct FontMetricsTable {
    struct Entry {
        let advance: Double
        let bboxX: Double
        let bboxY: Double
        let bboxW: Double
        let bboxH: Double
    }

    /// One measured face: its vertical metrics and its glyph boxes, all in
    /// points at the table's `referenceSize`.
    struct Face {
        /// As the producer wrote it — `LayoutFont.face` is matched against it
        /// case-insensitively, so this keeps the canonical capitalization for
        /// diagnostics.
        let name: String
        let ascent: Double
        let descent: Double
        let leading: Double
        let entries: [UInt32: Entry]
    }

    static let magic: UInt32 = 0x534D_4654
    static let version: UInt32 = 4

    let referenceSize: Double
    /// Keyed by the face name lowercased. A score's `<font face="…">` is
    /// author-supplied text, so an exact-case match would drop "edwin" on the
    /// floor for no reason.
    let faces: [String: Face]

    /// The measured face for a `LayoutFont.face`, or nil when the table does
    /// not carry it and the caller should fall back to the stub.
    func face(named name: String) -> Face? {
        faces[name.lowercased()]
    }

    enum DecodeError: Error, Equatable {
        case badMagic(UInt32)
        case unsupportedVersion(UInt32)
        case truncated
        case malformedFaceName
    }

    /// Parse the flat little-endian byte layout written by Android's
    /// `FontMetricsBuilder.kt` and `Tools/GenFontMetrics` (a raw byte buffer,
    /// NOT protobuf-style `@WireFormat` framing). The producers hand-roll the
    /// bytes, so the reader is hand-written to match them field-for-field —
    /// `magic | version | referenceSize | faceCount | [face × faceCount]` per
    /// the wire-layout doc above. (This used to go through `@WireFormat`, but
    /// that macro emits tag/varint/length-delimited framing the hand-written
    /// producer never matched, so the decode silently failed and the metrics
    /// table was never installed.)
    package static func decode(_ data: Data) throws -> FontMetricsTable {
        var reader = ByteReader(data: data)
        let magicValue = try reader.u32()
        guard magicValue == magic else { throw DecodeError.badMagic(magicValue) }
        let versionValue = try reader.u32()
        guard versionValue == version else {
            throw DecodeError.unsupportedVersion(versionValue)
        }
        let referenceSize = try reader.f64()
        let faceCount = try reader.u32()
        var faces: [String: Face] = [:]
        faces.reserveCapacity(Int(faceCount))
        for _ in 0 ..< faceCount {
            let face = try decodeFace(&reader)
            faces[face.name.lowercased()] = face
        }
        return FontMetricsTable(referenceSize: referenceSize, faces: faces)
    }

    private static func decodeFace(_ reader: inout ByteReader) throws -> Face {
        let nameByteCount = try Int(reader.u32())
        let nameBytes = try reader.bytes(nameByteCount)
        guard let name = String(bytes: nameBytes, encoding: .utf8), !name.isEmpty else {
            throw DecodeError.malformedFaceName
        }
        let ascent = try reader.f32()
        let descent = try reader.f32()
        let leading = try reader.f32()
        let glyphCount = try reader.u32()
        var entries: [UInt32: Entry] = [:]
        entries.reserveCapacity(Int(glyphCount))
        for _ in 0 ..< glyphCount {
            let codepoint = try reader.u32()
            let advance = try reader.f32()
            let bboxX = try reader.f32()
            let bboxY = try reader.f32()
            let bboxW = try reader.f32()
            let bboxH = try reader.f32()
            entries[codepoint] = Entry(
                advance: advance, bboxX: bboxX, bboxY: bboxY,
                bboxW: bboxW, bboxH: bboxH,
            )
        }
        return Face(
            name: name, ascent: ascent, descent: descent,
            leading: leading, entries: entries,
        )
    }

    /// Little-endian cursor over the producers' hand-written bytes. `Data` is
    /// not guaranteed to be zero-indexed, hence the `index(_:offsetBy:)`
    /// arithmetic rather than plain subscripts.
    private struct ByteReader {
        let data: Data
        var cursor = 0

        mutating func u32() throws -> UInt32 {
            var v: UInt32 = 0
            for (i, byte) in try take(4).enumerated() {
                v |= UInt32(byte) << (8 * i)
            }
            return v
        }

        mutating func u64() throws -> UInt64 {
            var v: UInt64 = 0
            for (i, byte) in try take(8).enumerated() {
                v |= UInt64(byte) << (8 * i)
            }
            return v
        }

        mutating func f32() throws -> Double {
            try Double(Float(bitPattern: u32()))
        }

        mutating func f64() throws -> Double {
            try Double(bitPattern: u64())
        }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            try take(count)
        }

        private mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, cursor + count <= data.count else {
                throw DecodeError.truncated
            }
            let base = data.index(data.startIndex, offsetBy: cursor)
            var out: [UInt8] = []
            out.reserveCapacity(count)
            for i in 0 ..< count {
                out.append(data[data.index(base, offsetBy: i)])
            }
            cursor += count
            return out
        }
    }
}

/// Factory that returns a `FontMetricsProvider` backed by the given
/// metrics table. The concrete `FontMetricsTableProvider` is
/// `fileprivate` because its protocol witnesses use the `private
/// typealias CGFloat/CGRect` above to disambiguate on Android, and
/// Swift forbids `internal` methods from returning a `private` type.
/// Returning the existential erases the concrete type so callers
/// elsewhere in the module never need to name it.
package func makeFontMetricsTableProvider(
    table: FontMetricsTable,
) -> any FontMetricsProvider {
    FontMetricsTableProvider(table: table)
}

/// `FontMetricsProvider` that serves measured metrics — each face's ascent,
/// descent and line gap as well as per-glyph boxes and advances — from a
/// `FontMetricsTable`. Falls back to a `StubFontMetricsProvider` for faces
/// the table does not carry, and per scalar for codepoints a carried face
/// does not have (Edwin's missing CJK, most often).
private struct FontMetricsTableProvider: FontMetricsProvider {
    private let table: FontMetricsTable
    private let stub = StubFontMetricsProvider()

    init(table: FontMetricsTable) {
        self.table = table
    }

    private func scale(_ font: LayoutFont) -> Double {
        Double(font.pointSize) / table.referenceSize
    }

    /// The stub's estimate for a single scalar, in points at `font.pointSize`.
    /// Used for a codepoint the measured face has no entry for, so an
    /// unmeasurable run degrades to the same numbers a platform with no table
    /// at all would produce rather than to a flat guess.
    private func stubAdvance(_ scalar: Unicode.Scalar, font: LayoutFont) -> Double {
        Double(stub.typographicWidth(text: String(scalar), font: font))
    }

    func ascent(font: LayoutFont) -> CGFloat {
        guard let face = table.face(named: font.face) else {
            return stub.ascent(font: font)
        }
        return CGFloat(face.ascent * scale(font))
    }

    func descent(font: LayoutFont) -> CGFloat {
        guard let face = table.face(named: font.face) else {
            return stub.descent(font: font)
        }
        return CGFloat(face.descent * scale(font))
    }

    func leading(font: LayoutFont) -> CGFloat {
        guard let face = table.face(named: font.face) else {
            return stub.leading(font: font)
        }
        return CGFloat(face.leading * scale(font))
    }

    func glyphPathBoundingBox(
        font: LayoutFont, codepoint: UInt16,
    ) -> CGRect? {
        guard let face = table.face(named: font.face),
              let entry = face.entries[UInt32(codepoint)]
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
        guard let face = table.face(named: font.face), !text.isEmpty else {
            return stub.typographicWidth(text: text, font: font)
        }
        let s = scale(font)
        var total: Double = 0
        for scalar in text.unicodeScalars {
            if let entry = face.entries[scalar.value] {
                total += entry.advance * s
            } else {
                total += stubAdvance(scalar, font: font)
            }
        }
        return CGFloat(total)
    }

    func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        guard let face = table.face(named: font.face), !text.isEmpty else {
            return stub.inkBounds(text: text, font: font)
        }
        let s = scale(font)
        var pen: Double = 0
        var minX: Double = 0
        var maxX: Double = 0
        var seenAny = false
        func extend(_ left: Double, _ right: Double) {
            if !seenAny {
                minX = left
                maxX = right
                seenAny = true
            } else {
                if left < minX { minX = left }
                if right > maxX { maxX = right }
            }
        }
        for scalar in text.unicodeScalars {
            guard let entry = face.entries[scalar.value] else {
                // Unmeasurable: the stub reports a full-advance ink box for
                // text, so claim the same rather than pretending the run has
                // a hole in it.
                let advance = stubAdvance(scalar, font: font)
                extend(pen, pen + advance)
                pen += advance
                continue
            }
            // A glyph with an advance but no ink — space, and every other
            // blank the text ranges sweep up — moves the pen and claims
            // nothing.
            if entry.bboxW > 0, entry.bboxH > 0 {
                let left = pen + entry.bboxX * s
                extend(left, left + entry.bboxW * s)
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
