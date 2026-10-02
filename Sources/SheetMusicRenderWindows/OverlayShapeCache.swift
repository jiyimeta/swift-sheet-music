import CDirect2D

/// The `fillPath` overlays' shapes, built once per overlay `id` and filled every frame after.
///
/// An ink layer is hundreds of outlines of hundreds of points, redrawn on every frame of a scroll or of playback;
/// building each as a path again every frame cost a 2-core machine 9 ms a frame at 300 strokes (folino ink spec §9).
/// A shape is a path geometry of the surface's factory, in millimetres and scaled at fill time, so zoom does not
/// rebuild it and a device loss does not invalidate it.
///
/// The overlay's contract is that one id means one set of figures. A cheap signature (figure and point counts, the
/// first and last points) still guards it: a host that reuses an id for different figures gets them rebuilt rather
/// than the old shape drawn. A shape no frame has used for `idleFrames` frames is released.
struct OverlayShapeCache {
    static let idleFrames = 600

    private struct Signature: Equatable {
        let figureCount: Int
        let pointCount: Int
        let first: PagePointMM?
        let last: PagePointMM?

        init(_ figures: [[PagePointMM]]) {
            figureCount = figures.count
            pointCount = figures.reduce(0) { $0 + $1.count }
            first = figures.first?.first
            last = figures.last?.last
        }
    }

    private struct Entry {
        let shape: OpaquePointer
        let signature: Signature
        var lastFrame: Int
    }

    private var entries: [Int: Entry] = [:]
    private var frame = 0

    var count: Int {
        entries.count
    }

    /// The shape for `id`, built on `canvas` when there is none for these figures; `nil` when the figures fill nothing
    /// or Direct2D could not build it.
    mutating func shape(id: Int, figures: [[PagePointMM]], canvas: OpaquePointer) -> OpaquePointer? {
        let signature = Signature(figures)
        if var entry = entries[id], entry.signature == signature {
            entry.lastFrame = frame
            entries[id] = entry
            return entry.shape
        }
        if let stale = entries.removeValue(forKey: id) {
            cd2d_shape_release(stale.shape)
        }
        guard let shape = Self.build(figures, on: canvas) else { return nil }
        entries[id] = Entry(shape: shape, signature: signature, lastFrame: frame)
        return shape
    }

    /// Ends a frame: releases the shapes no frame has used for `idleFrames` frames.
    mutating func endFrame() {
        frame += 1
        let idle = entries.filter { frame - $0.value.lastFrame > Self.idleFrames }
        for (id, entry) in idle {
            cd2d_shape_release(entry.shape)
            entries[id] = nil
        }
    }

    mutating func releaseAll() {
        for entry in entries.values {
            cd2d_shape_release(entry.shape)
        }
        entries.removeAll()
    }

    /// One shape from `figures` (millimetres), or `nil` when no figure has three points or Direct2D fails.
    static func build(_ figures: [[PagePointMM]], on canvas: OpaquePointer) -> OpaquePointer? {
        let drawn = figures.filter { $0.count >= 3 }
        guard !drawn.isEmpty else { return nil }
        var xy: [Float] = []
        xy.reserveCapacity(drawn.reduce(0) { $0 + $1.count } * 2)
        for figure in drawn {
            for point in figure {
                xy.append(Float(point.x))
                xy.append(Float(point.y))
            }
        }
        let counts = drawn.map { UInt32($0.count) }
        var created: OpaquePointer?
        let result = xy.withUnsafeBufferPointer { points in
            counts.withUnsafeBufferPointer { sizes in
                cd2d_shape_create(canvas, points.baseAddress, sizes.baseAddress, UInt32(sizes.count), &created)
            }
        }
        return result == 0 ? created : nil
    }
}
