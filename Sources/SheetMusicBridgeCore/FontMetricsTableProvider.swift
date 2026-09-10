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

    func renderingTextFont(_ font: LayoutFont) -> LayoutFont {
        LayoutFont(
            face: font.face == SMuFLFamily.bravura ? font.face : "Edwin",
            pointSize: font.pointSize, weight: font.weight, isItalic: font.isItalic,
        )
    }

    func textInkBounds(text: String, font: LayoutFont) -> CGRect? {
        guard let face = table.face(for: font) else { return stub.textInkBounds(text: text, font: font) }
        let factor = scale(font)
        let stride = CGFloat((face.ascent + face.descent + face.leading) * factor)
        var result: CGRect?
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var pen: CGFloat = 0
            for scalar in line.unicodeScalars {
                let box: CGRect?
                let advance: CGFloat
                if let entry = face.entries[scalar.value] {
                    box = entry.bboxW > 0 && entry.bboxH > 0 ? CGRect(
                        x: CGFloat(entry.bboxX * factor), y: CGFloat(entry.bboxY * factor),
                        width: CGFloat(entry.bboxW * factor), height: CGFloat(entry.bboxH * factor),
                    ) : nil
                    advance = CGFloat(entry.advance * factor)
                } else {
                    box = stub.textInkBounds(text: String(scalar), font: font)
                    advance = CGFloat(stubAdvance(scalar, font: font))
                }
                if let box {
                    let shifted = box.offsetBy(dx: pen, dy: -CGFloat(index) * stride)
                    result = result.map { $0.union(shifted) } ?? shifted
                }
                pen += advance
            }
        }
        return result
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
        guard let face = table.face(for: font) else {
            return stub.ascent(font: font)
        }
        return CGFloat(face.ascent * scale(font))
    }

    func descent(font: LayoutFont) -> CGFloat {
        guard let face = table.face(for: font) else {
            return stub.descent(font: font)
        }
        return CGFloat(face.descent * scale(font))
    }

    func leading(font: LayoutFont) -> CGFloat {
        guard let face = table.face(for: font) else {
            return stub.leading(font: font)
        }
        return CGFloat(face.leading * scale(font))
    }

    func glyphPathBoundingBox(
        font: LayoutFont, codepoint: UInt16,
    ) -> CGRect? {
        guard let face = table.face(for: font),
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
        guard let face = table.face(for: font), !text.isEmpty else {
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
        guard let face = table.face(for: font), !text.isEmpty else {
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
