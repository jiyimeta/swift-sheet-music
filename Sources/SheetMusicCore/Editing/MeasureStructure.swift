/// Shared mechanics for the measure-structure commands (`InsertMeasure` / `DeleteMeasure`).
enum MeasureStructure {
    /// The signature kinds that belong to the score start and travel with it when bar 1 changes identity.
    static func isLeadingSignature(_ element: VoiceElement) -> Bool {
        switch element {
        case .keySignature, .timeSignature, .clef: true
        default: false
        }
    }

    /// The run of leading signature elements at the head of `voice`'s element list.
    static func leadingSignaturePrefix(of voice: Voice) -> [VoiceElement] {
        Array(voice.elements.prefix(while: isLeadingSignature))
    }

    static func measureCount(of score: Score) -> Int {
        score.parts.first?.staves.first?.measures.count ?? 0
    }

    static func blankColumn(for score: Score) -> MeasureSlice {
        MeasureSlice(
            staffMeasures: score.parts.map { part in
                part.staves.map { _ in Measure(voices: [Voice(elements: [.rest(duration: .measure)])]) }
            },
            systemMeasure: SystemMeasure(),
        )
    }

    /// Spanners store a relative forward measure distance; a structural change between a spanner's anchor and its
    /// end must stretch or shrink that distance.
    static func adjustSpannerOffsets(in score: inout Score, forInsertionAt index: Int) {
        adjustSpannerOffsets(in: &score) { anchorMeasure, offset in
            anchorMeasure < index && index <= anchorMeasure + offset ? offset + 1 : offset
        }
    }

    static func adjustSpannerOffsets(in score: inout Score, forDeletionAt index: Int) {
        adjustSpannerOffsets(in: &score) { anchorMeasure, offset in
            anchorMeasure < index && index <= anchorMeasure + offset ? offset - 1 : offset
        }
    }

    private static func adjustSpannerOffsets(in score: inout Score, _ transform: (Int, Int) -> Int) {
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                for measureIndex in score.parts[partIndex].staves[staffIndex].measures.indices {
                    for voiceIndex in score.parts[partIndex].staves[staffIndex].measures[measureIndex].voices.indices {
                        let elements = score.parts[partIndex].staves[staffIndex].measures[measureIndex]
                            .voices[voiceIndex].elements
                        for elementIndex in elements.indices {
                            guard case var .spanner(spanner) = elements[elementIndex] else { continue }
                            spanner.nextMeasuresOffset =
                                transform(measureIndex, spanner.nextMeasuresOffset)
                            score.parts[partIndex].staves[staffIndex].measures[measureIndex]
                                .voices[voiceIndex].elements[elementIndex] = .spanner(spanner)
                        }
                    }
                }
            }
        }
    }
}
