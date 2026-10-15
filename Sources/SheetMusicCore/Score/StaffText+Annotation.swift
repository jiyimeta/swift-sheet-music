import SheetMusicFoundation

extension StaffText {
    /// What a staff text is besides its text.
    package enum Annotation: Sendable, Equatable {
        case playTechnique(PlayingTechnique, playsBack: Bool)
        case harpPedal(HarpPedalDiagram)
    }
}
