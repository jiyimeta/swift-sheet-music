import SheetMusicCore
import SheetMusicFoundation

/// A line MuseScore infers from words — "cresc." / "dim." a hairpin line, "rit." / "accel." / … a gradual tempo
/// change (`textToCrescLine`, `P2:4543-4564`; the tempo-line branch, `P2:3539-3549`). It has no stop in the file: a
/// later dynamic, tempo text or fermata on its staff ends it (`terminateInferredLine`, `P2:3409-3424`), and one
/// nothing ends stays zero-length.
struct MusicXMLInferredLine: Sendable, Equatable {
    /// What ends a line: a dynamic ends a hairpin line, a tempo text or a fermata a tempo line.
    enum Kind: Sendable, Equatable {
        case hairpin
        case tempo
    }

    /// Where a terminator ended the line, in the measure that holds it, and from the part's beginning.
    struct End: Sendable, Equatable {
        let measure: Int
        let tick: Fraction
        let absolute: Fraction
    }

    /// The begin side, without its `<next>`.
    let spanner: Spanner
    let staff: Int
    let measure: Int
    /// The start in its measure.
    let tick: Fraction
    /// The start from the part's beginning, which the 24-quarter limit is measured from.
    let absoluteStart: Fraction
    /// `nil` until a terminator ends the line.
    var end: End?

    var kind: Kind {
        spanner.kind == .hairpin ? .hairpin : .tempo
    }

    /// MuseScore's `line->ticks() == 0`: never ended, or ended where it starts — a line a later terminator can still
    /// end.
    var hasNoLength: Bool {
        guard let end else { return true }
        return end.absolute == absoluteStart
    }
}

/// Something that ends the open inferred lines of its kind on its staff.
struct MusicXMLInferredLineTerminator: Sendable, Equatable {
    let kind: MusicXMLInferredLine.Kind
    let staff: Int
    let measure: Int
    let tick: Fraction
    let absolute: Fraction
}

/// The part's inferred lines, opened as the walker reads their words and ended by their terminators
/// (`m_inferredHairpins` / `m_inferredTempoLines`, added at the part's end whether ended or not, `P2:2307-2314`).
struct MusicXMLInferredLineLog: Sendable, Equatable {
    /// `MAX_INFERRED_LINE_LEN` (`P2:3415`): 24 quarter notes, 6 wholes.
    static let maximumLength = Fraction(numerator: 6, denominator: 1)

    private(set) var lines: [MusicXMLInferredLine] = []

    mutating func open(_ line: MusicXMLInferredLine) {
        lines.append(line)
    }

    /// Ends every line of `kind` on `staff` that has no length yet and starts at most 24 quarters before
    /// `absolute`. MuseScore puts no lower bound on that distance, so a terminator before the line's start (after a
    /// `<backup>`) would end it before it begins; here such a terminator leaves the line as it is.
    mutating func terminate(
        kind: MusicXMLInferredLine.Kind, staff: Int, atAbsolute absolute: Fraction, measure: Int, tick: Fraction,
    ) {
        for index in lines.indices where lines[index].kind == kind && lines[index].staff == staff {
            guard lines[index].hasNoLength else { continue }
            let distance = absolute - lines[index].absoluteStart
            guard !distance.precedes(.zeroTick), !Self.maximumLength.precedes(distance) else { continue }
            lines[index].end = MusicXMLInferredLine.End(measure: measure, tick: tick, absolute: absolute)
        }
    }

    mutating func terminate(_ terminator: MusicXMLInferredLineTerminator) {
        terminate(
            kind: terminator.kind, staff: terminator.staff, atAbsolute: terminator.absolute,
            measure: terminator.measure, tick: terminator.tick,
        )
    }

    /// Each line as a begin side and an end marker on its staff: at its end, or — never ended — at its own start.
    func finished(measureLengths: [Fraction]) -> [MusicXMLClosedSpanner] {
        lines.compactMap { line -> MusicXMLClosedSpanner? in
            let end = line.end ?? MusicXMLInferredLine.End(
                measure: line.measure, tick: line.tick, absolute: line.absoluteStart,
            )
            let payload = MusicXMLDirectionEvent.Payload.voice(.spanner(line.spanner))
            let begin = MusicXMLDirectionEvent(
                measure: line.measure, staff: line.staff, tick: line.tick, payload: payload,
            )
            let stop = MusicXMLDirectionEvent(measure: end.measure, staff: line.staff, tick: end.tick, payload: payload)
            return MusicXMLSpannerPairing.closed(
                line.spanner, begin: begin, end: stop, measureLengths: measureLengths, edit: MusicXMLSpannerStopEdit(),
            )
        }
    }
}

/// The inferred lines' begin sides. Both start at the direction's tick: MuseScore adds `<offset>` a second time when
/// it places them (`addInferredHairpin` / `addInferredTempoLine` are passed `tick + m_offset` and set `tick +
/// m_offset` from it, `P2:3705`, `3764`, `4573`, `4591`), which puts the line after the element it stands for; that
/// is deliberately not mirrored.
extension MusicXMLDirectionDecoder {
    /// "cresc." / "dim." words (`textToCrescLine`, `P2:4543-4564`): a hairpin line with its line hidden and no
    /// continue text, whose text is saved only when it is not the style's "cresc." / "dim."; "cresc" wins when both
    /// appear. Its side is the hairpin's `<direction>`, kept as payload markup, from the placement attribute alone
    /// (`default-y` is not consulted), else up on a vocal staff and down on any other (`addInferredHairpin`,
    /// `P2:4575-4579`).
    static func appendInferredHairpin(
        _ facts: MusicXMLDirectionFacts, staff: Int, tick: Fraction, context: Context, to output: inout Output,
    ) {
        guard let text = facts.crescLineWords else { return }
        let isCresc = text.hasSubstring("cresc")
        let spanner = Spanner(
            kind: .hairpin, rawType: "HairPin", beginText: text == (isCresc ? "cresc." : "dim.") ? nil : text,
            hairpin: Spanner.HairpinPayload(subtype: isCresc ? .crescLine : .dimLine), continueText: "",
            isEndMarker: false, lineProperties: Spanner.LineProperties(lineVisible: false),
            payloadMarkup: [
                hairpinDirection(placement: facts.placementAttribute, isVocalStaff: context.isVocalStaff),
            ],
        )
        output.inferredLines.append(MusicXMLInferredLine(
            spanner: spanner, staff: staff, measure: context.measure, tick: tick,
            absoluteStart: context.measureStart + tick,
        ))
    }

    /// Tempo-line words (`P2:3539-3549`): a gradual tempo change whose text is the simplified words, with no continue
    /// text, below only when the direction says so (`addInferredTempoLine`, `P2:4593-4595`). MuseScore sets the
    /// continue text to "", which is GradualTempoChange's default (`gradualtempochange.cpp:228-231`), so its file
    /// carries none: `nil` here.
    static func inferredTempoLine(
        _ plain: String, type: GradualTempoChangeType, facts: MusicXMLDirectionFacts, staff: Int, tick: Fraction,
        context: Context,
    ) -> MusicXMLInferredLine {
        var spanner = Spanner(
            kind: .gradualTempoChange, rawType: "GradualTempoChange", beginText: plain,
            gradualTempoChange: Spanner.GradualTempoChangePayload(type: type), isEndMarker: false,
        )
        if facts.placement == "below" { spanner.placement = .below }
        return MusicXMLInferredLine(
            spanner: spanner, staff: staff, measure: context.measure, tick: tick,
            absoluteStart: context.measureStart + tick,
        )
    }
}
