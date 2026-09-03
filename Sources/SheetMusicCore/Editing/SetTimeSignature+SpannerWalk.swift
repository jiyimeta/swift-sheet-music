import SheetMusicFoundation

/// Where a re-bar FINDS the spanners it has to restate, and how it writes an endpoint back to one.
///
/// Split out of `SetTimeSignature+Spanners.swift`, which owns the endpoint math, when this half had to learn a
/// second anchor SHAPE and the two together no longer fit one file.
///
/// ## Two shapes, one address
///
/// A spanner's begin side reaches the model two ways (`SpannerPlacement`):
///
/// - as a **`.spanner` voice element** — hairpins, voltas, pedals, ottavas, everything MuseScore writes as its
///   own `<Spanner>` in the measure;
/// - inside **`Chord.spanners`** — a slur, which MuseScore writes inside the `<Chord>` it starts on.
///
/// Both carry the same `nextMeasuresOffset` / `nextFractionsOffset`, both measure it from the same anchor, and a
/// re-bar therefore moves both by the same rule. This walk saw only the first for as long as slurs were
/// read-only, so a chord-anchored slur came out of `.setTimeSignature` still counting bars of the OLD barring.
/// `MeasureStructure.adjustSpannerOffsets` learned both shapes for `InsertMeasure` / `DeleteMeasure`; this is the
/// same lesson on the re-bar path, and `FoundSpanner.spannerIndex` is `MeasureStructure.SpannerAddress`'s slot
/// under another name — a `VoiceElementID` alone cannot say WHICH of a chord's slurs is meant.
extension TimeSignatureRegion {
    // MARK: - Reading and writing one spanner, whichever shape it takes

    /// The spanner `slot` names inside `element`: the element itself when `slot` is `nil`, otherwise that entry
    /// of `Chord.spanners`. `nil` when the address no longer holds one — a re-bar rewrites voices wholesale, so
    /// an address captured before it can name something else afterwards.
    static func spanner(at slot: Int?, in element: VoiceElement) -> Spanner? {
        switch element {
        case let .spanner(spanner):
            slot == nil ? spanner : nil
        case let .chord(chord):
            slot.flatMap { chord.spanners.indices.contains($0) ? chord.spanners[$0] : nil }
        default:
            nil
        }
    }

    /// Writes an endpoint onto the spanner `slot` names, leaving `element` untouched when it holds no such
    /// spanner.
    static func setOffsets(
        _ endpoint: (offset: Int, fraction: Fraction?), at slot: Int?, in element: inout VoiceElement,
    ) {
        switch element {
        case var .spanner(spanner) where slot == nil:
            spanner.nextMeasuresOffset = endpoint.offset
            spanner.nextFractionsOffset = endpoint.fraction
            element = .spanner(spanner)
        case var .chord(chord):
            guard let slot, chord.spanners.indices.contains(slot) else { return }
            chord.spanners[slot].nextMeasuresOffset = endpoint.offset
            chord.spanners[slot].nextFractionsOffset = endpoint.fraction
            element = .chord(chord)
        default:
            return
        }
    }

    /// Writes each restated endpoint onto the spanner it names, skipping any address that no longer holds one.
    static func writeEndpoints(_ endpoints: [SpannerEndpoint], into score: inout Score) {
        for entry in endpoints {
            guard var element = score[entry.id] else { continue }
            setOffsets(
                (entry.measuresOffset, entry.fractionsOffset), at: entry.spannerIndex, in: &element,
            )
            score[entry.id] = element
        }
    }

    /// The endpoints the addresses in `endpoints` carry in `score` RIGHT NOW — the pre-image a restore's own
    /// inverse needs. Every such address is anchored before the region, so it names the same slot in either
    /// barring.
    static func currentEndpoints(for endpoints: [SpannerEndpoint], in score: Score) -> [SpannerEndpoint] {
        endpoints.map { entry in
            guard let element = score[entry.id],
                  let spanner = spanner(at: entry.spannerIndex, in: element)
            else { return entry }
            return SpannerEndpoint(
                id: entry.id,
                spannerIndex: entry.spannerIndex,
                measuresOffset: spanner.nextMeasuresOffset,
                fractionsOffset: spanner.nextFractionsOffset,
            )
        }
    }

    /// The inside-anchored counterpart of `writeEndpoints`: the same write, addressed into a rebuilt column that
    /// has not been spliced into a score yet.
    static func write(
        _ endpoint: (offset: Int, fraction: Fraction?), into column: inout MeasureSlice, at found: FoundSpanner,
    ) {
        guard column.staffMeasures.indices.contains(found.partIndex),
              column.staffMeasures[found.partIndex].indices.contains(found.staffIndex)
        else { return }
        var measure = column.staffMeasures[found.partIndex][found.staffIndex]
        guard measure.voices.indices.contains(found.voiceIndex),
              measure.voices[found.voiceIndex].elements.indices.contains(found.elementIndex)
        else { return }
        setOffsets(
            endpoint, at: found.spannerIndex,
            in: &measure.voices[found.voiceIndex].elements[found.elementIndex],
        )
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
        /// The index into `Chord.spanners`, or `nil` when the element at `elementIndex` IS the spanner.
        var spannerIndex: Int?
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

    static func spanners(inRegion region: Range<Int>, of score: Score) -> [FoundSpanner] {
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

    static func spanners(inColumns columns: [MeasureSlice]) -> [FoundSpanner] {
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

    /// Every spanner one measure carries, in element order, with a chord's own entries in `Chord.spanners` order.
    ///
    /// That order is what makes the inside-region match work: `RebarPlanner` re-emits a voice's elements in tick
    /// order and only the HEAD of a split chord keeps its `spanners` (`RebarPlanner.pieces` rebuilds the head
    /// from the source chord; `DurationChangeAlgorithm.makeChordChain` builds every other piece from scratch), so
    /// the k-th entry of a voice before the re-bar is still the k-th after it.
    private static func spanners(
        in measure: Measure, partIndex: Int, staffIndex: Int, measureIndex: Int,
    ) -> [FoundSpanner] {
        var result: [FoundSpanner] = []
        for voiceIndex in measure.voices.indices {
            let elements = measure.voices[voiceIndex].elements
            for elementIndex in elements.indices {
                func found(slot: Int?, _ spanner: Spanner) -> FoundSpanner {
                    FoundSpanner(
                        partIndex: partIndex, staffIndex: staffIndex, voiceIndex: voiceIndex,
                        elementIndex: elementIndex, spannerIndex: slot, measureIndex: measureIndex,
                        offset: spanner.nextMeasuresOffset, fraction: spanner.nextFractionsOffset,
                    )
                }
                switch elements[elementIndex] {
                case let .spanner(spanner):
                    result.append(found(slot: nil, spanner))
                case let .chord(chord):
                    result.append(contentsOf: chord.spanners.indices.map { found(slot: $0, chord.spanners[$0]) })
                default:
                    continue
                }
            }
        }
        return result
    }
}
