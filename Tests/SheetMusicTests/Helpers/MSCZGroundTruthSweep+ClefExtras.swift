// `&& !os(WASI)` to match the guard on `MSCZGroundTruthSweep.swift`, whose
// type this file extends: `SheetMusicPDF` is not in the WebAssembly manifest's
// test dependencies, so without it the whole test target fails to compile
// there with `no such module`.
#if !os(Android) && !os(WASI)
    import Foundation
    @testable import SheetMusicPDF

    extension MSCZGroundTruthSweep {
        /// The clefs the raster front-end put where the vector one has NONE.
        ///
        /// `clefProbe` walks the vector clefs and reports what the raster
        /// put near each — it cannot see a raster clef with no vector clef
        /// nearby, and that is the glyph that costs the most: a false clef
        /// inside a measure changes the clef in force for every note after
        /// it on that staff. A model that has learned the octave variants
        /// (round 2's run5) pays exactly here — its extra `clefG15mb` /
        /// `clefG8va` proposals on the held-out set are this failure on
        /// synthetic pages.
        ///
        /// Gated with the same `OMR_MSCZ_CLEF_PROBE=1`. One `[mscz-clefextra]`
        /// line per extra clef (page, class, score, position) and one
        /// summary line per document, so a 657-file sweep can be grepped
        /// for the documents that have any.
        static func clefExtras(
            _ item: Case, vector: WalkedContent, raster: WalkedContent,
            scored: [OMRGlyphDetector.ScoredGlyph], radius: CGFloat = 12,
        ) {
            guard ProcessInfo.processInfo.environment["OMR_MSCZ_CLEF_PROBE"] == "1" else { return }
            let vectorClefs = vector.glyphs.filter(isClefGlyph)
            let scoreOf = Dictionary(scored.map { ($0.glyph, $0.score) }, uniquingKeysWith: max)
            var extras = 0
            for clef in raster.glyphs where isClefGlyph(clef) {
                let at = clef.geometry.origin
                let page = clef.geometry.pageIndex
                let matched = vectorClefs.contains {
                    $0.geometry.pageIndex == page
                        && hypot($0.geometry.origin.x - at.x, $0.geometry.origin.y - at.y) <= radius
                }
                if matched { continue }
                extras += 1
                let score = scoreOf[clef].map { String(format: "%.3f", $0) } ?? "?"
                print("[mscz-clefextra][\(item.name)] page=\(page) "
                    + "class=\(OMRLabelClassNames.className(for: clef.semantic)) score=\(score) "
                    + "at=(\(round(at.x * 10) / 10),\(round(at.y * 10) / 10))")
            }
            print("[mscz-clefextra][\(item.name)] extras=\(extras) rasterClefs="
                + "\(raster.glyphs.count(where: isClefGlyph)) vectorClefs=\(vectorClefs.count)")
        }

        static func isClefGlyph(_ glyph: ClassifiedGlyph) -> Bool {
            OMRLabelClassNames.className(for: glyph.semantic).hasPrefix("clef")
        }
    }
#endif
