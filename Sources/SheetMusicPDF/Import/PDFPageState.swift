#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// Per-page content-stream interpreter state. Populated by a front-end
/// (Apple `CGPDFScanner` walker, or the Foundation-only Android tokenizer)
/// calling the `op*()` methods in `PDFImporter+Interpreter`; the accumulated
/// `glyphs` / `texts` / `paths` / `curveArcs` become the page's slice of
/// `WalkedContent`.
///
/// A class (not a struct) because the Apple front-end holds it via `Unmanaged`
/// for the `CGPDFScanner` opaque `info` pointer. Top-level (not nested in the
/// Apple walker) so the Foundation-only decode side can build it on Android.
final class PDFPageState {
    let pageIndex: Int
    /// CTM stack. q pushes a copy, Q pops, cm concats into top.
    var ctmStack: [CGAffineTransform] = [.identity]
    // Text state.
    var textMatrix: CGAffineTransform = .identity
    var lineMatrix: CGAffineTransform = .identity
    var fontName = ""
    var fontSize: CGFloat = 0
    /// Per-page registry of `/ToUnicode` CMaps keyed by the font RESOURCE
    /// NAME (the key op_Tf receives, e.g. "F10"). Filled by the front-end
    /// from the page's Resources → Font dict.
    var fontCMaps: [String: PDFImporter.ToUnicodeCMap] = [:]
    /// The CMap selected by the most recent `Tf` (nil for fonts without a
    /// usable `/ToUnicode`, e.g. the ASCII test fixtures).
    var activeCMap: PDFImporter.ToUnicodeCMap?
    /// Per-page registry of simple-font TEXT decoders keyed by font RESOURCE
    /// NAME, filled by the front-end alongside `fontCMaps`. A font that
    /// declares neither `/Differences` nor a modeled base encoding has no
    /// entry — see `SimpleFontTextDecoder.init?`.
    var simpleFontDecoders: [String: SimpleFontTextDecoder] = [:]
    /// The decoder selected by the most recent `Tf` (nil for a font with
    /// nothing declared, which keeps the legacy whole-run decode).
    var activeSimpleFontDecoder: SimpleFontTextDecoder?
    /// TESTING ONLY. See `PDFImportOptions.anchorMusicGlyphsToPUARange`.
    /// Set once per page by the front-end walker from that option; consulted
    /// by `emitShow` when deciding whether a decoded scalar is music or text.
    var anchorMusicToPUARange = false
    #if canImport(CoreGraphics)
        /// Per-page registry of glyph classifiers keyed by font RESOURCE
        /// NAME, filled by the front-end alongside `fontCMaps`.
        /// `GlyphClassifier` is CoreText-based (Apple-only), so this
        /// registry does not exist on Android.
        var classifiers: [String: GlyphClassifier] = [:]
        /// The classifier selected by the most recent `Tf`.
        var activeClassifier: GlyphClassifier?
    #endif
    /// Current subpath: starts at last `m`, accumulates points from `l`.
    /// `currentPoint` follows the latest `m` or `l`.
    var currentPoint: CGPoint?
    /// Recorded straight line segments (start, end) that came from an
    /// `m → l` pair, in user-space coordinates as of the time the `l`
    /// operator ran. CTM is captured per-segment because `q`/`Q`/`cm` may
    /// run between `m` and `l`.
    var pendingLines: [(CGPoint, CGPoint, CGAffineTransform)] = []
    /// Recorded rectangles from `re`, paired with the CTM at construction.
    var pendingRects: [(CGRect, CGAffineTransform)] = []
    /// Ordered user-space vertices of the CURRENT subpath (from the last `m`
    /// through subsequent `l`s). Paired with the CTM as of the `m`. Used to
    /// recognize a beam quadrilateral on a fill. A `c`/`v`/`y` curve clears
    /// this (beams are straight quads), so a curved subpath can never be
    /// misread as a beam.
    var pendingPolyPoints: [CGPoint] = []
    var pendingPolyCTM: CGAffineTransform = .identity
    var pendingPolyHasCurve = false
    // Outputs.
    var glyphs: [ClassifiedGlyph] = []
    var texts: [TextGlyph] = []
    var paths: [PathSegment] = []
    var curveArcs: [CurveArc] = []
    var lineWidth: CGFloat = 1.0

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
    }

    var ctm: CGAffineTransform {
        ctmStack.last ?? .identity
    }

    func setTopCTM(_ value: CGAffineTransform) {
        if ctmStack.isEmpty { ctmStack.append(value) } else {
            ctmStack[ctmStack.count - 1] = value
        }
    }

    func resetPath() {
        currentPoint = nil
        pendingLines.removeAll(keepingCapacity: true)
        pendingRects.removeAll(keepingCapacity: true)
        pendingPolyPoints.removeAll(keepingCapacity: true)
        pendingPolyHasCurve = false
    }

    /// Convert each `pendingLines` / `pendingRects` entry into a
    /// `PathSegment`, classified as horizontal/vertical/rectangle in page
    /// coordinates. Curves and diagonals are dropped.
    ///
    /// `fill` is true for fill / fill-and-stroke paint operators. On a fill,
    /// the accumulated subpath is first tested for a beam quadrilateral
    /// (MuseScore renders each beam line as a filled `m l l l (h) f`
    /// parallelogram); a match emits a `.beam` segment and the per-edge
    /// straight-line capture is skipped so the beam's flat top / bottom edge
    /// is not also logged as a short horizontal.
    func flushPaintedPath(fill: Bool) {
        if fill, pendingPolyHasCurve {
            emitCurveArc()
            resetPath()
            return
        }
        if fill, emitBeamIfQuad() {
            resetPath()
            return
        }
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
                height: dy,
            )
            paths.append(.init(
                kind: kind,
                rect: rect,
                lineWidth: lineWidth,
                pageIndex: pageIndex,
            ))
        }
        for (rect, ctm) in pendingRects {
            let transformed = rect.applying(ctm)
            paths.append(.init(
                kind: .rectangle,
                rect: transformed,
                lineWidth: lineWidth,
                pageIndex: pageIndex,
            ))
        }
        resetPath()
    }

    /// If the current subpath is a thin filled parallelogram (a beam line),
    /// append a `.beam` segment and return true.
    ///
    /// MuseScore draws each beam line as `m l l l (h) f` — four distinct
    /// corners. After dropping the duplicate close point we expect exactly
    /// four unique vertices forming a near-horizontal slab: width 2–175pt
    /// (one stem-to-stem span; fractional / partial beams are the short end)
    /// and bounding-box height < 12pt (a single beam is ~2pt thick; the slope
    /// of a sloped beam pushes the bbox height up to ~8pt but never near a
    /// notehead's). The page-space bounding box becomes the segment rect so
    /// the rhythm pass can overlap-test it against stems.
    ///
    /// The lower bound is 2pt, not the 4pt it started at, because a
    /// fractional beam is ~1.25 SPACES wide — an absolute floor is really a
    /// staff-size threshold in disguise. A six-staff page engraves at ~2.85pt
    /// per space, putting its fractional beams at ~3.6pt, under the old
    /// floor; the quad then fell through to the per-edge capture below, its
    /// two short edges became phantom `.vertical` "stems" sitting exactly
    /// where `stubOwner` looks for the stub's owner, and every
    /// dotted-eighth + sixteenth pair lost the sixteenth's secondary beam
    /// (read as an eighth). Nothing downstream trusts a beam on width alone —
    /// `beamLevels` still requires it to attach to a stem and overlap that
    /// stem's band — so the floor only has to clear sub-2pt noise.
    func emitBeamIfQuad() -> Bool {
        guard !pendingPolyHasCurve else { return false }
        let pts = uniquePolyVertices()
        guard pts.count == 4 else { return false }
        let page = pts.map { $0.applying(pendingPolyCTM) }
        let xs = page.map(\.x)
        let ys = page.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return false }
        let w = maxX - minX
        let h = maxY - minY
        guard w >= 2, w <= 175, h < 12 else { return false }
        let quad = PDFImporter.fitBeamQuad(corners: page, pageIndex: pageIndex)
        paths.append(.init(
            kind: .beam,
            rect: CGRect(x: minX, y: minY, width: w, height: h),
            lineWidth: lineWidth,
            pageIndex: pageIndex,
            quad: quad,
        ))
        return true
    }

    /// Turn the current curved subpath into a `CurveArc` (page space). The
    /// on-path vertices we recorded are the `m` anchor plus each Bezier
    /// endpoint, which trace the outline of the filled tie/slur lens — enough
    /// to recover the bbox and the left / right extreme anchor points the tie
    /// decoder pairs to noteheads. Tiny dots (augmentation dots are also
    /// filled curves) are dropped by a minimum-width gate.
    func emitCurveArc() {
        let pts = pendingPolyPoints.map { $0.applying(pendingPolyCTM) }
        guard pts.count >= 2 else { return }
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return }
        let w = maxX - minX
        let h = maxY - minY
        // Augmentation dots / noteheads close as ~2pt circles; a tie or slur
        // arc spans at least ~6pt. Drop sub-6pt curves — EXCEPT clearly flat
        // narrow arcs: dense 16th-note ties render only 3.3–5.9pt wide
        // (height 1.6–2.6pt). Flatness (height well under width) separates
        // them from round dots (height ≈ width). Same band as `isTieShaped`
        // (PDFImporter+Ties.swift).
        let flatNarrow = w >= PDFImporter.tieNarrowWidthMin
            && h <= PDFImporter.tieNarrowFlatnessRatio * w
        guard w >= 6 || flatNarrow else { return }
        let left = pts.min { $0.x < $1.x } ?? pts[0]
        let right = pts.max { $0.x < $1.x } ?? pts[pts.count - 1]
        curveArcs.append(CurveArc(
            bbox: CGRect(x: minX, y: minY, width: w, height: h),
            leftPoint: left,
            rightPoint: right,
            pageIndex: pageIndex,
        ))
    }

    /// De-duplicate the subpath vertices, collapsing a trailing close-point
    /// that coincides with the first vertex and any exact repeats. Beams
    /// arrive as 4 or 5 raw points.
    private func uniquePolyVertices() -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pendingPolyPoints {
            if let last = out.last,
               abs(last.x - p.x) < 0.01, abs(last.y - p.y) < 0.01
            { continue }
            out.append(p)
        }
        if out.count >= 2, let first = out.first, let last = out.last,
           abs(first.x - last.x) < 0.01, abs(first.y - last.y) < 0.01
        { out.removeLast() }
        return out
    }
}
