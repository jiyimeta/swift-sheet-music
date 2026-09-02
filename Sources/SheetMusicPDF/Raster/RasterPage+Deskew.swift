import Foundation

extension RasterPage {
    /// Coarse-to-fine projection-profile deskew, in degrees, positive
    /// counter-clockwise.
    ///
    /// For a candidate angle the row projection is computed by SHEARING
    /// the accumulation — the row a column contributes to is offset by
    /// `(x − cx)·tan θ` — rather than by rotating the mask. At these
    /// angles the two agree to well under a pixel, and the shear needs no
    /// resampling. The score is the sum of squared bin counts, maximized
    /// when ink concentrates into few rows, i.e. when the staff lines are
    /// horizontal.
    ///
    /// This step is not optional and not a refinement. Measured against
    /// the labels on 74 pages, a plain row projection recovers 91–96% of
    /// staff lines on clean rasters, **8–33%** after the scanner
    /// degradation profile, and 91–96% again once deskew runs. The
    /// collapse is geometric: the profile draws up to ±2°, which across a
    /// 2550-px page moves a line's y by ±44px — nearly two staff spaces —
    /// so the five lines of one staff smear into each other.
    ///
    /// One angle per page, not one per staff band:
    /// `Training/generate/degrade.py`'s `stage_rotate` applies a single
    /// rigid rotation, so a per-band angle would be fitting noise this
    /// data does not contain. Real-scan page curvature is a later
    /// concern, and the staff model is stored as per-line fits so it can
    /// arrive without reshaping anything.
    static func estimateSkewDegrees(_ mask: InkMask) -> Double {
        let coarse = search(mask, center: 0, halfSpan: 2.5, step: 0.25)
        return search(mask, center: coarse, halfSpan: 0.25, step: 0.02)
    }

    /// The MIDPOINT of the maximizing plateau, not its first member.
    ///
    /// The shear offset is rounded to whole rows, so every angle small
    /// enough to move no column by half a row scores identically — the
    /// score is a plateau, not a peak. Taking the first maximum therefore
    /// returns the most negative angle of the plateau rather than its
    /// centre: measured on an upright 600px-wide staff the plateau spans
    /// ±0.38° and the first-maximum rule returned −0.42° for a page with
    /// no skew at all. (`otsuThreshold` has the same shape of tie for the
    /// same kind of reason.)
    private static func search(
        _ mask: InkMask, center: Double, halfSpan: Double, step: Double,
    ) -> Double {
        var low = center
        var high = center
        var bestScore = -1.0
        var angle = center - halfSpan
        while angle <= center + halfSpan + 1e-9 {
            let score = projectionSharpness(mask, degrees: angle)
            if score > bestScore {
                bestScore = score
                low = angle
                high = angle
            } else if score == bestScore {
                high = angle
            }
            angle += step
        }
        return (low + high) / 2
    }

    /// Sum of squared row-projection bins at a candidate angle, on a 4×
    /// decimated mask — 16× cheaper, and far finer than the angle step it
    /// is scoring.
    private static func projectionSharpness(_ mask: InkMask, degrees: Double) -> Double {
        let stride = 4
        let width = mask.width / stride
        let height = mask.height / stride
        guard width > 0, height > 0 else { return 0 }
        let slope = tan(degrees * .pi / 180)
        let centerX = Double(width) / 2
        var bins = [Double](repeating: 0, count: height)
        for sx in 0 ..< width {
            // MINUS: the shear must UNDO the page's rotation, so a page
            // skewed by +θ is straightened by shearing by −θ. Getting
            // this backwards is not a small error — the estimate comes
            // back negated, `rotate(_:degrees: -angle)` then doubles the
            // skew instead of removing it, and the only visible symptom
            // is that staff detection gets worse.
            let offset = -Int(((Double(sx) - centerX) * slope).rounded())
            let x = sx * stride
            for sy in 0 ..< height where mask[x, sy * stride] {
                let row = sy + offset
                guard row >= 0, row < height else { continue }
                bins[row] += 1
            }
        }
        var total = 0.0
        for bin in bins {
            total += bin * bin
        }
        return total
    }

    /// Bilinear rotation about the image centre, positive
    /// counter-clockwise, same canvas size, paper outside.
    ///
    /// The pixels really move; carrying only an angle would break every
    /// column-wise primitive downstream. A barline spanning a grand staff
    /// is ~700px tall and drifts ~25px across its own length at 2°, so
    /// its column runs would fragment into nothing.
    ///
    /// Rotation happens on GRAYSCALE and binarization follows, because
    /// rotating a binary mask produces jagged edges that then read as ink
    /// texture — and at 200dpi a staff line is only 1.2px thick, so that
    /// texture is the same size as the feature.
    static func rotate(_ bitmap: GrayBitmap, degrees: Double) -> GrayBitmap {
        guard degrees != 0 else { return bitmap }
        var out = bitmap
        let centerX = Double(bitmap.width - 1) / 2
        let centerY = Double(bitmap.height - 1) / 2
        let t = degrees * .pi / 180
        let cosT = cos(t)
        let sinT = sin(t)
        for y in 0 ..< bitmap.height {
            let dy = Double(y) - centerY
            for x in 0 ..< bitmap.width {
                let dx = Double(x) - centerX
                out[x, y] = sample(
                    bitmap,
                    x: cosT * dx + sinT * dy + centerX,
                    y: -sinT * dx + cosT * dy + centerY,
                )
            }
        }
        return out
    }

    private static func sample(_ bitmap: GrayBitmap, x: Double, y: Double) -> UInt8 {
        let x0 = Int(x.rounded(.down))
        let y0 = Int(y.rounded(.down))
        guard x0 >= 0, y0 >= 0, x0 + 1 < bitmap.width, y0 + 1 < bitmap.height else {
            return 255
        }
        let fx = x - Double(x0)
        let fy = y - Double(y0)
        let top = Double(bitmap[x0, y0]) * (1 - fx) + Double(bitmap[x0 + 1, y0]) * fx
        let bottom = Double(bitmap[x0, y0 + 1]) * (1 - fx)
            + Double(bitmap[x0 + 1, y0 + 1]) * fx
        return UInt8(min(255.0, max(0.0, top * (1 - fy) + bottom * fy)))
    }
}
