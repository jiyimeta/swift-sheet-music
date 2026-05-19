#if os(Android)

    import struct Foundation.Data
    import SheetMusicLayout

    /// Glyph-metrics table populated from Android `Paint.getTextBounds` /
    /// `Paint.measureText` at a fixed reference point size. Wire format:
    ///
    ///     u32  magic   = 0x53_4D_46_54 ("SMFT")
    ///     u32  version = 1
    ///     f64  referenceSize
    ///     u32  glyphCount
    ///     [glyph] × glyphCount:
    ///         u32 codepoint
    ///         f32 advance
    ///         f32 bboxX
    ///         f32 bboxY
    ///         f32 bboxW
    ///         f32 bboxH
    ///
    /// All little-endian. The values stored are in points at `referenceSize`;
    /// the provider rescales to the requested `pointSize` at lookup.
    public struct SMuFLMetricsTable: Sendable {
        public struct Entry: Sendable {
            public let advance: Double
            public let bboxX: Double
            public let bboxY: Double
            public let bboxW: Double
            public let bboxH: Double
        }

        public static let magic: UInt32 = 0x534D_4654
        public static let version: UInt32 = 1

        public let referenceSize: Double
        public let entries: [UInt32: Entry]

        public enum DecodeError: Error {
            case truncated
            case badMagic(UInt32)
            case unsupportedVersion(UInt32)
        }

        public static func decode(_ data: Data) throws -> SMuFLMetricsTable {
            var cursor = 0
            func readU32() throws -> UInt32 {
                guard cursor + 4 <= data.count else { throw DecodeError.truncated }
                let v = data.withUnsafeBytes { raw -> UInt32 in
                    raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                }
                cursor += 4
                return UInt32(littleEndian: v)
            }
            func readF32() throws -> Float {
                guard cursor + 4 <= data.count else { throw DecodeError.truncated }
                let bits = data.withUnsafeBytes { raw -> UInt32 in
                    raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                }
                cursor += 4
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
            func readF64() throws -> Double {
                guard cursor + 8 <= data.count else { throw DecodeError.truncated }
                let bits = data.withUnsafeBytes { raw -> UInt64 in
                    raw.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
                }
                cursor += 8
                return Double(bitPattern: UInt64(littleEndian: bits))
            }

            let m = try readU32()
            guard m == magic else { throw DecodeError.badMagic(m) }
            let v = try readU32()
            guard v == version else { throw DecodeError.unsupportedVersion(v) }
            let refSize = try readF64()
            let count = try Int(readU32())
            var entries: [UInt32: Entry] = [:]
            entries.reserveCapacity(count)
            for _ in 0 ..< count {
                let cp = try readU32()
                let advance = try Double(readF32())
                let x = try Double(readF32())
                let y = try Double(readF32())
                let w = try Double(readF32())
                let h = try Double(readF32())
                entries[cp] = Entry(
                    advance: advance,
                    bboxX: x, bboxY: y, bboxW: w, bboxH: h,
                )
            }
            return SMuFLMetricsTable(referenceSize: refSize, entries: entries)
        }
    }

    /// `FontMetricsProvider` that serves Bravura glyph metrics from a table
    /// captured on the Android side. Falls back to a `StubFontMetricsProvider`
    /// for non-Bravura faces (e.g. Edwin text widths) and for codepoints not
    /// present in the table.
    public struct SMuFLMetricsTableProvider: FontMetricsProvider {
        private let table: SMuFLMetricsTable
        private let stub = StubFontMetricsProvider()

        public init(table: SMuFLMetricsTable) {
            self.table = table
        }

        private func isBravura(_ font: LayoutFont) -> Bool {
            font.face == SMuFLFamily.bravura
        }

        private func scale(_ font: LayoutFont) -> Double {
            Double(font.pointSize) / table.referenceSize
        }

        public func ascent(font: LayoutFont) -> CGFloat {
            stub.ascent(font: font)
        }

        public func descent(font: LayoutFont) -> CGFloat {
            stub.descent(font: font)
        }

        public func glyphPathBoundingBox(
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

        public func typographicWidth(
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

        public func inkBounds(text: String, font: LayoutFont) -> InkBounds {
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

#endif
