#if !os(Android)
    import CoreGraphics
    import CoreText
    import Foundation
    import PDFKit
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// PDF → page labels (spec §6.6). Forced-Tier-1 walk + dual-walk
    /// codepoint pairing + ToUnicode-inversion ink bboxes. Test-side
    /// only; zero Sources/ changes (spec §4.3).
    ///
    /// LABELS ARE AUTHORITATIVE, so only Tier 1 (SMuFL PUA codepoint) may
    /// name a class. Two things hold that line:
    ///   * Tier 4 (shape matching) is off — `walkDocument`'s
    ///     `enableShapeMatching` defaults to false and is never passed here.
    ///   * Tier 2 (glyph name) keys off `characterCode`, which the CMap
    ///     path never supplies, so it cannot answer for a Type0 font.
    /// A PDF that reaches the classifier by any OTHER path (a simple font,
    /// where Tier 2 does answer) is detected by the probe walk and
    /// QUARANTINED — see `walkProblems`. A quietly-wrong label is worse
    /// than a missing document, because later gates treat these as truth.
    ///
    /// Glyphs Tier 1 cannot name are NOT dropped and NOT guessed: they keep
    /// their `unknownXXXX` class name and therefore appear in the page
    /// census, which is the per-page visibility channel for Tier-1 misses.
    @MainActor
    enum OMRLabelExport {
        struct DocumentExport {
            var pages: [OMRPageLabels]
            /// Non-empty ⇒ quarantine this document (recorded in the
            /// dataset manifest by the harness); pages may still be
            /// partially present for forensics but must not ship.
            var problems: [String]
        }

        static func export(pdfData: Data, dpi: Int) throws -> DocumentExport {
            let document = try PDFImporter.openDocument(pdfData)
            // Walk A (truth): Tier 1 authoritative, routing anchored to
            // the PUA range so A and B promote the identical glyph set.
            let truth = try PDFImporter.walkDocument(
                document, anchorMusicGlyphsToPUARange: true,
            )
            // Walk B (probe): Tier 1 disabled → every music glyph's
            // semantic is `.unknown(rawCodepoint)` on the CMap path.
            let probe = try PDFImporter.walkDocument(
                document, disableSMuFLCodepointTier: true,
                anchorMusicGlyphsToPUARange: true,
            )
            guard let paired = pairCodepoints(
                truth: truth.content.glyphs, probe: probe.content.glyphs,
            ) else {
                return DocumentExport(pages: [], problems: [
                    "dual-walk glyph count mismatch (truth "
                        + "\(truth.content.glyphs.count) vs probe "
                        + "\(probe.content.glyphs.count)) — simple-font or "
                        + "non-MuseScore PDF; cannot label",
                ])
            }
            var problems = walkProblems(paired)
            let codepoints = codepointIndex(paired)
            let outlines = OutlineResolver(document: document)
            var pages: [OMRPageLabels] = []
            for pageIndex in 0 ..< document.pageCount {
                guard let size = truth.pageSizes[pageIndex] else {
                    problems.append("page \(pageIndex): no mediaBox size")
                    continue
                }
                pages.append(OMRLabelSchema.pageLabels(
                    walked: truth.content, pageIndex: pageIndex,
                    pageSize: size, dpi: dpi,
                    imageFile: "page_\(pageIndex).png",
                    inkBBox: { glyph in
                        guard let codepoint = codepoints[glyph]?.first,
                              let em = outlines.emBox(
                                  pageIndex: pageIndex, codepoint: codepoint,
                              )
                        else { return nil }
                        return inkBBox(
                            outlineAt1000: em,
                            origin: glyph.geometry.origin,
                            renderedSize: glyph.geometry.renderedSize,
                        )
                    },
                ))
            }
            return DocumentExport(pages: pages, problems: problems)
        }

        /// Document-level rejections derived from the paired walks. Both
        /// are "this is not a Tier-1-labelable SMuFL vector score", which
        /// must quarantine rather than emit half-trusted labels.
        private static func walkProblems(
            _ paired: [(glyph: ClassifiedGlyph, codepoint: UInt32?)],
        ) -> [String] {
            var problems: [String] = []
            if paired.isEmpty {
                problems.append(
                    "no music glyph reached the classifier — "
                        + "not a SMuFL vector score; cannot label",
                )
            }
            if paired.contains(where: { $0.codepoint == nil }) {
                problems.append(
                    "probe walk answered a non-unknown semantic "
                        + "(a heuristic tier classified these glyphs, so the "
                        + "labels are not Tier-1 authoritative); affected glyphs "
                        + "carry no codepoint and no bbox",
                )
            }
            return problems
        }

        /// Codepoint(s) per distinct glyph VALUE. `pageLabels` hands the
        /// bbox closure a `ClassifiedGlyph`, not its index, so the pairing
        /// has to be re-keyed by value; `ClassifiedGlyph` is `Hashable` and
        /// its geometry carries origin + page, so a collision means two
        /// truly identical draws — for which `.first` (append order = walk
        /// order) is the same answer either way. Deterministic despite the
        /// dictionary: only the VALUE is read, never the iteration order.
        private static func codepointIndex(
            _ paired: [(glyph: ClassifiedGlyph, codepoint: UInt32?)],
        ) -> [ClassifiedGlyph: [UInt32]] {
            var out: [ClassifiedGlyph: [UInt32]] = [:]
            for pair in paired {
                if let codepoint = pair.codepoint {
                    out[pair.glyph, default: []].append(codepoint)
                }
            }
            return out
        }

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
        /// KNOWN LIMITATION: if two resources on one page map the SAME PUA
        /// scalar to different outlines, `ClassifiedGlyph` carries no font
        /// resource, so the right one cannot be chosen — the sorted-first
        /// resource wins deterministically. MuseScore emits one music-font
        /// subset per page, so this has not been observed; it would show
        /// up as an implausible bbox, not as a wrong class.
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
        /// glyph's text origin (both spaces are y-up).
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

        /// Per-page PUA-codepoint → glyph-outline lookup, built lazily and
        /// cached (a page's outlines repeat thousands of times).
        ///
        /// BEST EFFORT BY CONSTRUCTION: a page may carry no `/ToUnicode`,
        /// a font may ship no embedded program, and `CGFont` refuses some
        /// programs (bare CFF, damaged subsets). Every one of those returns
        /// nil rather than a zero rect, which `pageLabels` writes as a JSON
        /// `null` `bbox_pt` — counted and printed by the batch harness as
        /// `bboxMissing`. There is deliberately no fabricated fallback box.
        final class OutlineResolver {
            private let document: PDFDocument
            private var indexByPage: [Int: [UInt32: OutlineRef]] = [:]
            private var emBoxCache: [Int: [UInt32: CGRect?]] = [:]

            struct OutlineRef {
                var font: CTFont
                var glyphID: CGGlyph
            }

            init(document: PDFDocument) {
                self.document = document
            }

            /// Outline bbox at CTFont size 1000, or nil when unreachable.
            func emBox(pageIndex: Int, codepoint: UInt32) -> CGRect? {
                if let hit = emBoxCache[pageIndex]?[codepoint] { return hit }
                var result: CGRect?
                if let ref = index(pageIndex: pageIndex)[codepoint],
                   let path = CTFontCreatePathForGlyph(ref.font, ref.glyphID, nil),
                   !path.isEmpty
                {
                    result = path.boundingBoxOfPath
                }
                emBoxCache[pageIndex, default: [:]][codepoint] = result
                return result
            }

            private func index(pageIndex: Int) -> [UInt32: OutlineRef] {
                if let cached = indexByPage[pageIndex] { return cached }
                var index: [UInt32: OutlineRef] = [:]
                if let cgPage = document.page(at: pageIndex)?.pageRef {
                    let fonts = PDFImporter.extractEmbeddedFonts(cgPage: cgPage)
                    let inverted = invertCMaps(PDFImporter.extractFontCMaps(cgPage: cgPage))
                    var fontByResource: [String: CTFont] = [:]
                    // Sorted scalars: the result is order-independent, but
                    // sorting removes any doubt about hash-order effects.
                    for scalar in inverted.keys.sorted() {
                        guard let ref = inverted[scalar] else { continue }
                        if fontByResource[ref.resource] == nil,
                           let program = fonts[ref.resource]?.program,
                           let ctFont = makeCTFont(program: program)
                        {
                            fontByResource[ref.resource] = ctFont
                        }
                        guard let ctFont = fontByResource[ref.resource] else { continue }
                        index[scalar] = OutlineRef(
                            font: ctFont, glyphID: CGGlyph(truncatingIfNeeded: ref.cid),
                        )
                    }
                }
                indexByPage[pageIndex] = index
                return index
            }
        }
    }
#endif
