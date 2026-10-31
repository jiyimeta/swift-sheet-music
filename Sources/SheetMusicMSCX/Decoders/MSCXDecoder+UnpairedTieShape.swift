import SheetMusicCore
import SheetMusicFoundation

/// What shape a tie had whose side the reader drops for want of a partner — the suffix of its diagnostic code
/// (`mscx.tie.unpairedSide.<kind>`), so field data a host collects per code tells the causes apart.
///
/// The kind is read off what the file wrote for the side (`MSCXTieSide.Partner`), not off what the model kept: a side
/// is dropped exactly because the model found nothing where the file pointed.
struct MSCXUnpairedTieShape {
    enum Kind {
        /// The `<location>` names another staff (`<staves>` ≠ 0).
        case crossStaff
        /// The `<location>` names another voice of the staff (`<voices>` ≠ 0).
        case crossVoice
        /// The `<location>` names a note past the neighbouring chord: across a bar more than the chord reaches, or over
        /// chords or rests in between.
        case distant
        /// The `<location>` names the neighbouring chord, and nothing there carries the other half — the shape an
        /// edit that removed the partner leaves behind.
        case noPartner
        /// A grace note's tie, or a `<location>` naming a grace note (`<grace>`).
        case grace
        /// No `<location>` at all: MuseScore 2's `<Tie id>` / `<endSpanner>` pair, or a `<next>` / `<prev>` without
        /// one.
        case noLocation
        /// MuseScore 5's form, a `<Tie>` on the end note naming the start note by `<eid>`.
        case museScore5
    }

    let kind: Kind
    /// The raw deltas or references the file wrote, for the message.
    let detail: String

    /// The diagnostic code, spelled out per kind so each stays greppable.
    var code: String {
        switch kind {
        case .crossStaff: "mscx.tie.unpairedSide.crossStaff"
        case .crossVoice: "mscx.tie.unpairedSide.crossVoice"
        case .distant: "mscx.tie.unpairedSide.distant"
        case .noPartner: "mscx.tie.unpairedSide.noPartner"
        case .grace: "mscx.tie.unpairedSide.grace"
        case .noLocation: "mscx.tie.unpairedSide.noLocation"
        case .museScore5: "mscx.tie.unpairedSide.museScore5"
        }
    }

    init(_ recorded: MSCXTieSide?, side: MSCXTieSide.Side, measures: [Measure]) {
        guard let recorded else {
            kind = .noPartner
            detail = "<Spanner type=\"Tie\">"
            return
        }
        switch recorded.partner {
        case let .museScore5(eid):
            kind = .museScore5
            detail = side == .back
                ? "MuseScore 5 <Tie> naming start note <eid>\(eid)</eid>"
                : "MuseScore 5 tie start (note <eid>\(eid)</eid>)"
        case let .legacyID(id):
            kind = recorded.address.grace == nil ? .noLocation : .grace
            detail = side == .forward
                ? "<Tie id=\"\(id ?? "")\"> with no location"
                : "<endSpanner id=\"\(id ?? "")\"> with no location"
        case .missingLocation:
            kind = recorded.address.grace == nil ? .noLocation : .grace
            detail = "<Spanner type=\"Tie\"> <\(side == .forward ? "next" : "prev")> without <location>"
        case let .location(location):
            detail = "<Spanner type=\"Tie\"> <\(side == .forward ? "next" : "prev")> location ("
                + Self.describe(location) + ")"
            if location.staves != 0 {
                kind = .crossStaff
            } else if location.voices != 0 {
                kind = .crossVoice
            } else if recorded.address.grace != nil || location.grace != nil {
                kind = .grace
            } else {
                kind = Self.isAdjacent(recorded, location, measures: measures) ? .noPartner : .distant
            }
        }
    }

    func message(side: MSCXTieSide.Side, pitch: Int) -> String {
        let missing = "no note of pitch \(pitch) carries the other half"
        let shape = switch kind {
        case .crossStaff: "names another staff, where \(missing)"
        case .crossVoice: "names another voice, where \(missing)"
        case .distant: "names a note beyond the neighbouring chord, where \(missing) that this reader can pair"
        case .noPartner: "names the neighbouring chord, where \(missing)"
        case .grace: "is a grace note's, and \(missing)"
        case .noLocation, .museScore5: "has no partner: \(missing)"
        }
        return "\(detail) \(shape); dropping \(side.rawValue) — "
            + "MuseScore discards an unmatched connector side the same way"
    }

    private static func describe(_ location: MSCXTieSide.Location) -> String {
        var fields = [
            "staves \(location.staves)", "voices \(location.voices)", "measures \(location.measures)",
            "fractions \(location.fractions.numerator)/\(location.fractions.denominator)",
        ]
        if let grace = location.grace { fields.append("grace \(grace)") }
        if location.notes != 0 { fields.append("notes \(location.notes)") }
        return fields.joined(separator: ", ")
    }

    /// Whether `location` names the chord right beside the side's own in its voice: the position its chord ends at for
    /// a `<next>`, the start of the chord or rest before it for a `<prev>`.
    private static func isAdjacent(
        _ side: MSCXTieSide, _ location: MSCXTieSide.Location, measures: [Measure],
    ) -> Bool {
        let durations = measures.effectiveMeasureDurations()
        let target = normalized(
            measure: side.address.measure + location.measures, offset: side.start + location.fractions,
            durations: durations,
        )
        switch side.side {
        case .forward:
            return target == normalized(measure: side.address.measure, offset: side.end, durations: durations)
        case .back:
            guard let previous = previousStart(of: side, in: measures, durations: durations) else { return false }
            return target == normalized(measure: previous.measure, offset: previous.offset, durations: durations)
        }
    }

    private struct Position: Equatable {
        var measure: Int
        var offset: Fraction
    }

    /// `offset` brought within its bar, carrying whole bars into `measure`.
    private static func normalized(measure: Int, offset: Fraction, durations: [Fraction]) -> Position {
        var position = Position(measure: measure, offset: offset)
        func length(_ index: Int) -> Fraction {
            durations.indices.contains(index) ? durations[index] : Fraction(numerator: 4, denominator: 4)
        }
        func isLess(_ lhs: Fraction, _ rhs: Fraction) -> Bool {
            lhs.numerator * rhs.denominator < rhs.numerator * lhs.denominator
        }
        while position.offset.numerator < 0, position.measure > 0 {
            position.measure -= 1
            position.offset += length(position.measure)
        }
        while !isLess(position.offset, length(position.measure)), position.measure < durations.count {
            position.offset -= length(position.measure)
            position.measure += 1
        }
        return position
    }

    /// Where the chord or rest before the side's chord in its voice starts — in the bar before when the side's chord
    /// opens its own.
    private static func previousStart(
        of side: MSCXTieSide, in measures: [Measure], durations: [Fraction],
    ) -> Position? {
        func starts(in measure: Int) -> [(element: Int, offset: Fraction)] {
            guard measures.indices.contains(measure),
                  measures[measure].voices.indices.contains(side.address.voice)
            else { return [] }
            var offset = Fraction(numerator: 0, denominator: 1)
            var result: [(element: Int, offset: Fraction)] = []
            for (index, element) in measures[measure].voices[side.address.voice].elements.enumerated() {
                guard case let .chord(chord) = element else { continue }
                result.append((index, offset))
                offset += chord.duration.resolved(in: durations[measure]).asFraction
            }
            return result
        }
        let here = starts(in: side.address.measure)
        if let previous = here.last(where: { $0.element < side.address.element }) {
            return Position(measure: side.address.measure, offset: previous.offset)
        }
        guard let previous = starts(in: side.address.measure - 1).last else { return nil }
        return Position(measure: side.address.measure - 1, offset: previous.offset)
    }
}
