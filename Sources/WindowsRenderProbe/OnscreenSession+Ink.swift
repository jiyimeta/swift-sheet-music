import Foundation
import SheetMusicRenderWindows

extension OnscreenSession {
    /// `frames` frames at rest with an ink layer over the visible page — 300 `fillPath` overlays of about 420
    /// vertices each, the outline a host's 200-sample stroke comes to (folino `InkOutline`) — and the same frames
    /// without it; the surface's work per frame for each, so the overlay's own cost is the difference.
    func ink(frames: Int) -> (with: [Double], without: [Double]) {
        let strokes = Self.inkStrokes(count: 300, samples: 200)
        var with: [Double] = []
        var without: [Double] = []
        for _ in 0 ..< frames {
            draw(zoom: 1, originY: originY)
            without.append(surface.lastDrawTiming.workMs)
            draw(zoom: 1, originY: originY, overlays: strokes)
            with.append(surface.lastDrawTiming.workMs)
        }
        let vertices = strokes.reduce(0) { total, overlay in
            guard case let .fillPath(_, _, figures, _) = overlay else { return total }
            return total + figures.reduce(0) { $0 + $1.count }
        }
        print("ink: \(strokes.count) strokes, \(vertices) vertices per frame")
        return (with, without)
    }

    /// A grid of wavy 30 mm strokes over page 0, each one closed ribbon 0.6 mm wide with round-ish ends.
    private static func inkStrokes(count: Int, samples: Int) -> [ScoreSurface.Overlay] {
        (0 ..< count).map { index in
            let originX = 10 + Double(index % 6) * 32
            let originY = 15 + Double(index / 6) * 5.4
            var left: [PagePointMM] = []
            var right: [PagePointMM] = []
            for sample in 0 ..< samples {
                let t = Double(sample) / Double(samples - 1)
                let x = originX + 30 * t
                let y = originY + 1.5 * sin(t * 6 * .pi)
                left.append(PagePointMM(x: x, y: y - 0.3))
                right.append(PagePointMM(x: x, y: y + 0.3))
            }
            let cap = (0 ..< 8).map { step in
                PagePointMM(x: left[samples - 1].x + 0.3 * sin(Double(step) * .pi / 8), y: left[samples - 1].y)
            }
            return .fillPath(
                page: 0, id: index, figures: [left + cap + right.reversed() + cap.reversed()], argb: 0xCC1E_40C0,
            )
        }
    }
}
