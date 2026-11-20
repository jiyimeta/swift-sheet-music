/// How a renderer that walks the draw program into device pixels draws a `stroke(width:)`: MuseScore's way, which is
/// Qt's raster engine's.
///
/// MuseScore hands every line to QPainter at its own width, antialiased, with no floor and no cosmetic pen (its
/// `TDraw::draw` for staff lines, ledger lines and stems). Qt then draws a pen no wider than one device pixel through
/// its cosmetic stroker: one pixel wide, at an opacity of the pen's width in pixels (`qpaintengine_raster.cpp`'s
/// `fast_pen`, `qcosmeticstroker.cpp`'s `opacity = 256 * width * txscale`), shared between the two rows (or columns)
/// it falls across, with no snapping to the pixel grid. A wider pen is stroked at its own width.
///
/// So here:
///
/// - a stroke one pixel wide or wider is drawn at its own width;
/// - a thinner one is drawn one pixel wide at the opacity that puts down the ink its own width would (a 0.4 px line is
///   a one-pixel line at 40%): it neither grows nor vanishes;
/// - a width of zero or less (or not a number) is the thinnest line the device draws — one pixel, fully opaque — as Qt,
///   CoreGraphics and PDF read a zero width.
///
/// What it replaces: the Windows walk raised every stroke to 1.5 px (or 0.4 mm zoomed out), the Kotlin `ScoreCanvas`
/// and `canvas.ts` floor, at full opacity — a staff line (~0.23 mm, ~0.87 px at 96 dpi and 100%) drawn ~1.7 times its
/// width, more the further out it zoomed, beside a Mac that draws it at its own width (folino owner's QA, 2026-11-20).
///
/// Pure, so the Windows walk (`DrawCommandWalker`) and the Mac's reference walk (RenderPreviews'
/// `DrawProgramCGRenderer`) take the same answer, and the host tests pin it.
public enum StrokeRaster {
    /// The pen one `stroke(width:)` draws with.
    public struct Pen: Equatable, Sendable {
        /// The width handed to the rasterizer, in device pixels.
        public let widthPx: Double
        /// What the current colour's alpha is multiplied by, 0 … 1.
        public let opacity: Double

        public init(widthPx: Double, opacity: Double) {
            self.widthPx = widthPx
            self.opacity = opacity
        }
    }

    /// The pen for a stroke `widthMM` wide on a device of `pxPerMM` pixels per millimetre.
    public static func pen(widthMM: Double, pxPerMM: Double) -> Pen {
        let width = widthMM * pxPerMM
        guard width.isFinite, width > 0 else { return Pen(widthPx: 1, opacity: 1) }
        return width >= 1 ? Pen(widthPx: width, opacity: 1) : Pen(widthPx: 1, opacity: width)
    }

    /// `argb` with its alpha multiplied by `opacity` (0 … 1), rounded: the colour a renderer strokes `pen` in.
    public static func color(_ argb: UInt32, opacity: Double) -> UInt32 {
        guard opacity < 1 else { return argb }
        let alpha = Double(argb >> 24) * max(opacity, 0)
        return UInt32(alpha.rounded()) << 24 | argb & 0x00FF_FFFF
    }
}
