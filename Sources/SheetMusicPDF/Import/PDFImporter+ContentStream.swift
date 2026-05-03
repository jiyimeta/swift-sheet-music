import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

extension PDFImporter {
    /// Low-level content-stream walker. Enumerates each page in the
    /// document, registers `CGPDFOperatorCallback`s for the operators
    /// we care about, and collects raw glyphs / text runs / drawn path
    /// segments in PDF page coordinates.
    ///
    /// CTM, text matrix, font, and current path are tracked in a small
    /// per-page interpreter (`PageState`) which is bridged through the
    /// `CGPDFScanner`'s opaque `info` pointer via `Unmanaged`.
    struct ContentStreamWalker {
        let document: PDFDocument

        struct Output {
            var glyphs: [RawGlyph]
            var texts: [TextGlyph]
            var paths: [PathSegment]
        }

        func walk() throws -> Output {
            var glyphs: [RawGlyph] = []
            var texts: [TextGlyph] = []
            var paths: [PathSegment] = []
            for pageIndex in 0 ..< document.pageCount {
                guard let page = document.page(at: pageIndex),
                      let cgPage = page.pageRef
                else { continue }
                let state = PageState(pageIndex: pageIndex)
                walkPage(cgPage: cgPage, state: state)
                glyphs.append(contentsOf: state.glyphs)
                texts.append(contentsOf: state.texts)
                paths.append(contentsOf: state.paths)
            }
            return Output(glyphs: glyphs, texts: texts, paths: paths)
        }

        // Class because we hold it via Unmanaged for the C info pointer.
        final class PageState {
            let pageIndex: Int
            // CTM stack. q pushes a copy, Q pops, cm concats into top.
            var ctmStack: [CGAffineTransform] = [.identity]
            // Text state.
            var textMatrix: CGAffineTransform = .identity
            var lineMatrix: CGAffineTransform = .identity
            var fontName: String = ""
            var fontSize: CGFloat = 0
            // Current subpath: starts at last `m`, accumulates points
            // from `l`. `currentPoint` follows the latest `m` or `l`.
            var currentPoint: CGPoint?
            // Recorded straight line segments (start, end) that came from
            // an `m → l` pair, in user-space coordinates as of the time
            // the `l` operator ran. CTM is captured per-segment because
            // `q`/`Q`/`cm` may run between `m` and `l`.
            var pendingLines: [(CGPoint, CGPoint, CGAffineTransform)] = []
            // Recorded rectangles from `re`, paired with the CTM at
            // construction time.
            var pendingRects: [(CGRect, CGAffineTransform)] = []
            // Outputs.
            var glyphs: [RawGlyph] = []
            var texts: [TextGlyph] = []
            var paths: [PathSegment] = []
            var lineWidth: CGFloat = 1.0

            init(pageIndex: Int) { self.pageIndex = pageIndex }

            var ctm: CGAffineTransform { ctmStack.last ?? .identity }

            func setTopCTM(_ value: CGAffineTransform) {
                if ctmStack.isEmpty { ctmStack.append(value) } else {
                    ctmStack[ctmStack.count - 1] = value
                }
            }

            func resetPath() {
                currentPoint = nil
                pendingLines.removeAll(keepingCapacity: true)
                pendingRects.removeAll(keepingCapacity: true)
            }

            /// Convert each `pendingLines` / `pendingRects` entry into a
            /// `PathSegment`, classified as horizontal/vertical/rectangle
            /// in page coordinates. Curves and diagonals are dropped.
            func flushPaintedPath() {
                for (p0u, p1u, ctm) in pendingLines {
                    let p0 = p0u.applying(ctm)
                    let p1 = p1u.applying(ctm)
                    let dx = abs(p1.x - p0.x)
                    let dy = abs(p1.y - p0.y)
                    let kind: PathSegment.Kind?
                    if dy < 0.5, dx > 0.5 {
                        kind = .horizontal
                    } else if dx < 0.5, dy > 0.5 {
                        kind = .vertical
                    } else {
                        kind = nil
                    }
                    guard let kind else { continue }
                    let rect = CGRect(
                        x: min(p0.x, p1.x),
                        y: min(p0.y, p1.y),
                        width: dx,
                        height: dy
                    )
                    paths.append(.init(
                        kind: kind,
                        rect: rect,
                        lineWidth: lineWidth,
                        pageIndex: pageIndex
                    ))
                }
                for (rect, ctm) in pendingRects {
                    let transformed = rect.applying(ctm)
                    paths.append(.init(
                        kind: .rectangle,
                        rect: transformed,
                        lineWidth: lineWidth,
                        pageIndex: pageIndex
                    ))
                }
                resetPath()
            }
        }

        private func walkPage(cgPage: CGPDFPage, state: PageState) {
            guard let table = CGPDFOperatorTableCreate() else { return }
            defer { CGPDFOperatorTableRelease(table) }
            ContentStreamOperators.register(on: table)
            let stream = CGPDFContentStreamCreateWithPage(cgPage)
            let info = Unmanaged.passUnretained(state).toOpaque()
            let scanner = CGPDFScannerCreate(stream, table, info)
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            CGPDFContentStreamRelease(stream)
        }
    }

    /// CID → Unicode lookup. v1 walker uses identity; SMuFL fonts in
    /// MuseScore exports ship CIDs that already equal the SMuFL PUA
    /// codepoint, so identity covers the SMuFL path.
    struct ToUnicodeCMap {
        static let identity = ToUnicodeCMap()
        func map(cid: UInt32) -> UInt32 { cid }
    }
}
