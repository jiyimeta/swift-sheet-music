import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout

enum TextPlacementFixtures {
    #if !canImport(CoreGraphics)
        typealias CGPoint = SheetMusicLayout.CGPoint
    #endif

    static let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    static let metrics = StaffMetrics(staffSize: 28)

    static func score(
        role: TextPlacementRole, side: Placement? = nil, autoplace: Bool? = nil,
        offset: ScoreOffset? = nil, text: String = "Ag", lines: Int = 5,
        style: TextPlacementStyles = TextPlacementStyles(),
    ) -> Score {
        let properties = ElementProperties(offset: offset, placement: side, autoplace: autoplace)
        var chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 71, tpc: 19)]))
        var voice: [VoiceElement] = []
        var system: [PositionedSystemElement] = []
        switch role {
        case .lyrics:
            var lyric = Lyric(text: text)
            lyric.elementProperties = properties
            chord.lyrics = [lyric]
        case .staffText, .systemText:
            var mark = StaffText(text: text, isSystemText: role == .systemText)
            mark.elementProperties = properties
            system = [PositionedSystemElement(position: .start, element: .staffText(mark), originalStaff: address)]
        case .rehearsalMark:
            var mark = RehearsalMark(text: text, frame: .rectangle)
            mark.elementProperties = properties
            system = [PositionedSystemElement(position: .start, element: .rehearsalMark(mark))]
        case .harmonyA, .harmonyB, .romanNumeral, .nashvilleNumber:
            var harmony = Harmony(name: text)
            if role == .romanNumeral { harmony.harmonyType = .roman }
            if role == .nashvilleNumber { harmony.harmonyType = .nashville }
            harmony.elementProperties = properties
            voice = [.harmony(harmony)]
        }
        voice.append(.chord(chord))
        var result = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "voice"),
            staves: [Staff(lineCount: lines, measures: [Measure(voices: [Voice(elements: voice)])])],
        )], systemMeasures: [SystemMeasure(elements: system)])
        result.style.textPlacement = style
        return result
    }

    static func layout(_ score: Score) -> LayoutDocument {
        LayoutEngine.layout(score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: 800)
    }

    static func origin(_ element: LayoutElement) -> CGPoint {
        switch element {
        case let .textMark(_, _, point), let .staffText(_, point, _, _, _, _),
             let .rehearsalMark(_, point, _, _, _, _): point
        case let .harmony(harmony): CGPoint(x: harmony.anchorX, y: harmony.y)
        case let .lyricHyphen(point, _, _), let .lyricsMelisma(point, _, _): point
        default: .zero
        }
    }

    static func mark(_ document: LayoutDocument) -> LayoutElement? {
        document.systems.flatMap(\.measures).flatMap(\.elements).first { $0.textPlacement != nil }
    }
}
