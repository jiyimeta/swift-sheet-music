#if canImport(CoreGraphics)
    import CoreGraphics
#endif

public struct LayoutMeasure: Sendable, Equatable {
    /// 0-based score-wide measure index. Identifies which measure of
    /// `score.allStaves[*].staff.measures` this layout entry corresponds to,
    /// independent of the system that wrapping placed it in.
    public let measureIndex: Int
    /// Measure-local origin within its `LayoutSystem`.
    public let origin: CGPoint
    /// Width of the measure (including barline space).
    public let width: CGFloat
    /// Per-staff elements (aggregated). Origins inside `elements` are
    /// relative to the measure origin.
    public let elements: [LayoutElement]
    /// Top-left markers (segno, coda, fine, toCoda).
    public let markers: [LayoutElement]
    /// Bottom-right jumps (D.C., D.S.).
    public let jumps: [LayoutElement]
    /// `<LayoutBreak>line` on the source `Measure`. Render-time
    /// indicators (UI) consult this; layout has already applied
    /// the break by ending the system at this measure.
    public let lineBreak: Bool
    /// `<LayoutBreak>page` on the source `Measure`. The exporter's
    /// pagination uses this to force a page boundary; UI indicator
    /// overlay also consults it.
    public let pageBreak: Bool
    /// Cross-staff aggregated tick → measure-local X map produced by
    /// `LayoutEngine.tickColumns` during placement. Spanner anchoring
    /// consults this to position partial-measure spanners (an 8va
    /// covering only the last chord, a slur starting mid-measure, …)
    /// at the actual chord X rather than the measure's left edge.
    /// Empty for measures with no timed content.
    public let tickColumns: [Int: CGFloat]
    /// When non-nil, this layout measure renders as a multi-measure-rest
    /// H-bar covering `multiMeasureRest!` source measures. The
    /// `elements` array carries the H-bar `LayoutElement` plus the
    /// trailing barline; no chord/rest elements are emitted. Nil for
    /// every normal measure.
    public let multiMeasureRest: Int?
    /// Elements whose source is hidden (`visible == false`) but emitted
    /// anyway because `showsInvisibleElements` is on. Renderers draw these
    /// at 50 % opacity (MuseScore `#808080` on white). Empty in print
    /// layout. Origins follow the same convention as `elements`.
    public let invisibleElements: [LayoutElement]
    /// Per-tick minimum (highest) Y of chord noteheads in this measure,
    /// aggregated across all staves and voices. Y values are system-level
    /// (Y-down): smaller = higher on screen. Populated by `buildSystem`
    /// from the placed chord elements so vibrato autoplace can push the
    /// spanner above high notes. Empty for multi-measure-rest measures
    /// and measures with no timed chords.
    public let chordNorthByTick: [Int: CGFloat]
    /// Horizontal ink extent of every dynamic placed in this measure,
    /// tagged with the staff it belongs to and the tick it is anchored
    /// at. Populated by `buildSystem` while the per-staff element
    /// buffers are still separate — that is the only point where both
    /// facts are known, since `elements` aggregates every staff and a
    /// `LayoutElement` carries no tick.
    ///
    /// Consumed by `LayoutEngine.attachSpanners` to reserve room
    /// between a hairpin and the dynamic at its own start / end tick
    /// (MuseScore `TLayout::manageHairpinSnapping`). Empty when the
    /// measure has no dynamics.
    public let dynamicExtents: [DynamicExtent]

    /// One dynamic's horizontal ink span, in measure-local X.
    public struct DynamicExtent: Sendable, Equatable {
        /// Index into `LayoutSystem.staffOrigins`.
        public let staffIndex: Int
        /// Tick within the measure the dynamic is anchored at.
        public let tick: Int
        public let minX: CGFloat
        public let maxX: CGFloat

        public init(
            staffIndex: Int, tick: Int, minX: CGFloat, maxX: CGFloat,
        ) {
            self.staffIndex = staffIndex
            self.tick = tick
            self.minX = minX
            self.maxX = maxX
        }
    }

    public init(
        measureIndex: Int,
        origin: CGPoint,
        width: CGFloat,
        elements: [LayoutElement],
        markers: [LayoutElement] = [],
        jumps: [LayoutElement] = [],
        lineBreak: Bool = false,
        pageBreak: Bool = false,
        tickColumns: [Int: CGFloat] = [:],
        multiMeasureRest: Int? = nil,
        invisibleElements: [LayoutElement] = [],
        chordNorthByTick: [Int: CGFloat] = [:],
        dynamicExtents: [DynamicExtent] = [],
    ) {
        self.measureIndex = measureIndex
        self.origin = origin
        self.width = width
        self.elements = elements
        self.markers = markers
        self.jumps = jumps
        self.lineBreak = lineBreak
        self.pageBreak = pageBreak
        self.tickColumns = tickColumns
        self.multiMeasureRest = multiMeasureRest
        self.invisibleElements = invisibleElements
        self.chordNorthByTick = chordNorthByTick
        self.dynamicExtents = dynamicExtents
    }

    /// Whether `other` would draw identically to this measure once
    /// translated to its own `origin.x`.
    ///
    /// Compares everything a renderer reads except the horizontal
    /// origin: a measure that only slid sideways (because an earlier
    /// measure changed width) can have its layer container repositioned
    /// instead of rebuilt. `origin.y` IS compared — it participates in
    /// the per-element Y flip.
    ///
    /// Cost is O(1) when the two values share array storage (the common
    /// case when the layout cache carried a measure forward) and O(content)
    /// otherwise. Correct either way.
    public func hasSameRenderContent(as other: LayoutMeasure) -> Bool {
        measureIndex == other.measureIndex
            && origin.y == other.origin.y
            && width == other.width
            && multiMeasureRest == other.multiMeasureRest
            && elements == other.elements
            && markers == other.markers
            && jumps == other.jumps
            && invisibleElements == other.invisibleElements
    }
}
