@testable import SheetMusicCore
import Testing

/// Small, fully timed fixtures; each score starts with a parallel system lane.
enum VoiceIdentityFixtures {
    static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    static let time = VoiceElement.timeSignature(TimeSignature(numerator: 4, denominator: 4))

    static func location(_ element: Int, measure: Int = 0, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    static func chord(_ duration: NoteDuration = .quarter, pitch: Int = 60, tpc: Int = 14) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    static func score(_ measures: [[Voice]]) -> Score {
        Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "piano"),
            staves: [Staff(measures: measures.map { Measure(voices: $0) })],
        )], systemMeasures: IdentifiedArray(measures.map { _ in SystemMeasure() }))
    }

    static func score(elements: [VoiceElement]) -> Score {
        score([[Voice(elements: elements)]])
    }

    static func elements(_ score: Score, measure: Int = 0, voice: Int = 0) -> IdentifiedArray<VoiceElement> {
        score.parts[0].staves[0].measures[measure].voices[voice].elements
    }

    static func ids(_ elements: IdentifiedArray<VoiceElement>) -> [EID] {
        elements.indices.map { elements.eid(at: $0) }
    }

    static func minted(_ initial: EIDAllocator, _ offset: UInt64) -> EID {
        EID(first: initial.actor, second: initial.counter + offset)
    }

    static func advanced(_ initial: EIDAllocator, by count: UInt64) -> EIDAllocator {
        EIDAllocator(actor: initial.actor, counter: initial.counter + count)
    }

    static func voiceIDs(_ score: Score) -> [[EID]] {
        score.parts.flatMap { part in
            part.staves.flatMap { staff in
                staff.measures.flatMap { measure in measure.voices.map { ids($0.elements) } }
            }
        }
    }

    static func spineIDs(_ score: Score) -> [EID] {
        var result = score.parts.indices.map { score.parts.eid(at: $0) }
        for part in score.parts {
            result.append(contentsOf: part.staves.indices.map { part.staves.eid(at: $0) })
        }
        result.append(contentsOf: score.systemMeasures.indices.map { score.systemMeasures.eid(at: $0) })
        return result
    }

    static func allIDs(_ score: Score) -> [EID] {
        spineIDs(score) + voiceIDs(score).flatMap(\.self)
    }

    static func expectSameScore(
        _ actual: Score, _ expected: Score, sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        // Value equality includes voice counts and tuplets, but deliberately ignores EIDs.
        #expect(actual == expected, sourceLocation: sourceLocation)
        #expect(voiceIDs(actual) == voiceIDs(expected), sourceLocation: sourceLocation)
        #expect(spineIDs(actual) == spineIDs(expected), sourceLocation: sourceLocation)
        let actualTuplets = tupletValues(actual)
        let expectedTuplets = tupletValues(expected)
        #expect(actualTuplets.ids == expectedTuplets.ids, sourceLocation: sourceLocation)
        #expect(actualTuplets.values == expectedTuplets.values, sourceLocation: sourceLocation)
        #expect(graceIDs(actual) == graceIDs(expected), sourceLocation: sourceLocation)
        let actualLaneIDs = actual.systemMeasures.map { column in
            column.elements.indices.map { column.elements.eid(at: $0) }
        }
        let expectedLaneIDs = expected.systemMeasures.map { column in
            column.elements.indices.map { column.elements.eid(at: $0) }
        }
        #expect(actualLaneIDs == expectedLaneIDs, sourceLocation: sourceLocation)
    }

    /// Per chord, before and after remain separate, including empty lists.
    private static func graceIDs(_ score: Score) -> [[[EID]]] {
        score.parts.flatMap { part in
            part.staves.flatMap { staff in
                staff.measures.flatMap { measure in
                    measure.voices.flatMap { voice in
                        voice.elements.compactMap { element -> [[EID]]? in
                            guard case let .chord(chord) = element else { return nil }
                            return [chord.graceNotesBefore, chord.graceNotesAfter].map { graces in
                                graces.indices.map { graces.eid(at: $0) }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func tupletValues(_ score: Score) -> (ids: [[EID]], values: [[Tuplet]]) {
        var ids: [[EID]] = []
        var values: [[Tuplet]] = []
        for part in score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        ids.append(voice.tuplets.indices.map { voice.tuplets.eid(at: $0) })
                        values.append(voice.tuplets.values)
                    }
                }
            }
        }
        return (ids, values)
    }
}
