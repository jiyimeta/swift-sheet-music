import SheetMusicCore

extension LayoutEngine {
    /// The clef declaration in force at the head of `measureIndex` — what a continuation system's restated clef
    /// glyph is a restatement OF.
    ///
    /// A restatement is not a declaration, and for a long time it carried no identity for exactly that reason.
    /// That is right about the model and wrong about the page: on system four the restated glyph is the only
    /// clef there is, and a reader clicking it means the clef that is in force, which lives back on system one.
    /// This resolves the one to the other.
    ///
    /// **Voice zero only, and the LAST declaration wins.** A clef belongs to the staff rather than to one voice
    /// of it — `SetClef` refuses any other voice outright — and within a bar the later element is the one still
    /// in force when the bar ends. `nil` is never returned: a staff with no explicit clef before this point is
    /// reading its own default, which `ClefAnchor.staffDefault` names.
    ///
    /// Walked backwards from the bar before `measureIndex`, so the common case (a clef declared on the first
    /// system, restated on every one after) costs one bar's scan per system rather than the whole score's.
    static func declaringClefAnchor(
        before measureIndex: Int, staff: Staff, address: StaffAddress,
    ) -> ClefAnchor {
        for index in stride(from: min(measureIndex, staff.measures.count) - 1, through: 0, by: -1) {
            guard let voice = staff.measures[index].voices.first else { continue }
            for element in voice.elements.indices.reversed() {
                guard case .clef = voice.elements[element] else { continue }
                return .explicit(VoiceElementID(
                    staff: address, measureIndex: index, voiceIndex: 0, elementIndex: element,
                ))
            }
        }
        return .staffDefault(address)
    }

    /// The bar whose key-signature declaration is in force at the head of `measureIndex` — what a system-head
    /// redraw of the signature is a redraw OF.
    ///
    /// The key-signature twin of `declaringClefAnchor(before:staff:address:)`, and it exists for the same
    /// reason: on page two of a paged score the redrawn signature is the only one on the sheet, so a click on it
    /// has to resolve to the declaration it shows. `nil` when no bar before this one declares a signature — the
    /// staff is in C, there is nothing to redraw, and the engine synthesizes no glyph either.
    ///
    /// **Voice zero, and the LAST declaration in the bar wins**, matching `SetKeySignature`'s own scope: it
    /// writes the leading signature run of voice zero, and within a bar the later element is the one still in
    /// force when the bar ends.
    static func declaringKeySignatureMeasure(before measureIndex: Int, staff: Staff) -> Int? {
        for index in stride(from: min(measureIndex, staff.measures.count) - 1, through: 0, by: -1) {
            guard let voice = staff.measures[index].voices.first else { continue }
            for element in voice.elements.reversed() {
                guard case .keySignature = element else { continue }
                return index
            }
        }
        return nil
    }
}
