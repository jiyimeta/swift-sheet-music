import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Derives a `NoteDuration` from MusicXML `<type>`, `<dot>`, `<time-modification>`
/// and `<duration>`. Mirrors the fallback logic of MuseScore's
/// `MusicXmlParserPass2::note`: prefer the typed form (`<type>` + dots +
/// tuplet), but if it disagrees with `<duration>` or is missing, fall back to
/// a `Fraction` computed from `<duration>`.
enum MusicXMLDuration {
    /// Decode a `<note>`'s duration using its children and the current divisions.
    /// Returns `nil` if neither a typed form nor a positive `<duration>` is present;
    /// callers treat that as a malformed note.
    static func decode(
        note: XMLTreeNode,
        divisions: DivisionsContext,
    ) -> NoteDuration? {
        let durationInt = note.first("duration").flatMap { Int($0.text) }
        let typeText = note.first("type")?.text
        let dotCount = note.all("dot").count

        if let typeText,
           let base = NoteDuration(mscxName: typeText)
        {
            let dotted = base.dotted(dotCount)
            if let mod = note.first("time-modification") {
                return applyTupletModification(to: dotted, mod: mod)
            }
            return dotted
        }

        if let durationInt, durationInt > 0 {
            return .fraction(divisions.fractionOfWhole(durationInt))
        }
        return nil
    }

    private static func applyTupletModification(
        to base: NoteDuration,
        mod: XMLTreeNode,
    ) -> NoteDuration {
        guard let actualText = mod.first("actual-notes")?.text,
              let normalText = mod.first("normal-notes")?.text,
              let actual = Int(actualText),
              let normal = Int(normalText),
              actual > 0, normal > 0
        else {
            return base
        }
        let baseFraction = base.asFraction
        let n = baseFraction.numerator * normal
        let d = baseFraction.denominator * actual
        return .fraction(Fraction(numerator: n, denominator: d))
    }
}
