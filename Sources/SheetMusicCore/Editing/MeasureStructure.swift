/// Shared mechanics for the measure-structure commands (`InsertMeasure` / `DeleteMeasure`).
enum MeasureStructure {
    /// One spanner's *begin* side, addressed precisely enough to write back to it. A `VoiceElementID` alone is
    /// not enough: a chord can carry several entries in `Chord.spanners` (an inner and an outer slur), of which
    /// only some may need adjusting, so the slot has to travel with the element address.
    struct SpannerAddress: Hashable, Sendable {
        /// The element carrying the spanner — a `.spanner` voice element, or the chord holding it.
        let id: VoiceElementID
        /// The index into `Chord.spanners`, or `nil` when `id` names the `.spanner` element itself.
        let spannerIndex: Int?
    }

    /// The signature kinds that belong to the score start and travel with it when bar 1 changes identity.
    static func isLeadingSignature(_ element: VoiceElement) -> Bool {
        switch element {
        case .keySignature, .timeSignature, .clef: true
        default: false
        }
    }

    /// The run of leading signature elements at the head of `voice`'s element list.
    static func leadingSignaturePrefix(of voice: Voice) -> IdentifiedArray<VoiceElement> {
        let count = voice.elements.prefix(while: isLeadingSignature).count
        return IdentifiedArray(voice.elements.identifiedPairs(in: 0 ..< count))
    }

    /// Builds bar 0's merged leading-signature run in MuseScore's structural order — clef, then key
    /// signature, then time signature — regardless of which bar contributed which kind
    /// (`src/engraving/dom/masterscore.cpp`: signatures live in typed segments whose tick-0 order is
    /// Clef → KeySig → TimeSig, so a merge can never reproduce insertion order). `incoming`'s own
    /// declaration of a kind always wins over `deleted`'s — a bar that already declares its own key/time/
    /// clef never inherits that kind from the deleted bar.
    static func mergedLeadingSignatures(
        inheritingFrom deleted: IdentifiedArray<VoiceElement>, into incoming: IdentifiedArray<VoiceElement>,
    ) -> IdentifiedArray<VoiceElement> {
        func resolve(_ matches: (VoiceElement) -> Bool) -> (EID, VoiceElement)? {
            if let index = incoming.firstIndex(where: matches) { return (incoming.eid(at: index), incoming[index]) }
            if let index = deleted.firstIndex(where: matches) { return (deleted.eid(at: index), deleted[index]) }
            return nil
        }
        return IdentifiedArray([
            resolve { if case .clef = $0 { true } else { false } },
            resolve { if case .keySignature = $0 { true } else { false } },
            resolve { if case .timeSignature = $0 { true } else { false } },
        ].compactMap(\.self))
    }

    /// Removes matching slots and retargets endpoints inward within their original member span.
    /// Literal input retains positional endpoints until its score adoption chokepoint.
    static func removeElements(
        in voice: inout Voice, where shouldRemove: (VoiceElement) -> Bool,
    ) {
        let removed = Set(voice.elements.indices.filter { shouldRemove(voice.elements[$0]) })
        voice.removeElements(at: removed)
    }

    static func measureCount(of score: Score) -> Int {
        score.parts.first?.staves.first?.measures.count ?? 0
    }

    static func blankColumn(for score: Score, ids: inout EIDAllocator) -> MeasureSlice {
        MeasureSlice(
            staffMeasures: score.parts.map { part in
                part.staves.map { _ in Measure(voices: [freshMeasureRest(using: &ids)]) }
            },
            systemMeasure: SystemMeasure(),
            systemMeasureEID: nil,
        )
    }

    /// A new rest built inside an executing apply; carried voices never go through a fill pass.
    static func freshMeasureRest(using ids: inout EIDAllocator) -> Voice {
        Voice(elements: IdentifiedArray([(ids.next(), VoiceElement.rest(duration: .measure))]))
    }

    /// Spanners store a relative forward measure distance; a structural change between a spanner's anchor and its
    /// end must stretch or shrink that distance.
    static func adjustSpannerOffsets(in score: inout Score, forInsertionAt index: Int) {
        adjustSpannerOffsets(in: &score) { address, offset in
            let anchor = address.id.measureIndex
            return anchor < index && index <= anchor + offset ? offset + 1 : offset
        }
    }

    /// Shrinks every spanner whose span crosses the deleted measure, and returns the addresses of the ones
    /// whose span *ended exactly at* the deleted measure (`index == anchorMeasure + offset`). Those need an
    /// exact re-increment — not the generic insertion predicate — when the deletion's inverse reinserts the
    /// column: `forInsertionAt` tests `index <= anchor + offset` against the already-shrunk offset, which
    /// no longer includes the boundary the shrink just excluded. See `DeleteMeasure.apply` / `InsertMeasure.apply`.
    @discardableResult
    static func adjustSpannerOffsets(in score: inout Score, forDeletionAt index: Int) -> [SpannerAddress] {
        var endpoints: [SpannerAddress] = []
        adjustSpannerOffsets(in: &score) { address, offset in
            let anchor = address.id.measureIndex
            guard anchor < index, index <= anchor + offset else { return offset }
            if index == anchor + offset {
                endpoints.append(address)
            }
            return offset - 1
        }
        return endpoints
    }

    private static func adjustSpannerOffsets(in score: inout Score, _ transform: (SpannerAddress, Int) -> Int) {
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                for measureIndex in score.parts[partIndex].staves[staffIndex].measures.indices {
                    for voiceIndex in score.parts[partIndex].staves[staffIndex].measures[measureIndex].voices.indices {
                        let elements = score.parts[partIndex].staves[staffIndex].measures[measureIndex]
                            .voices[voiceIndex].elements
                        for elementIndex in elements.indices {
                            let id = VoiceElementID(
                                staff: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex),
                                measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: elementIndex,
                            )
                            switch elements[elementIndex] {
                            case var .spanner(spanner):
                                spanner.nextMeasuresOffset = transform(
                                    SpannerAddress(id: id, spannerIndex: nil), spanner.nextMeasuresOffset,
                                )
                                score.parts.updateValue(at: partIndex) { partValue in
                                    partValue.staves.updateValue(at: staffIndex) { staffValue in
                                        staffValue.measures[measureIndex]
                                            .voices[voiceIndex].elements.updateValue(at: elementIndex) {
                                                $0 = .spanner(spanner)
                                            }
                                    }
                                }
                            case var .chord(chord) where !chord.spanners.isEmpty:
                                // A slur begin lives in `Chord.spanners`, not as a `.spanner` element, and its
                                // `nextMeasuresOffset` is measured from the SAME anchor — so it has to move by the
                                // same rule. This walk missed it until group 6 made slurs writable.
                                for slot in chord.spanners.indices {
                                    chord.spanners[slot].nextMeasuresOffset = transform(
                                        SpannerAddress(id: id, spannerIndex: slot),
                                        chord.spanners[slot].nextMeasuresOffset,
                                    )
                                }
                                score.parts.updateValue(at: partIndex) { partValue in
                                    partValue.staves.updateValue(at: staffIndex) { staffValue in
                                        staffValue.measures[measureIndex]
                                            .voices[voiceIndex].elements.updateValue(at: elementIndex) {
                                                $0 = .chord(chord)
                                            }
                                    }
                                }
                            default:
                                continue
                            }
                        }
                    }
                }
            }
        }
    }
}
