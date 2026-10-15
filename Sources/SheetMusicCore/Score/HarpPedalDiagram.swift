import SheetMusicFoundation

/// MuseScore's `HarpPedalDiagram`: the seven harp pedals' positions, drawn as pedal glyphs (`isDiagram`) or as note
/// names with accidentals. What is drawn is the element's text, which MuseScore generates from this state; the state
/// itself is kept so it is written back.
package struct HarpPedalDiagram: Sendable, Equatable {
    /// MuseScore's `PedalPosition`, by its ordinal (0 flat, 1 natural, 2 sharp); any other ordinal survives as-is.
    package enum Position: Sendable, Equatable {
        case flat, natural, sharp
        case other(Int)

        package var mscxOrdinal: Int {
            switch self {
            case .flat: 0
            case .natural: 1
            case .sharp: 2
            case let .other(ordinal): ordinal
            }
        }

        package init(mscxOrdinal: Int) {
            switch mscxOrdinal {
            case 0: self = .flat
            case 1: self = .natural
            case 2: self = .sharp
            default: self = .other(mscxOrdinal)
            }
        }
    }

    /// Glyph mode (the pedal diagram) when true, note names when false. MuseScore's default is true.
    package var isDiagram: Bool
    /// One position per string, in MuseScore's `HarpStringType` order: D, C, B, E, F, G, A.
    package var pedals: [Position]

    package init(isDiagram: Bool = true, pedals: [Position] = Array(repeating: .natural, count: 7)) {
        self.isDiagram = isDiagram
        self.pedals = pedals
    }
}
