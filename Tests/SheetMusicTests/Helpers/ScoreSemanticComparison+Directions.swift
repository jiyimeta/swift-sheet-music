import Foundation
@testable import SheetMusicCore

/// The comparator passes the MusicXML `<direction>` fixtures need on top of `normalize`. Each takes a `Score` and
/// returns one.
extension ScoreSemanticComparison {
    /// Drop every `.staffText` system element — only the MSCX decoder picked them up before MusicXML did, so keeping
    /// them broke cross-format equivalence. (Tempo / rehearsal mark / swing are kept.)
    static func removingStaffText(_ score: Score) -> Score {
        var s = score
        s.systemMeasures.mapValues { measure in
            var copy = measure
            copy.elements.removeAll { element in
                if case .staffText = element.element { return true }
                return false
            }
            return copy
        }
        return s
    }

    /// Stable-sort each maximal run of consecutive untimed annotations: annotations rank 0, spanners rank 1.
    /// MuseScore's order inside one segment depends on when it added each annotation, which carries no musical
    /// meaning. Any other element (a chord, a clef, a jog, …) ends a run, so nothing moves across it.
    static func sortingAnnotationRuns(_ score: Score) -> Score {
        mappingVoices(score) { voice in
            var result: [VoiceElement] = []
            var run: [VoiceElement] = []
            func flush() {
                let ranked = run.enumerated().sorted { lhs, rhs in
                    let (l, r) = (annotationRank(lhs.element) ?? 0, annotationRank(rhs.element) ?? 0)
                    return l == r ? lhs.offset < rhs.offset : l < r
                }
                result.append(contentsOf: ranked.map(\.element))
                run.removeAll()
            }
            for element in voice.elements {
                if annotationRank(element) != nil {
                    run.append(element)
                } else {
                    flush()
                    result.append(element)
                }
            }
            flush()
            var copy = voice
            copy.elements = IdentifiedArray(result)
            return copy
        }
    }

    /// Clear the line geometry MusicXML cannot carry (hook heights, dash length and gap, line width) on every
    /// spanner, and a gradual tempo change's preserved markup (the hook geometry MuseScore writes for lines it makes).
    static func ignoringLineGeometry(_ score: Score) -> Score {
        mappingVoices(score) { voice in
            var copy = voice
            copy.elements = IdentifiedArray(voice.elements.map { element -> VoiceElement in
                guard case var .spanner(spanner) = element else { return element }
                if var line = spanner.lineProperties {
                    line.beginHookHeight = nil
                    line.endHookHeight = nil
                    line.dashLength = nil
                    line.dashGap = nil
                    line.lineWidth = nil
                    spanner.lineProperties = line == Spanner.LineProperties() ? nil : line
                }
                if spanner.gradualTempoChange != nil {
                    spanner.gradualTempoChange?.preservedMarkup = []
                }
                return .spanner(spanner)
            })
            return copy
        }
    }

    /// 0 for an untimed annotation, 1 for a spanner, `nil` for anything that ends a run.
    private static func annotationRank(_ element: VoiceElement) -> Int? {
        switch element {
        case .dynamic, .expression, .sticking, .fermata, .breath, .harmony, .figuredBass, .symbol, .capo,
             .stringTunings, .fretDiagram:
            0
        case .spanner:
            1
        default:
            nil
        }
    }

    private static func mappingVoices(_ score: Score, _ transform: @escaping (Voice) -> Voice) -> Score {
        var s = score
        s.parts.mapValues { part in
            var pt = part
            pt.staves.mapValues { staff in
                var st = staff
                st.measures = st.measures.map { measure in
                    var m = measure
                    m.voices = m.voices.map(transform)
                    return m
                }
                return st
            }
            return pt
        }
        return s
    }
}
