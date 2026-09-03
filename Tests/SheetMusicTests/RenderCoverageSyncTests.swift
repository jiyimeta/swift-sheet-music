import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's CoreGraphics shims also export `CGPoint`
    /// (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so anchor explicitly to
    /// SheetMusicLayout's own definition instead of leaving it ambiguous.
    ///
    /// `private typealias` keeps this file-scoped — a module-scope `typealias CGPoint` here
    /// would collide with the same pattern in every other file in this target that needs it.
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// Cross-module sync guard: asserts that the MSCX decoder's known
/// notehead / accidental / vibrato subtypes exactly match what the
/// Layout renderer can draw.  A future glyph addition in either side
/// must update the other to keep this suite green.
struct RenderCoverageSyncTests {
    /// The decoder's known MS4 `<head>` tokens must equal the set of
    /// `NoteHeadGroup.rawValue`s (bidirectional).  One direction only
    /// is covered by `NoteHeadGroupTests.everyGroupSymNameResolves`
    /// and `NoteHeadGroupTests.tokenResolves`; this adds the
    /// decoder→renderer direction and the full equality check.
    @Test func headTokensAreBidirectionallyInSync() {
        let knownSet = MSCXDecoder.knownHeadTokens
        let rendererSet = Set(NoteHeadGroup.allCases.map(\.rawValue))
        let decoderOnly = knownSet.subtracting(rendererSet)
        let rendererOnly = rendererSet.subtracting(knownSet)
        #expect(
            knownSet == rendererSet,
            "decoderOnly=\(decoderOnly.sorted()), rendererOnly=\(rendererOnly.sorted())",
        )
    }

    /// Every `Accidental` case must resolve to a non-nil SMuFL codepoint
    /// via its `mscxSubtype` (= rawValue = SMuFL SymId name).
    @Test func everyAccidentalResolvesToGlyph() {
        for acc in Accidental.allCases {
            #expect(
                SMuFLCodepoint.byName(acc.mscxSubtype) != nil,
                "\(acc): \(acc.mscxSubtype)",
            )
        }
    }

    /// Every `VibratoType` case must produce a non-zero SMuFL codepoint
    /// from `SpannerGeometry.vibratoGlyphRun`.
    @Test func everyVibratoTypeHasGlyph() {
        for t in VibratoType.allCases {
            let run = SpannerGeometry.vibratoGlyphRun(
                from: .zero,
                to: CGPoint(x: 40, y: 0),
                type: t,
                sp: 8,
                advance: 8,
            )
            #expect(run.codepoint != 0)
        }
    }
}
