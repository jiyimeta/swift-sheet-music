import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Decodes one `<direction>` into events placed by the measure clock — MuseScore's
/// `MusicXmlParserDirection::direction` (`importmusicxmlpass2.cpp`): every element lands at `tick + offset` on the
/// staff `<staff>` names.
enum MusicXMLDirectionDecoder {
    struct Context {
        /// The measure's index in the part.
        var measure: Int
        /// The part's staff count, which `<staff>` is clamped to.
        var staffCount: Int
        /// The measure clock where the `<direction>` stands.
        var now: Fraction
        var divisions: DivisionsContext
        var options: MusicXMLImportOptions
        /// The part's index in the score: a direction on part 0's first staff is on the score's top staff.
        var partIndex = 0
        /// Where the measure starts in the part, which an inferred line's 24-quarter limit is measured from.
        var measureStart = Fraction.zeroTick
        /// The import's tempo markings so far, shared by every part (`canAddTempoText`).
        let registry: MusicXMLTempoRegistryBox
    }

    /// A system-lane element the direction made, on a staff of the part, at a position in the measure.
    struct SystemPlacement: Sendable, Equatable {
        let staff: Int
        let position: MeasurePosition
        let element: SystemElement
    }

    struct Output: Sendable, Equatable {
        var events: [MusicXMLDirectionEvent] = []
        var systemElements: [SystemPlacement] = []
        /// Tempo markings, which belong to the score's top staff whatever staff the direction names.
        var tempoElements: [PositionedSystemElement] = []
        /// The inferred lines the direction's words start, opened after its terminators have ended earlier lines.
        var inferredLines: [MusicXMLInferredLine] = []
        /// What ends earlier inferred lines: the direction's dynamics and tempo text.
        var lineTerminators: [MusicXMLInferredLineTerminator] = []
    }

    static func decode(_ direction: XMLTreeNode, context: Context) -> Output {
        let staff = staffIndex(direction, staffCount: context.staffCount)
        let tick = Self.tick(of: direction, context: context)
        var output = Output()
        let facts = MusicXMLDirectionFacts(direction, infers: context.options.inferTextType)
        appendDynamics(facts, staff: staff, tick: tick, context: context, to: &output)
        appendInferredHairpin(facts, staff: staff, tick: tick, context: context, to: &output)
        let tempoCount = output.tempoElements.count
        appendTexts(facts, staff: staff, tick: tick, context: context, to: &output)
        // A tempo text ends the tempo lines on the direction's staff (`P2:3701-3704`), though it goes to the top one.
        if output.tempoElements.count > tempoCount {
            output.lineTerminators.append(MusicXMLInferredLineTerminator(
                kind: .tempo, staff: staff, measure: context.measure, tick: tick,
                absolute: context.measureStart + tick,
            ))
        }
        appendSpanners(facts, staff: staff, tick: tick, context: context, to: &output)
        return output
    }

    /// Where the direction's elements land in the measure: the clock plus its `<offset>` (`tick + offset`).
    static func tick(of direction: XMLTreeNode, context: Context) -> Fraction {
        context.now + offset(direction, context: context)
    }

    /// `<offset>` in divisions as a fraction of a whole note; one that would place the direction before the start of
    /// the measure is cut to the start (`preventNegativeTick`).
    private static func offset(_ direction: XMLTreeNode, context: Context) -> Fraction {
        guard let text = direction.first("offset")?.text, let divisions = Int(text), context.divisions.perQuarter > 0
        else { return .zeroTick }
        let offset = context.divisions.fractionOfWhole(divisions)
        return (context.now + offset).precedes(.zeroTick) ? Fraction.zeroTick - context.now : offset
    }

    /// `<staff>N</staff>` as a 0-based staff index, clamped to the part; 0 when absent.
    private static func staffIndex(_ direction: XMLTreeNode, staffCount: Int) -> Int {
        guard let text = direction.first("staff")?.text, let n = Int(text) else { return 0 }
        return min(max(n - 1, 0), max(staffCount - 1, 0))
    }
}
