// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Active engraving state at the start of a measure: which clef, key
/// signature and time signature are in force, plus the part labels
/// for each staff.
///
/// Used by horizontal continuous-view UIs to render a "sticky" header
/// pinned at the viewport's left edge that re-displays these symbols
/// regardless of scroll position — mirroring MuseScore's continuous
/// view, where the leftmost column always shows the active clef,
/// key, time, instrument name and current measure number.
public struct LayoutMeasureContext: Sendable, Equatable {
    public let measureIndex: Int
    public let clefRawTypes: [String]
    public let keySignatures: [Int]
    public let timeSignature: TimeSignaturePair?
    public let partLabels: [String]
    /// 1-based displayed number for this measure, with irregular
    /// measures excluded from the running count. `nil` when this
    /// measure is irregular and no number should be drawn (anacrusis
    /// convention). Mirrors `Score.displayedMeasureNumber(at:)`.
    public let displayedMeasureNumber: Int?

    public struct TimeSignaturePair: Sendable, Equatable {
        public let numerator: Int
        public let denominator: Int
        public init(numerator: Int, denominator: Int) {
            self.numerator = numerator
            self.denominator = denominator
        }
    }

    public init(
        measureIndex: Int,
        clefRawTypes: [String],
        keySignatures: [Int],
        timeSignature: TimeSignaturePair?,
        partLabels: [String],
        displayedMeasureNumber: Int? = nil,
    ) {
        self.measureIndex = measureIndex
        self.clefRawTypes = clefRawTypes
        self.keySignatures = keySignatures
        self.timeSignature = timeSignature
        self.partLabels = partLabels
        self.displayedMeasureNumber = displayedMeasureNumber
    }
}

extension LayoutEngine {
    /// One `LayoutMeasureContext` per measure of `score`. State is
    /// captured AFTER processing each measure's leading elements, so
    /// a sticky header reading `contexts[N]` sees the clef / key /
    /// time signature that's in force for the BODY of measure N —
    /// including any change measure N itself declared.
    ///
    /// This matches what a horizontal continuous-view UI wants: as
    /// soon as the reader's eyes are inside measure 1 at scroll
    /// position 0, the sticky should already reflect measure 1's
    /// time signature so it stays visible after scrolling past it.
    public static func measureContexts(
        for score: Score,
    ) -> [LayoutMeasureContext] {
        let allStaves = score.allStaves
        var clefs = defaultClefRawTypes(addresses: allStaves)
        var keys = Array(repeating: 0, count: allStaves.count)
        var timeSig: LayoutMeasureContext.TimeSignaturePair?
        // Fix: resolve part labels via address.partIndex so multi-staff
        // parts (e.g. Piano grand staff) map both staves to the same part
        // name instead of using the flat staff index as the part index.
        let partLabels = allStaves.map { entry -> String in
            let part = score.parts[entry.address.partIndex]
            return part.instrument.longName
                ?? part.trackName
                ?? ""
        }
        let measureCount = allStaves.first?.staff.measures.count ?? 0
        var contexts: [LayoutMeasureContext] = []
        contexts.reserveCapacity(measureCount)
        for measureIdx in 0 ..< measureCount {
            for (staffIdx, entry) in allStaves.enumerated() {
                let staff = entry.staff
                guard measureIdx < staff.measures.count else { continue }
                let measure = staff.measures[measureIdx]
                scan: for el in measure.voices.first?.elements ?? [] {
                    switch el {
                    case let .clef(c):
                        if staffIdx < clefs.count {
                            clefs[staffIdx] = c.concertClefType
                        }
                    case let .keySignature(k):
                        if staffIdx < keys.count {
                            keys[staffIdx] = k.concertKey
                        }
                    case let .timeSignature(t):
                        timeSig = .init(
                            numerator: t.numerator,
                            denominator: t.denominator,
                        )
                    case .chord:
                        break scan
                    default:
                        continue
                    }
                }
            }
            contexts.append(LayoutMeasureContext(
                measureIndex: measureIdx,
                clefRawTypes: clefs,
                keySignatures: keys,
                timeSignature: timeSig,
                partLabels: partLabels,
                displayedMeasureNumber: score.displayedMeasureNumber(
                    at: measureIdx,
                ),
            ))
        }
        return contexts
    }
}

extension LayoutDocument {
    /// Index of the `LayoutMeasure` intersecting `documentX` in the
    /// FIRST system. Returns nil if `documentX` falls outside any
    /// measure (e.g. left of the first measure or right of the last).
    /// Horizontal continuous-view UIs use this to find which measure
    /// drives the sticky header at the current scroll offset.
    public func measureIndex(atDocumentX x: CGFloat) -> Int? {
        guard let system = systems.first else { return nil }
        let local = x - system.origin.x
        for measure in system.measures {
            if measure.origin.x <= local
                && measure.origin.x + measure.width > local
            {
                return measure.measureIndex
            }
        }
        return nil
    }

    /// Score-coord X corresponding to the TRAILING edge of the
    /// sticky pane when the visible left edge of the score is at
    /// `scoreScrollX`. Used by horizontal continuous-view UIs to
    /// drive the sticky's measure-number lookup: passing this to
    /// `measureIndex(atDocumentX:)` flips the displayed measure
    /// the moment the next measure's leading barline crosses the
    /// pane's trailing edge — exactly when that next measure
    /// becomes the leftmost visible content past the sticky.
    ///
    /// The pane's width depends on the measure being shown (key
    /// signature width varies, etc.), so we look the measure up
    /// from `scoreScrollX` first, build the matching synthetic
    /// system, and use ITS width. For typical pieces without
    /// key / time changes between adjacent measures this is exact;
    /// at a key change the answer is off by at most one measure
    /// boundary.
    public func stickyTrailingX(
        scoreScrollX: CGFloat,
        measureContexts: [LayoutMeasureContext],
    ) -> CGFloat {
        guard let template = systems.first,
              !measureContexts.isEmpty
        else { return scoreScrollX }
        let bracketLocalX = (template.staffOrigins.first?.x ?? 0)
            - metrics.sp / 2
        let initialIdx = measureIndex(atDocumentX: scoreScrollX) ?? 0
        let safeIdx = min(
            max(0, initialIdx), measureContexts.count - 1,
        )
        let synth = LayoutEngine.stickyHeaderSystem(
            for: measureContexts[safeIdx],
            templateSystem: template,
            metrics: metrics,
        )
        // The pane visually covers viewport [0, (synth.W -
        // bracketLocalX) * mag], so the trailing edge in score
        // coord is offset from the visible scroll position by the
        // same `synth.W - bracketLocalX`.
        return scoreScrollX + synth.size.width - bracketLocalX
    }
}

extension LayoutEngine {
    /// Build a synthetic single-measure `LayoutSystem` containing only
    /// the elements a sticky header needs: per-staff clef + key sig +
    /// time sig, part labels, and a measure-number marker. Reuses the
    /// `templateSystem`'s `staffOrigins` so the synthetic header
    /// aligns vertically with the main score.
    ///
    /// The returned system can be fed straight into `SystemLayerView`
    /// or `SystemCanvas`, so the sticky header inherits all rendering
    /// fidelity (Bravura glyphs, sharps/flats spacing, staff-line
    /// thickness) for free.
    public static func stickyHeaderSystem( // swiftlint:disable:this function_body_length
        for context: LayoutMeasureContext,
        templateSystem: LayoutSystem,
        metrics: StaffMetrics,
    ) -> LayoutSystem {
        let staffOrigins = templateSystem.staffOrigins
        // Staff lines start at `staffOrigins[*].x` (= the part-label
        // gutter width chosen by `buildSystem`). Mirror the inset
        // `computeHeaderSchedule` uses so the clef sits at the same
        // x relative to the staff start as it would in any first
        // measure of a system.
        let staffStartX = staffOrigins.first?.x ?? metrics.sp * 8
        let clefX = staffStartX + metrics.sp * 2
        // Reserved width past the clef center, sized to clef
        // glyph half-width (Bravura gClef bbox ≈ sp * 2 wide,
        // half ≈ sp * 1) + MuseScore's `keysigLeftMargin` (0.5 sp,
        // styledef.cpp). Lands the keysig at sp * 4 from staff
        // start — matches MuseScore's
        // `clefLeftMargin + widthClef + keysigLeftMargin` ≈ sp * 3.85.
        let clefW = metrics.sp * 2
        let keySigX = clefX + clefW
        // Staff name and measure-number labels live at the clef
        // right edge — i.e. `keysigLeftMargin` (0.5 sp) LEFT of
        // the keysig. Matches MuseScore's `clefLeftMargin +
        // widthClef` (continuouspanel.cpp:463 / 424).
        let labelX = keySigX - metrics.sp * 0.5
        // Width of the key-signature column = 0 if all staves are in
        // C major, else max(|key| + 1.5 sp) across staves so accident
        // rows fit.
        let keyAbs = context.keySignatures.map { abs($0) }.max() ?? 0
        let keySigW = keyAbs > 0
            ? metrics.sp * (CGFloat(keyAbs) + 1.5)
            : 0
        let timeSigX = keySigX + keySigW
        let timeSigW: CGFloat = context.timeSignature != nil
            ? metrics.sp * 3
            : 0
        // No trailing padding — the pane ends flush with the time
        // signature's right edge so score content reappears
        // immediately past it.
        let contentEndX = timeSigX + timeSigW
        let headerW = max(contentEndX, staffStartX + metrics.sp * 6)

        var elements: [LayoutElement] = []
        for (staffIdx, origin) in staffOrigins.enumerated() {
            // `metrics.staffHeight` is the five-line REFERENCE height
            // that step→Y placement is expressed in, exactly as in
            // `placeMeasureElements`, so it stays put for every line
            // count. Only the two glyphs MuseScore centers on the
            // staff's own height — the percussion clefs and the time
            // signature — take `centerOffsetSp` on top of it.
            let staffMidY = origin.y + metrics.staffHeight / 2
            let geometry = templateSystem.geometry(atFlatIndex: staffIdx)
            if staffIdx < context.clefRawTypes.count {
                let rawType = context.clefRawTypes[staffIdx]
                let clefDy = metrics.sp * ClefGlyph.staffCenteringOffsetSp(
                    for: NotatedClef(rawType: rawType),
                    lineGeometry: geometry,
                )
                elements.append(.clef(
                    rawType: rawType,
                    origin: CGPoint(x: clefX, y: staffMidY + clefDy),
                    anchor: nil,
                ))
            }
            if staffIdx < context.keySignatures.count, keyAbs > 0 {
                let key = context.keySignatures[staffIdx]
                elements.append(.keySignature(
                    sharps: max(0, key),
                    flats: max(0, -key),
                    origin: CGPoint(x: keySigX, y: staffMidY),
                ))
            }
            if let ts = context.timeSignature {
                elements.append(.timeSignature(
                    numerator: ts.numerator,
                    denominator: ts.denominator,
                    origin: CGPoint(
                        x: timeSigX,
                        y: staffMidY + metrics.sp * geometry.centerOffsetSp,
                    ),
                ))
            }
            // Staff name above the staff, left-aligned at `labelX`
            // (= clef-right-edge), mirroring MuseScore's continuous-
            // panel placement at `clefLeftMargin + widthClef`
            // (continuouspanel.cpp:463) — sits 0.5 sp LEFT of the
            // keysig, separated by `keysigLeftMargin`. Bottom-
            // leading anchor; if the name is wider than the pane,
            // the rendered text overflows the white box to the
            // right without forcing the panel to widen.
            if staffIdx < context.partLabels.count {
                let name = context.partLabels[staffIdx]
                if !name.isEmpty {
                    elements.append(.staffName(
                        text: name,
                        origin: CGPoint(
                            x: labelX,
                            y: origin.y - metrics.sp * 0.5,
                        ),
                    ))
                }
            }
        }
        var markers: [LayoutElement] = []
        if let topStaffOrigin = staffOrigins.first,
           let displayed = context.displayedMeasureNumber
        {
            // Sticky measure number, MuseScore-style:
            //   - "#N" prefix (continuouspanel.cpp:420 emits
            //     `String(u"#%1").arg(currentMeasure->measureNumber()
            //     + 1)`).
            //   - X = `labelX` (= clef-right-edge), same column as
            //     the staff name.
            //   - Y = `sp * 2.5` above the staff so the digits sit
            //     above the staff name.
            //   - Irregular measures (anacrusis) get no label, matching
            //     MuseScore's measure-numbering rule.
            markers.append(.measureNumber(
                text: "#\(displayed)",
                origin: CGPoint(
                    x: labelX,
                    y: topStaffOrigin.y - metrics.sp * 2.5,
                ),
            ))
        }
        let measure = LayoutMeasure(
            measureIndex: context.measureIndex,
            origin: CGPoint(x: 0, y: 0),
            width: headerW,
            elements: elements,
            markers: markers,
            jumps: [],
        )
        return LayoutSystem(
            origin: .zero,
            size: CGSize(
                width: headerW,
                height: templateSystem.size.height,
            ),
            measures: [measure],
            staffOrigins: staffOrigins,
            // Same staves as the template, so the geometries stay
            // parallel to the origins borrowed from it.
            staffGeometries: templateSystem.staffGeometries,
            // No left-side part labels: the sticky's instrument
            // names live ABOVE the staff (`.staffName` elements
            // above), where they don't compete with the measure
            // number for the gutter or push the pane wider when
            // the text is long.
            partLabels: [],
            spanners: [],
            sp: metrics.sp,
        )
    }
}
