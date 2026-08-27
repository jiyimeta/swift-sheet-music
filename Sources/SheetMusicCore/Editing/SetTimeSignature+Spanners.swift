import SheetMusicFoundation

/// What a re-bar does to a spanner's ENDPOINT.
///
/// A spanner does not store where it ends; it stores how far away the end is — `nextMeasuresOffset` bars from the
/// bar it is anchored in, then `nextFractionsOffset` into that bar (`HairpinRamps.computeEndTick` and
/// `LayoutEngine.endAnchor` both resolve it that way, and `MSCXEncoder` writes it back out that way). Both halves
/// are measured in the OLD barring, so re-partitioning the bars underneath them silently moves the endpoint —
/// a hairpin that stops two bars early, or a volta whose repeat ending covers the wrong bars and changes what
/// playback actually plays.
///
/// So the endpoint is re-derived from the one thing a re-bar preserves: the ABSOLUTE TICK it falls on. Resolve
/// the old pair to a tick, find the bar the new barring puts that tick in, and read both halves back off it.
///
/// ## One derivation, two anchor classes
///
/// `remapped(_:oldAnchor:newAnchor:geometry:)` is the whole of the math and both classes go through it; they
/// differ only in where the answer is written and in what the anchor's bar becomes.
///
/// - **Anchored BEFORE the region.** The anchor bar is untouched, so its address survives the splice: the new
///   values are collected and written afterwards, and the pre-image goes in the inverse.
/// - **Anchored INSIDE the region.** `RebarPlanner` has already carried the element into whichever new column
///   holds its tick, so the new values are written straight into those columns before they are spliced — and
///   the inverse needs nothing extra, because the column pre-image already restores them verbatim.
///
/// An inside-anchored spanner's new bar is read off its position in `columns` rather than re-derived from a
/// tick: the planner emits a voice's untimed elements in tick order, so the k-th spanner of a given
/// part/staff/voice in the region is the k-th one in the rebuilt columns. Counts that fail to line up are left
/// alone rather than guessed at.
extension TimeSignatureRegion {
    /// A spanner's address paired with the endpoint it declares — the pre-image a restore puts back, and the
    /// restated value a re-bar writes.
    struct SpannerEndpoint: Sendable, Equatable {
        var id: VoiceElementID
        var measuresOffset: Int
        var fractionsOffset: Fraction?
    }

    /// Where every bar of the score starts, before the splice and after it — the tick tables the endpoint math is
    /// done against.
    struct BarGeometry {
        let division: Int
        let oldStarts: [Int]
        let newStarts: [Int]

        /// The bars after the region keep their durations: the region stops AT the next bar that declares its own
        /// meter, so nothing past it inherits anything new.
        init(score: Score, region: Range<Int>, columns: [MeasureSlice], signature: TimeSignature) {
            division = score.division
            let old = score.effectiveMeasureDurations()
            let nominal = Fraction(numerator: signature.numerator, denominator: signature.denominator)
            var new = Array(old.prefix(region.lowerBound))
            new.append(contentsOf: columns.map {
                $0.staffMeasures.first?.first?.actualLength ?? nominal
            })
            if region.upperBound < old.count {
                new.append(contentsOf: old[region.upperBound...])
            }
            oldStarts = Self.startTicks(old, division: division)
            newStarts = Self.startTicks(new, division: division)
        }

        /// The absolute tick a spanner anchored in `anchorBar` and declaring these offsets ends on — the start of
        /// bar `anchorBar + offset`, plus the fraction into it.
        ///
        /// `nil` when that bar is past the end of the score. Such an endpoint is already out of range and every
        /// consumer clamps it (`HairpinRamps` with `min(measures.count - 1, …)`, `LayoutEngine.endAnchor` with a
        /// bounded walk); re-spelling it here would turn a clamp into a committed value.
        func endTick(anchorBar: Int, offset: Int, fraction: Fraction?) -> Int? {
            let endBar = anchorBar + offset
            guard oldStarts.indices.contains(endBar) else { return nil }
            return oldStarts[endBar] + (fraction?.ticks(division: division) ?? 0)
        }

        /// The bar of the NEW barring holding `tick` — the last one starting at or before it.
        func newBar(containing tick: Int) -> Int {
            var result = 0
            for (index, start) in newStarts.enumerated() where start <= tick {
                result = index
            }
            return result
        }

        /// Ticks as the fraction-of-a-whole-note every position field in the model is written in, matching
        /// `RebarPlanner.Geometry.fraction(ofTicks:)`.
        func fraction(ofTicks ticks: Int) -> Fraction {
            Fraction(numerator: ticks, denominator: 4 * division)
        }

        private static func startTicks(_ durations: [Fraction], division: Int) -> [Int] {
            var starts: [Int] = []
            var total = 0
            for duration in durations {
                starts.append(total)
                total += duration.ticks(division: division)
            }
            return starts
        }
    }

    /// The `(measures, fractions)` pair naming the same absolute moment under the new barring, or `nil` when
    /// there is nothing to restate.
    ///
    /// `nil` for a spanner declaring NEITHER offset. `MSCXEncoder` writes `<measures>` only when it is non-zero
    /// and `<fractions>` only when it is present, so "0 and absent" is not an endpoint at all — it is a spanner
    /// that ends inside its own bar, which stays true however that bar is re-cut. Deriving it from a tick would
    /// resolve it to the start of the anchor's OLD bar and hand back a backwards offset the moment the anchor
    /// sits past a new barline.
    ///
    /// `nil` too when the derivation lands on the values already there, so an untouched spanner is left byte-
    /// identical rather than rewritten to itself.
    static func remapped(
        _ endpoint: (offset: Int, fraction: Fraction?),
        oldAnchor: Int, newAnchor: Int, geometry: BarGeometry,
    ) -> (offset: Int, fraction: Fraction?)? {
        guard endpoint.offset != 0 || endpoint.fraction != nil else { return nil }
        guard let tick = geometry.endTick(
            anchorBar: oldAnchor, offset: endpoint.offset, fraction: endpoint.fraction,
        ) else { return nil }
        let bar = geometry.newBar(containing: tick)
        let remainder = tick - geometry.newStarts[bar]
        let fraction = remainder == 0 ? nil : geometry.fraction(ofTicks: remainder)
        let offset = bar - newAnchor
        guard offset != endpoint.offset || fraction != endpoint.fraction else { return nil }
        return (offset, fraction)
    }

    /// Restates every spanner endpoint the new barring moved: the inside-anchored ones straight into `columns`,
    /// and the outside-anchored ones as `(previous, restated)` pairs for the caller to write after the splice and
    /// to carry in the inverse.
    static func restatingSpannerEndpoints(
        _ columns: inout [MeasureSlice], region: Range<Int>, signature: TimeSignature, in score: Score,
    ) -> [(previous: SpannerEndpoint, restated: SpannerEndpoint)] {
        let geometry = BarGeometry(score: score, region: region, columns: columns, signature: signature)
        restateInsideRegion(&columns, region: region, in: score, geometry: geometry)
        return restatedOutsideRegion(of: score, region: region, geometry: geometry)
    }

    // MARK: - Anchored before the region

    private static func restatedOutsideRegion(
        of score: Score, region: Range<Int>, geometry: BarGeometry,
    ) -> [(previous: SpannerEndpoint, restated: SpannerEndpoint)] {
        var result: [(previous: SpannerEndpoint, restated: SpannerEndpoint)] = []
        for found in spanners(inRegion: 0 ..< region.lowerBound, of: score) {
            guard let restated = remapped(
                (found.offset, found.fraction),
                oldAnchor: found.measureIndex, newAnchor: found.measureIndex, geometry: geometry,
            ) else { continue }
            let id = VoiceElementID(
                staff: StaffAddress(partIndex: found.partIndex, staffIndexInPart: found.staffIndex),
                measureIndex: found.measureIndex, voiceIndex: found.voiceIndex,
                elementIndex: found.elementIndex,
            )
            result.append((
                previous: SpannerEndpoint(
                    id: id, measuresOffset: found.offset, fractionsOffset: found.fraction,
                ),
                restated: SpannerEndpoint(
                    id: id, measuresOffset: restated.offset, fractionsOffset: restated.fraction,
                ),
            ))
        }
        return result
    }

    /// Writes each restated endpoint onto the spanner it names, skipping any address that no longer holds one.
    static func writeEndpoints(_ endpoints: [SpannerEndpoint], into score: inout Score) {
        for entry in endpoints {
            guard case var .spanner(spanner) = score[entry.id] else { continue }
            spanner.nextMeasuresOffset = entry.measuresOffset
            spanner.nextFractionsOffset = entry.fractionsOffset
            score[entry.id] = .spanner(spanner)
        }
    }

    /// The endpoints the addresses in `endpoints` carry in `score` RIGHT NOW — the pre-image a restore's own
    /// inverse needs. Every such address is anchored before the region, so it names the same slot in either
    /// barring.
    static func currentEndpoints(for endpoints: [SpannerEndpoint], in score: Score) -> [SpannerEndpoint] {
        endpoints.map { entry in
            guard case let .spanner(spanner) = score[entry.id] else { return entry }
            return SpannerEndpoint(
                id: entry.id,
                measuresOffset: spanner.nextMeasuresOffset,
                fractionsOffset: spanner.nextFractionsOffset,
            )
        }
    }

    // MARK: - Anchored inside the region

    private static func restateInsideRegion(
        _ columns: inout [MeasureSlice], region: Range<Int>, in score: Score, geometry: BarGeometry,
    ) {
        let before = Dictionary(grouping: spanners(inRegion: region, of: score), by: \.voiceKey)
        guard !before.isEmpty else { return }
        let after = Dictionary(grouping: spanners(inColumns: columns), by: \.voiceKey)
        for (key, sources) in before {
            guard let targets = after[key], targets.count == sources.count else { continue }
            for (source, target) in zip(sources, targets) {
                guard let restated = remapped(
                    (source.offset, source.fraction),
                    oldAnchor: source.measureIndex,
                    newAnchor: region.lowerBound + target.measureIndex,
                    geometry: geometry,
                ) else { continue }
                write(restated, into: &columns[target.measureIndex], at: target)
            }
        }
    }

    private static func write(
        _ endpoint: (offset: Int, fraction: Fraction?), into column: inout MeasureSlice, at found: FoundSpanner,
    ) {
        guard column.staffMeasures.indices.contains(found.partIndex),
              column.staffMeasures[found.partIndex].indices.contains(found.staffIndex)
        else { return }
        var measure = column.staffMeasures[found.partIndex][found.staffIndex]
        guard measure.voices.indices.contains(found.voiceIndex),
              measure.voices[found.voiceIndex].elements.indices.contains(found.elementIndex),
              case var .spanner(spanner) = measure.voices[found.voiceIndex].elements[found.elementIndex]
        else { return }
        spanner.nextMeasuresOffset = endpoint.offset
        spanner.nextFractionsOffset = endpoint.fraction
        measure.voices[found.voiceIndex].elements[found.elementIndex] = .spanner(spanner)
        column.staffMeasures[found.partIndex][found.staffIndex] = measure
    }

    // MARK: - Finding them

    /// One spanner and where it sits. `measureIndex` is an absolute bar index when the walk was over a score, and
    /// an index into `columns` when it was over the rebuilt region.
    struct FoundSpanner {
        var partIndex: Int
        var staffIndex: Int
        var voiceIndex: Int
        var elementIndex: Int
        var measureIndex: Int
        var offset: Int
        var fraction: Fraction?

        /// The voice a spanner belongs to, which is what the two walks are matched up within.
        var voiceKey: VoiceKey {
            VoiceKey(part: partIndex, staff: staffIndex, voice: voiceIndex)
        }
    }

    struct VoiceKey: Hashable {
        var part: Int
        var staff: Int
        var voice: Int
    }

    private static func spanners(inRegion region: Range<Int>, of score: Score) -> [FoundSpanner] {
        var result: [FoundSpanner] = []
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                let measures = score.parts[partIndex].staves[staffIndex].measures
                for measureIndex in measures.indices where region.contains(measureIndex) {
                    result.append(contentsOf: spanners(
                        in: measures[measureIndex], partIndex: partIndex, staffIndex: staffIndex,
                        measureIndex: measureIndex,
                    ))
                }
            }
        }
        return result
    }

    private static func spanners(inColumns columns: [MeasureSlice]) -> [FoundSpanner] {
        var result: [FoundSpanner] = []
        for (columnIndex, column) in columns.enumerated() {
            for partIndex in column.staffMeasures.indices {
                for staffIndex in column.staffMeasures[partIndex].indices {
                    result.append(contentsOf: spanners(
                        in: column.staffMeasures[partIndex][staffIndex],
                        partIndex: partIndex, staffIndex: staffIndex, measureIndex: columnIndex,
                    ))
                }
            }
        }
        // Column-major on purpose: grouped by voice afterwards, each key's entries then read in column order and
        // then element order — the same order the score-side walk produces in bar order.
        return result
    }

    private static func spanners(
        in measure: Measure, partIndex: Int, staffIndex: Int, measureIndex: Int,
    ) -> [FoundSpanner] {
        var result: [FoundSpanner] = []
        for voiceIndex in measure.voices.indices {
            let elements = measure.voices[voiceIndex].elements
            for elementIndex in elements.indices {
                guard case let .spanner(spanner) = elements[elementIndex] else { continue }
                result.append(FoundSpanner(
                    partIndex: partIndex, staffIndex: staffIndex, voiceIndex: voiceIndex,
                    elementIndex: elementIndex, measureIndex: measureIndex,
                    offset: spanner.nextMeasuresOffset, fraction: spanner.nextFractionsOffset,
                ))
            }
        }
        return result
    }
}
