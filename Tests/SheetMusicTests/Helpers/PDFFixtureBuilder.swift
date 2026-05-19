#if !os(Android)
    import CoreGraphics
    import CoreText
    import Foundation

    /// Builds a single-page PDF in memory. Used to stand in for
    /// real MuseScore PDFs in unit tests of the content-stream walker
    /// and downstream stages.
    @MainActor
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
            }

            var origin: CGPoint
            var kind: Kind
            var lineWidth: CGFloat = 0.5
        }

        /// Draw glyphs and path segments on a fresh A4 page.
        /// Returns PDF data.
        static func build(
            size: CGSize = CGSize(width: 595, height: 842),
            glyphs: [GlyphPlacement] = [],
            paths: [PathPlacement] = [],
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
    }
#endif
