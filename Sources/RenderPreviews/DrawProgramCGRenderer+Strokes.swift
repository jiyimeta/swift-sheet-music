#if os(macOS)
    import CoreGraphics
    import SheetMusicBridgeCore

    @available(macOS 15.0, *)
    extension DrawProgramCGRenderer {
        /// How the walk widens strokes, so it measures what each renderer ships.
        enum Strokes {
            /// `StrokeRaster.pen`, MuseScore's Qt way: the Windows walk (`DrawCommandWalker`).
            case pen
            /// Raised to 1.5 device pixels at full opacity: the Kotlin `ScoreCanvas`'s `coerceAtLeast(1.5f)` and
            /// `canvas.ts`'s `MIN_STROKE_PX`, and the Windows walk before it drew with the pen.
            case floor
        }

        /// The floor `Strokes.floor` raises every stroke to, in device pixels.
        static let minStrokePx: CGFloat = 1.5

        /// The draw program's `argb` as a colour.
        static func color(_ argb: UInt32) -> CGColor {
            CGColor(
                red: CGFloat((argb >> 16) & 0xFF) / 255,
                green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255,
                alpha: CGFloat((argb >> 24) & 0xFF) / 255,
            )
        }

        /// The width and the colour a stroke `widthMM` wide in `argb` is drawn with at `pxPerMM`, `strokes`' way.
        static func pen(
            widthMM: Double, pxPerMM: CGFloat, argb: UInt32, strokes: Strokes,
        ) -> (width: CGFloat, color: CGColor) {
            switch strokes {
            case .pen:
                let pen = StrokeRaster.pen(widthMM: widthMM, pxPerMM: Double(pxPerMM))
                return (CGFloat(pen.widthPx), color(StrokeRaster.color(argb, opacity: pen.opacity)))
            case .floor:
                return (max(CGFloat(widthMM) * pxPerMM, minStrokePx), color(argb))
            }
        }
    }
#endif
