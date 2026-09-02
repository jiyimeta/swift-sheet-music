#if !os(Android) && !os(WASI)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// The pure, side-effect-free half of `OMRLabelExport` (spec §6.6):
    /// dual-walk pairing, /ToUnicode inversion, and the em-box → page-space
    /// bbox transform. Split out of `OMRLabelExport.swift` to keep both files
    /// inside the file-length cap. All three are `nonisolated` so the
    /// non-`@MainActor` unit suite can call them directly.
    extension OMRLabelExport {
        /// Positional pairing: the anchored dual walk emits the same
        /// glyph SET in the same order, so zip is exact. nil on any
        /// count mismatch (simple-font path, foreign producer).
        nonisolated static func pairCodepoints(
            truth: [ClassifiedGlyph], probe: [ClassifiedGlyph],
        ) -> [(glyph: ClassifiedGlyph, codepoint: UInt32?)]? {
            guard truth.count == probe.count else { return nil }
            return zip(truth, probe).map { truthGlyph, probeGlyph in
                if case let .unknown(codepoint) = probeGlyph.semantic {
                    return (truthGlyph, codepoint)
                }
                return (truthGlyph, nil)
            }
        }

        /// Invert per-font /ToUnicode CMaps into scalar → (resource, CID).
        /// Resources are visited in SORTED name order (determinism); first
        /// mapping wins. Only SMuFL-PUA scalars are indexed. For
        /// Identity-H fonts the CID is the glyph ID.
        ///
        /// KNOWN LIMITATION 1 (the likelier one): a subsetted font
        /// ROUTINELY decodes several CIDs to one Unicode scalar — unmapped
        /// CIDs collapse onto a single scalar
        /// (`GlyphClassifier.swift`'s `CacheKey` doc records this as normal).
        /// Keying by codepoint therefore hands every glyph sharing a scalar
        /// the LOWEST such CID's outline. With `Sources/` frozen there is no
        /// fix available here — `ClassifiedGlyph` carries no CID — so this is
        /// recorded for the dataset eyeball check: a plausible-but-wrong box
        /// on a minority of glyphs looks like nothing in `bboxMissing`.
        ///
        /// KNOWN LIMITATION 2: if two resources on one page map the SAME PUA
        /// scalar to different outlines, `ClassifiedGlyph` carries no font
        /// resource either, so the right one cannot be chosen — the
        /// sorted-first resource wins deterministically. MuseScore emits one
        /// music-font subset per page, so this has not been observed.
        ///
        /// Neither limitation can produce a wrong CLASS — only a wrong box.
        nonisolated static func invertCMaps(
            _ cmaps: [String: PDFImporter.ToUnicodeCMap],
        ) -> [UInt32: (resource: String, cid: UInt32)] {
            var out: [UInt32: (resource: String, cid: UInt32)] = [:]
            for resource in cmaps.keys.sorted() {
                guard let cmap = cmaps[resource], !cmap.isEmpty else { continue }
                for cid in UInt32(0) ... 0xFFFF {
                    guard let scalar = cmap.firstScalar(cid: cid) else { continue }
                    let value = scalar.value
                    guard (0xE000 ... 0xF8FF).contains(value), out[value] == nil
                    else { continue }
                    out[value] = (resource, cid)
                }
            }
            return out
        }

        /// Page-space ink bbox: the glyph outline's bounding box at
        /// CTFont size 1000, scaled by renderedSize/1000 about the
        /// glyph's text origin (both spaces are y-up). The 1000 is
        /// `makeCTFont`'s default `size:` — the two move together, and
        /// `recoversARealInkBBoxFromAnEmbeddedProgram` pins the coupling.
        nonisolated static func inkBBox(
            outlineAt1000: CGRect, origin: CGPoint, renderedSize: CGFloat,
        ) -> CGRect {
            let scale = renderedSize / 1000
            return CGRect(
                x: origin.x + outlineAt1000.minX * scale,
                y: origin.y + outlineAt1000.minY * scale,
                width: outlineAt1000.width * scale,
                height: outlineAt1000.height * scale,
            )
        }
    }
#endif
