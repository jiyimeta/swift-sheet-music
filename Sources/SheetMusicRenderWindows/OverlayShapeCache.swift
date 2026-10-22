import CDirect2D

/// The `fillPath` overlays' shapes, built once per overlay `id` and filled every frame after.
///
/// An ink layer is hundreds of outlines of hundreds of points, redrawn on every frame of a scroll or of playback;
/// building each as a path again every frame cost a 2-core machine 9 ms a frame at 300 strokes (folino ink spec §9).
/// A shape is a path geometry of the surface's factory, in millimetres and scaled at fill time, so zoom does not
/// rebuild it and a device loss does not invalidate it.
///
/// The overlay's contract is that one id means one set of figures — and, for `clippedFillPath`, one clip. A cheap
/// signature (figure and point counts, the first and last points, and the clip's same four plus its fill rule) still
/// guards it: a host that reuses an id for different figures gets them rebuilt rather than the old shape drawn.
///
/// **The signature is not a hash.** Two sets of figures that agree on those counts and end points but differ in
/// between pass for the same, and the old shape is drawn. So a host must give an overlay a new id whenever its figures
/// or its clip may have changed in between — folino folds its ink layer's revision into every overlay id, so an edited
/// stroke or a narrowed mask always arrives under an id this cache has not seen. A shape no frame has used for
/// `idleFrames` frames is released.
struct OverlayShapeCache {
    static let idleFrames = 600

    private struct Signature: Equatable {
        let figureCount: Int
        let pointCount: Int
        let first: PagePointMM?
        let last: PagePointMM?
        /// The clip's own signature, so the same strokes under a new mask are rebuilt.
        let clip: ClipSignature?

        struct ClipSignature: Equatable {
            let figureCount: Int
            let pointCount: Int
            let first: PagePointMM?
            let last: PagePointMM?
            let evenOdd: Bool
        }

        init(_ figures: [[PagePointMM]], clip: ScoreSurface.OverlayClip? = nil) {
            figureCount = figures.count
            pointCount = figures.reduce(0) { $0 + $1.count }
            first = figures.first?.first
            last = figures.last?.last
            self.clip = clip.map { clip in
                ClipSignature(
                    figureCount: clip.figures.count, pointCount: clip.figures.reduce(0) { $0 + $1.count },
                    first: clip.figures.first?.first, last: clip.figures.last?.last, evenOdd: clip.evenOdd,
                )
            }
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

    /// The shape for `id`, built on `canvas` when there is none for these figures (inside `clip`, when there is one);
    /// `nil` when the figures fill nothing or Direct2D could not build it.
    mutating func shape(
        id: Int, figures: [[PagePointMM]], clip: ScoreSurface.OverlayClip? = nil, canvas: OpaquePointer,
    ) -> OpaquePointer? {
        let signature = Signature(figures, clip: clip)
        if var entry = entries[id], entry.signature == signature {
            entry.lastFrame = frame
            entries[id] = entry
            return entry.shape
        }
        if let stale = entries.removeValue(forKey: id) {
            cd2d_shape_release(stale.shape)
        }
        guard let shape = Self.build(figures, clip: clip, on: canvas) else { return nil }
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

    /// One shape from `figures` (millimetres), kept only inside `clip` when there is one; `nil` when no figure has
    /// three points, a clip has none either (nothing lies inside an empty clip), or Direct2D fails.
    static func build(
        _ figures: [[PagePointMM]], clip: ScoreSurface.OverlayClip? = nil, on canvas: OpaquePointer,
    ) -> OpaquePointer? {
        guard let shape = Flat(figures) else { return nil }
        var created: OpaquePointer?
        let result: Int32
        if let clip {
            guard let region = Flat(clip.figures) else { return nil }
            result = shape.xy.withUnsafeBufferPointer { points in
                shape.counts.withUnsafeBufferPointer { sizes in
                    region.xy.withUnsafeBufferPointer { clipPoints in
                        region.counts.withUnsafeBufferPointer { clipSizes in
                            cd2d_shape_create_clipped(
                                canvas, points.baseAddress, sizes.baseAddress, UInt32(sizes.count),
                                clipPoints.baseAddress, clipSizes.baseAddress, UInt32(clipSizes.count),
                                clip.evenOdd ? 1 : 0, &created,
                            )
                        }
                    }
                }
            }
        } else {
            result = shape.xy.withUnsafeBufferPointer { points in
                shape.counts.withUnsafeBufferPointer { sizes in
                    cd2d_shape_create(canvas, points.baseAddress, sizes.baseAddress, UInt32(sizes.count), &created)
                }
            }
        }
        return result == 0 ? created : nil
    }

    /// Figures of three points or more, flattened for the shim: every point x then y, and each figure's count.
    private struct Flat {
        let xy: [Float]
        let counts: [UInt32]

        init?(_ figures: [[PagePointMM]]) {
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
            self.xy = xy
            counts = drawn.map { UInt32($0.count) }
        }
    }
}
