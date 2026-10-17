import Foundation
@testable import SheetMusicCore

/// `Options.keepsTextMarkup`: `Score.strippingPreservedMarkup()`, but with the text formatting and the voice-assignment
/// side of the direction elements kept, so a comparison sees them. Kept: `preservedTextMarkup` on staff texts, system
/// texts, tempos, rehearsal marks, swings, instrument changes, markers, jumps, dynamics, Expressions and Stickings,
/// and the `<direction>` entries of a dynamic's or an Expression's `preservedMarkup`. Everything else the strip clears
/// stays cleared: the other preserved children are what the MSCX writer adds, not what the import reads. A hairpin's
/// `<direction>` needs nothing here — it is `payloadMarkup`, which the strip leaves.
extension ScoreSemanticComparison {
    static func strippingPreservedMarkupKeepingText(_ score: Score) -> Score {
        var stripped = score.strippingPreservedMarkup()
        for measureIndex in stripped.systemMeasures.indices {
            let source = score.systemMeasures[measureIndex].elements
            stripped.systemMeasures.updateValue(at: measureIndex) { column in
                for elementIndex in column.elements.indices {
                    column.elements.updateValue(at: elementIndex) { placed in
                        placed.element = keepingTextMarkup(of: source[elementIndex].element, in: placed.element)
                    }
                }
            }
        }
        for partIndex in stripped.parts.indices {
            let sourceStaves = score.parts[partIndex].staves
            stripped.parts.updateValue(at: partIndex) { part in
                for staffIndex in part.staves.indices {
                    let sourceMeasures = sourceStaves[staffIndex].measures
                    part.staves.updateValue(at: staffIndex) { staff in
                        for measureIndex in staff.measures.indices {
                            keepTextMarkup(of: sourceMeasures[measureIndex], in: &staff.measures[measureIndex])
                        }
                    }
                }
            }
        }
        return stripped
    }

    /// One measure: its markers' and jumps' text, and each modeled voice element's. The strip drops the voices'
    /// `.preserved` elements and nothing else, so the source's other elements line up with the stripped ones.
    private static func keepTextMarkup(of source: Measure, in measure: inout Measure) {
        for index in measure.markers.indices {
            measure.markers[index].preservedTextMarkup = source.markers[index].preservedTextMarkup
        }
        for index in measure.jumps.indices {
            measure.jumps[index].preservedTextMarkup = source.jumps[index].preservedTextMarkup
        }
        for voiceIndex in measure.voices.indices {
            let modeled = source.voices[voiceIndex].elements.filter { element in
                if case .preserved = element { return false }
                return true
            }
            guard modeled.count == measure.voices[voiceIndex].elements.count else { continue }
            for elementIndex in measure.voices[voiceIndex].elements.indices {
                measure.voices[voiceIndex].elements.updateValue(at: elementIndex) { element in
                    element = keepingTextMarkup(of: modeled[elementIndex], in: element)
                }
            }
        }
    }

    private static func keepingTextMarkup(of source: SystemElement, in element: SystemElement) -> SystemElement {
        switch (source, element) {
        case let (.staffText(kept), .staffText(text)):
            var copy = text
            copy.preservedTextMarkup = kept.preservedTextMarkup
            return .staffText(copy)
        case let (.rehearsalMark(kept), .rehearsalMark(mark)):
            var copy = mark
            copy.preservedTextMarkup = kept.preservedTextMarkup
            return .rehearsalMark(copy)
        case let (.swing(kept), .swing(swing)):
            var copy = swing
            copy.preservedTextMarkup = kept.preservedTextMarkup
            return .swing(copy)
        case let (.tempo(kept), .tempo(tempo)):
            var copy = tempo
            copy.preservedTextMarkup = kept.preservedTextMarkup
            return .tempo(copy)
        case let (.instrumentChange(kept), .instrumentChange(change)):
            var copy = change
            copy.preservedTextMarkup = kept.preservedTextMarkup
            return .instrumentChange(copy)
        default:
            return element
        }
    }

    private static func keepingTextMarkup(of source: VoiceElement, in element: VoiceElement) -> VoiceElement {
        switch (source, element) {
        case let (.dynamic(kept), .dynamic(dynamic)):
            var copy = dynamic
            copy.preservedTextMarkup = kept.preservedTextMarkup
            copy.preservedMarkup = directions(in: kept.preservedMarkup)
            return .dynamic(copy)
        case let (.expression(kept), .expression(expression)):
            var copy = expression
            copy.preservedTextMarkup = kept.preservedTextMarkup
            copy.preservedMarkup = directions(in: kept.preservedMarkup)
            return .expression(copy)
        case let (.sticking(kept), .sticking(sticking)):
            var copy = sticking
            copy.preservedTextMarkup = kept.preservedTextMarkup
            return .sticking(copy)
        default:
            return element
        }
    }

    private static func directions(in markup: [PreservedXML]) -> [PreservedXML] {
        markup.filter { $0.name == "direction" }
    }
}
