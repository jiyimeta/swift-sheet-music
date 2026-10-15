import SheetMusicFoundation

extension StaffText {
    /// What a staff text is besides its text.
    package enum Annotation: Sendable, Equatable {
        case playTechnique(PlayingTechnique, playsBack: Bool)
        case harpPedal(HarpPedalDiagram)
    }

    /// The text style an annotated text's kept `<style>` names, when it is one drawn here: `expression` — the style
    /// MuseScore's palette gives "tremolo" (`palette/internal/palettecreator.cpp:1556-1572`) — staff or system.
    /// `nil` for another style or none.
    package var annotationStyle: TextStyleType? {
        guard let token = annotationMarkup.first(where: { $0.name == "style" })?.text.lowercased() else { return nil }
        switch token {
        case "expression": return .expression
        case "staff": return .staffText
        case "system": return .systemText
        default: return nil
        }
    }
}
