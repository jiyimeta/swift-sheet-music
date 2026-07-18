import Foundation

// Foundation-only geometry shim for non-Apple platforms (Android / Linux).
//
// The PDF importer's math is written against CoreGraphics value types. Under
// the Swift Android SDK, Foundation already vends `CGPoint` / `CGSize` /
// `CGRect` / `CGFloat` (and the `CGRect` properties the importer reads), but
// NOT `CGAffineTransform` nor the `.applying(_:)` transform-application
// methods. This file supplies exactly that missing surface with byte-for-byte
// CoreGraphics row-vector semantics, so the (unchanged) importer produces
// identical results on Apple and Android.
//
// Gated on `!canImport(CoreGraphics)`: a no-op on Apple (the native
// CoreGraphics types win); active on Android / Linux. The CG API surface the
// importer actually uses is tiny — `CGAffineTransform`, `.applying`,
// `.concatenating` — so this shim is the whole geometry-portability story.
//
// See docs/superpowers/specs/2026-07-12-pdf-import-android-design.md §3, §5.

#if !canImport(CoreGraphics)

    /// A 2-D affine transform, matching `CoreGraphics.CGAffineTransform`.
    ///
    /// Row-vector convention (as CoreGraphics): a point `(x, y)` maps to
    /// `(a·x + c·y + tx, b·x + d·y + ty)`.
    struct CGAffineTransform: Equatable {
        var a, b, c, d, tx, ty: CGFloat

        init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.tx = tx
            self.ty = ty
        }

        /// Translation-only transform (matches `CGAffineTransform(translationX:y:)`).
        init(translationX tx: CGFloat, y ty: CGFloat) {
            self.init(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: ty)
        }

        static let identity = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

        /// `self` followed by `t`. Matches CoreGraphics such that
        /// `p.applying(self.concatenating(t)) == p.applying(self).applying(t)`.
        func concatenating(_ t: CGAffineTransform) -> CGAffineTransform {
            CGAffineTransform(
                a: a * t.a + b * t.c,
                b: a * t.b + b * t.d,
                c: c * t.a + d * t.c,
                d: c * t.b + d * t.d,
                tx: tx * t.a + ty * t.c + t.tx,
                ty: tx * t.b + ty * t.d + t.ty,
            )
        }
    }

    extension CGPoint {
        /// Apply an affine transform (CoreGraphics semantics).
        func applying(_ t: CGAffineTransform) -> CGPoint {
            CGPoint(x: t.a * x + t.c * y + t.tx, y: t.b * x + t.d * y + t.ty)
        }
    }

    extension CGRect {
        /// Axis-aligned bounding box of the four transformed corners
        /// (CoreGraphics semantics — a rotated/skewed rect returns its bbox).
        func applying(_ t: CGAffineTransform) -> CGRect {
            let corners = [
                CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
                CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY),
            ].map { $0.applying(t) }
            let xs = corners.map(\.x)
            let ys = corners.map(\.y)
            let loX = xs.min() ?? 0
            let loY = ys.min() ?? 0
            let hiX = xs.max() ?? 0
            let hiY = ys.max() ?? 0
            return CGRect(x: loX, y: loY, width: hiX - loX, height: hiY - loY)
        }
    }

#endif
