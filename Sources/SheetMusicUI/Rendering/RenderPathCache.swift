import CoreText
import Foundation
import QuartzCore

/// The outlines `ScoreLayerBuilder` draws, kept across builds: Bravura fonts per size, SMuFL glyph paths and single
/// lines of text, each a path at the origin that callers copy into place with their own transform.
///
/// Building a score's layers asks for the same few dozen glyphs and few hundred strings over and over — every
/// notehead, every repeated lyric syllable — and each used to resolve a fresh `CTLine` or glyph outline. The paths
/// are immutable, so one copy serves every caller. The lock is there because host tests build layers from parallel
/// test cases; in the app every build runs on the main actor.
///
/// The tables only grow, so each is emptied wholesale when it reaches its capacity — a rebuild then pays for its
/// outlines once more. A dense score's distinct glyphs and strings fit well under the limits.
final class RenderPathCache: @unchecked Sendable {
    static let shared = RenderPathCache()

    struct GlyphKey: Hashable {
        let character: Character
        let font: CTFont

        static func == (lhs: GlyphKey, rhs: GlyphKey) -> Bool {
            lhs.character == rhs.character && CFEqual(lhs.font, rhs.font)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(character)
            hasher.combine(CFHash(font))
        }
    }

    struct TextKey: Hashable {
        let text: String
        let font: CTFont

        static func == (lhs: TextKey, rhs: TextKey) -> Bool {
            lhs.text == rhs.text && CFEqual(lhs.font, rhs.font)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(text)
            hasher.combine(CFHash(font))
        }
    }

    static let glyphCapacity = 4096
    static let textCapacity = 4096
    static let fontCapacity = 64

    private let lock = NSLock()
    private var bravuraFonts: [CGFloat: CTFont] = [:]
    private var glyphPaths: [GlyphKey: CGPath?] = [:]
    private var textPaths: [TextKey: CGPath?] = [:]

    func bravura(size: CGFloat) -> CTFont? {
        lock.withLock { bravuraFonts[size] }
    }

    func store(bravura font: CTFont, size: CGFloat) {
        lock.withLock { Self.insert(font, for: size, into: &bravuraFonts, capacity: Self.fontCapacity) }
    }

    /// `nil` when the glyph was never looked up; `.some(nil)` when it was and has no outline.
    func glyphPath(for key: GlyphKey) -> CGPath?? {
        lock.withLock { glyphPaths[key] }
    }

    func store(glyphPath path: CGPath?, for key: GlyphKey) {
        lock.withLock { Self.insert(path?.copy(), for: key, into: &glyphPaths, capacity: Self.glyphCapacity) }
    }

    /// `nil` when the line was never looked up; `.some(nil)` when it was and draws nothing.
    func textPath(for key: TextKey) -> CGPath?? {
        lock.withLock { textPaths[key] }
    }

    func store(textPath path: CGPath?, for key: TextKey) {
        lock.withLock { Self.insert(path?.copy(), for: key, into: &textPaths, capacity: Self.textCapacity) }
    }

    private static func insert<Key: Hashable, Value>(
        _ value: Value, for key: Key, into table: inout [Key: Value], capacity: Int,
    ) {
        if table.count >= capacity { table.removeAll(keepingCapacity: true) }
        table[key] = value
    }
}
