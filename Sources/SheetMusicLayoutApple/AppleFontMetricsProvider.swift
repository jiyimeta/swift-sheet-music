import CoreGraphics
import CoreText
import Foundation
import SheetMusicLayout

/// CoreText-backed `FontMetricsProvider`. Wraps the entire CT path in
/// a single `NSLock` because `CTFontCreateWithName` for unregistered
/// family names deadlocks under concurrent access (Swift Testing runs
/// test cases in parallel). The lock also serialises an internal
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

    // MARK: - Private

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
        return CTFontCreateWithName(
            font.face as CFString, font.pointSize, nil,
        )
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
