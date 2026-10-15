import SheetMusicCore

/// The elements the categories autoplace, read once per staff. Its own file at SwiftLint's `file_length` budget for
/// `SkylineAutoplacePass.swift`.
extension SkylineAutoplacePass {
    /// Every element the categories can autoplace, in staff order, with its kind.
    static func autoplaceCandidates(
        in measures: [[LayoutElement]],
    ) -> [(address: Address, kind: ShapeItemKind)] {
        var result: [(address: Address, kind: ShapeItemKind)] = []
        for (mIdx, elements) in measures.enumerated() {
            for (i, el) in elements.enumerated() {
                guard let kind = LayoutElementShape.kind(of: el),
                      el.textPlacement?.autoplace != false else { continue }
                result.append((Address(measure: mIdx, index: i), kind))
            }
        }
        return result
    }

    static func collect(
        kinds: [ShapeItemKind], from candidates: [(address: Address, kind: ShapeItemKind)],
    ) -> [Address] {
        candidates.filter { kinds.contains($0.kind) }.map(\.address)
    }
}
