#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation

    /// Builds a single-page PDF in memory. Used to stand in for
    /// real MuseScore PDFs in unit tests of the content-stream walker
    /// and downstream stages.
    enum PDFFixtureBuilder {
        struct GlyphPlacement {
            var unicodeScalar: UnicodeScalar // SMuFL PUA codepoint or ASCII
            var fontName: String // "Bravura", "Leland", "Helvetica", …
            var fontSize: CGFloat
            var origin: CGPoint
        }

        struct PathPlacement {
            enum Kind {
                case horizontal(width: CGFloat)
                case vertical(height: CGFloat)
                case rect(size: CGSize)
                /// A FILLED four-corner slab, drawn `m l l l h f` — the shape
                /// MuseScore uses for every beam line and the only one the
                /// content-stream walker captures as `PathSegment.Kind.beam`
                /// (see `PDFPageState.emitBeamIfQuad`). `.rect` will not do:
                /// it STROKES its outline and is captured as `.rectangle`.
                ///
                /// `slope` raises the right end by that many points, so a
                /// fixture can model a sloped beam and exercise `BeamQuad`'s
                /// interpolated edges rather than only the flat case.
                case beam(width: CGFloat, thickness: CGFloat, slope: CGFloat = 0)
            }

            var origin: CGPoint
            var kind: Kind
            var lineWidth: CGFloat = 0.5
        }

        /// Draw glyphs and path segments on a fresh A4 page.
        /// Returns PDF data.
        ///
        /// - Parameter dropToUnicodeCMaps: blank every `/ToUnicode N 0 R`
        ///   entry in the finished file. **Required for any fixture whose
        ///   music glyphs must actually be CLASSIFIED** — see
        ///   `strippingToUnicodeCMaps` for why.
        static func build(
            size: CGSize = CGSize(width: 595, height: 842),
            glyphs: [GlyphPlacement] = [],
            paths: [PathPlacement] = [],
            dropToUnicodeCMaps: Bool = false,
        ) -> Data {
            let data = draw(size: size, glyphs: glyphs, paths: paths)
            return dropToUnicodeCMaps ? strippingToUnicodeCMaps(from: data).data : data
        }

        private static func draw(
            size: CGSize,
            glyphs: [GlyphPlacement],
            paths: [PathPlacement],
        ) -> Data {
            let pdfData = NSMutableData()
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: pdfData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
            else {
                return Data()
            }
            ctx.beginPDFPage(nil)

            for path in paths {
                ctx.setLineWidth(path.lineWidth)
                ctx.beginPath()
                switch path.kind {
                case let .horizontal(w):
                    ctx.move(to: path.origin)
                    ctx.addLine(to: CGPoint(x: path.origin.x + w, y: path.origin.y))
                    ctx.strokePath()
                case let .vertical(h):
                    ctx.move(to: path.origin)
                    ctx.addLine(to: CGPoint(x: path.origin.x, y: path.origin.y + h))
                    ctx.strokePath()
                case let .rect(s):
                    ctx.stroke(CGRect(origin: path.origin, size: s))
                case let .beam(w, t, slope):
                    ctx.move(to: path.origin)
                    ctx.addLine(to: CGPoint(x: path.origin.x + w, y: path.origin.y + slope))
                    ctx.addLine(to: CGPoint(
                        x: path.origin.x + w, y: path.origin.y + slope + t,
                    ))
                    ctx.addLine(to: CGPoint(x: path.origin.x, y: path.origin.y + t))
                    ctx.closePath()
                    ctx.fillPath()
                }
            }

            for g in glyphs {
                let font = CTFontCreateWithName(g.fontName as CFString, g.fontSize, nil)
                let attr: [NSAttributedString.Key: Any] = [.font: font]
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: String(g.unicodeScalar), attributes: attr),
                )
                ctx.textPosition = g.origin
                CTLineDraw(line, ctx)
            }

            ctx.endPDFPage()
            ctx.closePDF()
            return pdfData as Data
        }

        /// Blank every `/ToUnicode N 0 R` entry, padding with spaces so all
        /// byte offsets in the xref table stay valid. Returns the patched
        /// data and how many entries were blanked.
        ///
        /// CoreGraphics embeds a music face as a SIMPLE font carrying
        /// `/Encoding /Differences [ 33 /uniE0A4 … ]` — precisely Tier 2's
        /// key space — but it also writes a `/ToUnicode` CMap mapping those
        /// codes to unrelated Latin scalars (a notehead decodes as "K").
        /// The importer routes any resource that has a CMap down the CMap
        /// path, which by design never consults `/Differences` because the
        /// two key spaces do not coincide (see `GlyphClassifier.classify`'s
        /// `characterCode` parameter). So with the CMap present, notation
        /// glyphs decode to junk text and NO tier classifies them —
        /// measured: 0 classified glyphs, 0 chords. Dropping the CMap puts
        /// the resource on the simple-font path where the `uniXXXX` names
        /// resolve — measured on the same fixture: 9 classified glyphs, 8
        /// chords, 8 lyrics.
        ///
        /// This is a property of CoreGraphics' PDF writer, not of the
        /// importer: a real MuseScore PDF carries a `/ToUnicode` that maps
        /// to the SMuFL PUA codepoints, so its music glyphs classify
        /// through Tier 1 on the CMap path. A CoreGraphics fixture cannot
        /// reproduce that mapping, so it exercises Tier 2 instead.
        static func strippingToUnicodeCMaps(from data: Data) -> (data: Data, blanked: Int) {
            guard var text = String(data: data, encoding: .isoLatin1) else { return (data, 0) }
            var blanked = 0
            while let entry = text.range(
                of: #"/ToUnicode\s+\d+\s+\d+\s+R"#, options: .regularExpression,
            ) {
                text.replaceSubrange(
                    entry, with: String(repeating: " ", count: text[entry].count),
                )
                blanked += 1
            }
            return (text.data(using: .isoLatin1) ?? data, blanked)
        }
    }
#endif
