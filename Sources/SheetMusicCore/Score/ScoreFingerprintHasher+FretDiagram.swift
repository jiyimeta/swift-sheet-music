import SheetMusicFoundation

extension FNV1a {
    /// A fret diagram's barres beyond the first, by occupant (tag 116): a one-barre diagram feeds the bytes it always
    /// did, the first barre being `combine(_ diagram:)`'s own.
    mutating func combineExtraBarres(of diagram: FretDiagram) {
        guard diagram.barres.count > 1 else { return }
        combine(116)
        combine(diagram.barres.count - 1)
        for barre in diagram.barres.dropFirst() {
            combine(barre.startString)
            combine(barre.endString)
            combine(barre.fret)
        }
    }
}
