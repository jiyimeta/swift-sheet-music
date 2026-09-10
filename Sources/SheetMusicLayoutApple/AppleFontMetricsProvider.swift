import CoreGraphics
import CoreText
import Foundation
import SheetMusicLayout

/// CoreText-backed `FontMetricsProvider`. Wraps the entire CT path in
/// a single `NSLock` because `CTFontCreateWithName` for unregistered
/// family names deadlocks under concurrent access (Swift Testing runs
/// test cases in parallel). The lock also serializes an internal
/// `[LayoutFont: CTFont]` cache — consolidates the per-file caches
/// (`BraceMetrics.bboxCache`, `FermataGlyphMetrics.cache`,
/// `HarmonyRendering.fontCache`) that the Layout-side rewrites
/// remove.
@available(macOS 15.0, *)
public struct AppleFontMetricsProvider: FontMetricsProvider {
    public init() {
        // Touch BravuraFont.register so SMuFL family resolves
        // before any CT calls. Idempotent (static let).
        _ = BravuraFont.register
    }

    public func ascent(font: LayoutFont) -> CGFloat {
        Lock.shared.with {
            CTFontGetAscent(ctFont(for: font))
        }
    }

    public func descent(font: LayoutFont) -> CGFloat {
        Lock.shared.with {
            CTFontGetDescent(ctFont(for: font))
        }
    }

    /// Edwin asks for 0.2 em of line gap — ≈0.7 sp at the staff-text
    /// size, enough that dropping it would put a multi-line
    /// annotation's skyline box a visible fraction of a staff space
    /// away from where `ScoreLayerBuilder+Helpers.textPath` stacks the
    /// lines. Bravura reports 0.
    public func leading(font: LayoutFont) -> CGFloat {
        Lock.shared.with {
            CTFontGetLeading(ctFont(for: font))
        }
    }

    public func glyphPathBoundingBox(
        font: LayoutFont, codepoint: UInt16,
    ) -> CGRect? {
        Lock.shared.with {
            let ct = ctFont(for: font)
            var unichars: [UniChar] = [codepoint]
            var glyphs: [CGGlyph] = [0]
            guard CTFontGetGlyphsForCharacters(
                ct, &unichars, &glyphs, 1,
            ), glyphs[0] != 0,
            let path = CTFontCreatePathForGlyph(ct, glyphs[0], nil)
            else { return nil }
            return path.boundingBox
        }
    }

    public func typographicWidth(
        text: String, font: LayoutFont,
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return Lock.shared.with {
            let line = ctLine(text: text, font: font)
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
    }

    public func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        guard !text.isEmpty else { return InkBounds(leftBearing: 0, width: 0) }
        return Lock.shared.with {
            let line = ctLine(text: text, font: font)
            let image = CTLineGetImageBounds(line, nil)
            return InkBounds(
                leftBearing: image.origin.x,
                width: image.width,
            )
        }
    }

    public func textInkBounds(text: String, font: LayoutFont) -> CGRect? {
        Lock.shared.with {
            let ct = ctFont(for: font)
            let stride = CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)
            var result: CGRect?
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                guard let bounds = lineInkBounds(ctLine(text: line, font: font), fallbackFont: ct) else { continue }
                let box = bounds.offsetBy(dx: 0, dy: -CGFloat(index) * stride)
                result = result.map { $0.union(box) } ?? box
            }
            return result
        }
    }

    // MARK: - Private

    /// CoreText's `.useGlyphPathBounds` can include control-point extrema that the actual
    /// outline never reaches (Helvetica's `g` is one example). Bound the drawn outlines.
    private func lineInkBounds(_ line: CTLine, fallbackFont: CTFont) -> CGRect? {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        var result: CGRect?
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let attributes = CTRunGetAttributes(run) as? [String: Any]
            let font: CTFont
            if let value = attributes?[kCTFontAttributeName as String] {
                font = unsafeBitCast(value as AnyObject, to: CTFont.self)
            } else {
                font = fallbackFont
            }
            for index in 0 ..< count {
                guard let path = CTFontCreatePathForGlyph(font, glyphs[index], nil), !path.isEmpty else { continue }
                let box = path.boundingBoxOfPath.offsetBy(dx: positions[index].x, dy: positions[index].y)
                result = result.map { $0.union(box) } ?? box
            }
        }
        return result
    }

    /// Builds (or reuses) a `CTFont` for the requested face/size/weight.
    /// Caller must hold `Lock.shared`.
    private func ctFont(for font: LayoutFont) -> CTFont {
        if let cached = Cache.shared.ctFonts[font] { return cached }
        let new = makeCTFont(font: font)
        Cache.shared.ctFonts[font] = new
        return new
    }

    private func makeCTFont(font: LayoutFont) -> CTFont {
        if font.face.isEmpty {
            // System font with optional weight trait.
            let weight: CGFloat
            switch font.weight {
            case .regular: weight = 0
            case .semibold: weight = 0.3 // matches UIFont.Weight.semibold
            case .bold: weight = 0.4 // matches UIFont.Weight.bold
            }
            let traits: CFDictionary = [
                kCTFontWeightTrait: weight,
            ] as CFDictionary
            let attributes: CFDictionary = [
                kCTFontTraitsAttribute: traits,
                kCTFontSizeAttribute: font.pointSize,
            ] as CFDictionary
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
            return CTFontCreateWithFontDescriptor(
                descriptor, font.pointSize, nil,
            )
        }
        let named = CTFontCreateWithName(
            font.face as CFString, font.pointSize, nil,
        )
        var traits: CTFontSymbolicTraits = []
        if font.weight == .bold { traits.insert(.boldTrait) }
        if font.isItalic { traits.insert(.italicTrait) }
        guard !traits.isEmpty else { return named }
        // Ask CoreText for the bold member of the same family. This is the identical resolution
        // `ResolvedTextStyle.ctFont` performs for the render path (`.boldTrait`), so what gets
        // measured here is what gets drawn there — a rehearsal mark's frame is sized from this
        // measurement and would otherwise be cut for the wrong weight.
        //
        // The vector renderer uses the same fallback when no family member is
        // available; it does not add a synthetic stroke to the returned outline.
        let bolded = CTFontCreateCopyWithSymbolicTraits(
            named, font.pointSize, nil, traits, traits,
        )
        return bolded ?? named
    }

    private func ctLine(text: String, font: LayoutFont) -> CTLine {
        let ct = ctFont(for: font)
        let attr = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): ct,
            ],
        )
        return CTLineCreateWithAttributedString(attr as CFAttributedString)
    }
}

@available(macOS 15.0, *)
private final class Lock: @unchecked Sendable {
    static let shared = Lock()
    private let mutex = NSLock()
    func with<T>(_ body: () -> T) -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return body()
    }
}

@available(macOS 15.0, *)
private final class Cache: @unchecked Sendable {
    static let shared = Cache()
    var ctFonts: [LayoutFont: CTFont] = [:]
}
