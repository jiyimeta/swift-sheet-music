import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// One `<bracket>` or `<dashes>` start or stop (`MusicXmlParserDirection::bracket` / `dashes`, `P2:5095-5258`). Both
/// pair in one `line` slot per number (`getSpanner`, `P2:5552-5553`). `continue` and any other type make nothing.
struct MusicXMLLineFact: Sendable, Equatable {
    enum Element: Sendable, Equatable {
        case bracket
        case dashes
    }

    let element: Element
    let isStart: Bool
    /// The 0-based slot number (`MusicXMLSpannerSlot.number`).
    let number: Int
    /// A bracket's `line-end`, `line-type`, `end-length` and `color`; a dashes element reads none of them.
    let lineEnd: String?
    let lineType: String?
    /// `end-length` as MuseScore reads it (`String::toDouble`: text that is no number is 0); `nil` when absent.
    let endLength: Double?
    let color: ScoreColor?
    /// The direction's `placement()` while the element is read (`P2:3372-3379`): the direction's attribute, else the
    /// side this element's `default-y` puts it on.
    let placement: String?
    /// The words read before a start that takes them in as its text (`hack: combine with a previous words element`,
    /// `P2:5139-5144`, `5236-5248`), as xml text; `nil` when it takes none.
    var words: String?

    init?(_ node: XMLTreeNode, placement: String?) {
        guard let number = MusicXMLSpannerSlot.number(node.attributes["number"]) else { return nil }
        switch node.attributes["type"] {
        case "start": isStart = true
        case "stop": isStart = false
        default: return nil
        }
        element = node.name == "dashes" ? .dashes : .bracket
        self.number = number
        self.placement = placement
        let isBracket = element == .bracket
        lineEnd = isBracket ? node.attributes["line-end"] : nil
        lineType = isBracket ? node.attributes["line-type"] : nil
        endLength = isBracket ? node.attributes["end-length"].flatMap { $0.isEmpty ? nil : (Double($0) ?? 0) } : nil
        color = isBracket ? node.attributes["color"].flatMap { MusicXMLColor.parse($0) } : nil
    }

    /// A bracket with `line-type="wavy"`, which MuseScore makes a trill line (`P2:5102-5103`).
    var isWavy: Bool {
        element == .bracket && lineType == "wavy"
    }

    /// A start that takes the words in: a dashes start, and a bracket start that makes a text line (`P2:5139`).
    var takesWords: Bool {
        isStart && !isWavy
    }
}

extension MusicXMLDirectionFacts {
    /// A bracket or dashes element, unless MuseScore skips it as a second start (or stop) of its number in this
    /// direction (`spannerExists`): a bracket checks the lines of its own element type (a trill for a wavy one, a
    /// text line otherwise, which a dashes element also is), a dashes element checks the hairpins — its lookup type,
    /// though it registers as a text line (`P2:5105-5106`, `5229-5234`, `5254-5259`).
    mutating func readLine(_ node: XMLTreeNode, placement: String?) {
        guard var line = MusicXMLLineFact(node, placement: placement) else { return }
        let repeated = switch line.element {
        case .bracket:
            lines.contains { $0.isStart == line.isStart && $0.number == line.number && $0.isWavy == line.isWavy }
        case .dashes:
            wedges.contains { $0.isStart == line.isStart && $0.number == line.number }
        }
        guard !repeated else { return }
        if line.takesWords, !wordsXML.isEmpty {
            line.words = wordsXML
            wordsXML = ""
        }
        lines.append(line)
    }
}

/// What a bracket's or dashes' stop element makes, as data (`P2:5180-5216`, `5254-5258`): a wavy bracket's stop is a
/// trill, any other a text line carrying the bracket's end hook — a dashes stop sets none.
struct MusicXMLLineStop: Sendable, Equatable {
    /// The stop is a wavy bracket's.
    let makesTrill: Bool
    let endHook: Spanner.LineHookType?
    let endHookHeight: Double?

    init(_ fact: MusicXMLLineFact) {
        makesTrill = fact.isWavy
        endHook = MusicXMLLineStyle.hook(fact.lineEnd)
        endHookHeight = MusicXMLLineStyle.hookHeight(fact)
    }

    /// A stop closing an open start sets its end hook when the start is a text line (`P2:5195-5216`) — a trill or a
    /// gradual tempo change takes nothing from it. A stop read before its start was taken in by the start already
    /// (`MusicXMLLineStart.spanner(afterHeldStop:)`).
    func apply(_ spanner: inout Spanner, stopCameFirst: Bool) {
        guard !stopCameFirst, spanner.kind == .textLine else { return }
        applyEnd(to: &spanner)
    }

    func applyEnd(to spanner: inout Spanner) {
        var properties = spanner.lineProperties ?? Spanner.LineProperties()
        if let endHook { properties.endHook = endHook }
        if let endHookHeight { properties.endHookHeight = endHookHeight }
        spanner.lineProperties = properties
        spanner.normalizeTextLine()
    }
}

/// A bracket's or dashes' start, with the spanners it can become. A bracket start that finds a stop held in its slot
/// takes the stop's element over (`sline = spdesc.isStopped ? spdesc.sp : 0`, `P2:5112-5113`): a wavy stop's makes it
/// a trill whatever its own line type, any other stop's a text line — a wavy start included — that keeps the stop's
/// end hook. A dashes start keeps its own spanner: it is looked up in the line slot it pairs in, and it sets its own
/// hooks and line style over whatever it took.
struct MusicXMLLineStart: Sendable, Equatable {
    let isDashes: Bool
    /// The spanner with no stop held.
    let asRead: Spanner
    let trill: Spanner
    let textLine: Spanner

    func spanner(afterHeldStop edit: MusicXMLSpannerStopEdit?) -> Spanner {
        guard let edit, !isDashes, case let .lineStop(stop)? = edit.change else { return asRead }
        if stop.makesTrill { return trill }
        var spanner = textLine
        stop.applyEnd(to: &spanner)
        return spanner
    }
}

/// A bracket's `line-end` / `line-type` / `end-length` as MuseScore sets them on a text line (`P2:5124-5162`).
enum MusicXMLLineStyle {
    static func hook(_ lineEnd: String?) -> Spanner.LineHookType? {
        switch lineEnd {
        case "up", "down": .hook90
        case "both": .hook90T
        case "arrow": .arrowFilled
        case "none": Spanner.LineHookType.none
        default: nil
        }
    }

    /// `end-length` ÷ 10 in spatia, ÷ 20 for `both`, negated for `down` — saved only when `end-length` unstyles it;
    /// without one, `down` negates the styled height, which is not saved.
    static func hookHeight(_ fact: MusicXMLLineFact) -> Double? {
        guard let length = fact.endLength else { return nil }
        let height = fact.lineEnd == "both" ? length / 20 : length / 10
        return fact.lineEnd == "down" ? -height : height
    }

    /// `solid`, `dashed` or `dotted` unstyle the line style; `wavy` and anything else leave it.
    static func lineType(_ lineType: String?) -> Spanner.LineType? {
        switch lineType {
        case "solid": .solid
        case "dashed": .dashed
        case "dotted": .dotted
        default: nil
        }
    }
}

extension MusicXMLDirectionDecoder {
    /// A direction's bracket and dashes elements as events in their line slots: the stops, then the starts.
    static func lineEvents(
        _ facts: MusicXMLDirectionFacts, context: Context,
    ) -> (stops: [MusicXMLDirectionEvent.Payload], starts: [MusicXMLDirectionEvent.Payload]) {
        var stops: [MusicXMLDirectionEvent.Payload] = []
        var starts: [MusicXMLDirectionEvent.Payload] = []
        for line in facts.lines {
            let slot = MusicXMLSpannerSlot(family: .line, number: line.number)
            if line.isStart {
                starts.append(.lineStart(slot, lineStart(line, facts: facts, context: context)))
            } else {
                stops.append(.spannerStop(slot, MusicXMLSpannerStopEdit(.lineStop(MusicXMLLineStop(line)))))
            }
        }
        return (stops, starts)
    }

    private static func lineStart(
        _ line: MusicXMLLineFact, facts: MusicXMLDirectionFacts, context: Context,
    ) -> MusicXMLLineStart {
        switch line.element {
        case .dashes:
            let spanner = dashesLine(line, facts: facts, context: context)
            return MusicXMLLineStart(isDashes: true, asRead: spanner, trill: spanner, textLine: spanner)
        case .bracket:
            let trill = trillLine(facts)
            let textLine = bracketTextLine(line, facts: facts)
            return MusicXMLLineStart(
                isDashes: false, asRead: line.isWavy ? trill : textLine, trill: trill, textLine: textLine,
            )
        }
    }

    /// A bracket's text line (`P2:5122-5165`): the begin hook and its height, the line type, the bracket's color and
    /// the words it took in, as plain text.
    private static func bracketTextLine(_ line: MusicXMLLineFact, facts: MusicXMLDirectionFacts) -> Spanner {
        var spanner = Spanner(kind: .textLine, rawType: "TextLine", visible: facts.visible, isEndMarker: false)
        spanner.lineProperties = Spanner.LineProperties(
            beginHook: MusicXMLLineStyle.hook(line.lineEnd), beginHookHeight: MusicXMLLineStyle.hookHeight(line),
            lineType: MusicXMLLineStyle.lineType(line.lineType),
        )
        spanner.beginText = line.words.map { MusicXMLFormattedWords.plainText(ofXMLText: $0) }
        spanner.elementProperties.color = line.color
        placeLine(&spanner, facts: facts)
        spanner.normalizeTextLine()
        return spanner
    }

    /// A wavy bracket's trill line (`P2:5114-5121`): a prall-prall trill; `line-end` and `color` are not read.
    private static func trillLine(_ facts: MusicXMLDirectionFacts) -> Spanner {
        var spanner = Spanner(
            kind: .trill, rawType: "Trill", visible: facts.visible,
            trill: Spanner.TrillPayload(type: .prallprall), isEndMarker: false,
        )
        placeLine(&spanner, facts: facts)
        return spanner
    }

    /// A dashes line (`P2:5236-5253`): a text line whose text is the words it took in, simplified — or, when those
    /// words read as a tempo line, a gradual tempo change. Its hooks are the defaults, and its dashed line style stays
    /// styled, so it saves none of them. `isLikelyTempoLine` reads the part's first staff here: the direction's
    /// `<staff>` comes after its `<direction-type>` (`P2:3461-3463`).
    private static func dashesLine(
        _ line: MusicXMLLineFact, facts: MusicXMLDirectionFacts, context: Context,
    ) -> Spanner {
        let words = line.words ?? ""
        let plain = MusicXMLFormattedWords.simplified(MusicXMLFormattedWords.plainText(ofXMLText: words))
        let traits = MusicXMLTextTraits(
            xmlText: words, placement: line.placement, isScoreTopStaff: context.partIndex == 0,
            hasMetronome: facts.hasMetronome, soundTempo: facts.sound.tempo, isSystemDirection: facts.isSystem,
            soundTechnique: nil, infers: context.options.inferTextType,
        )
        var spanner = if MusicXMLWordsClassifier.isLikelyTempoLine(traits, plain: plain) {
            Spanner(
                kind: .gradualTempoChange, rawType: "GradualTempoChange", visible: facts.visible,
                gradualTempoChange: Spanner.GradualTempoChangePayload(
                    type: MusicXMLWordsClassifier.tempoLineType(for: plain),
                ),
                isEndMarker: false,
            )
        } else {
            Spanner(kind: .textLine, rawType: "TextLine", visible: facts.visible, isEndMarker: false)
        }
        if line.words != nil { spanner.beginText = plain }
        placeLine(&spanner, facts: facts)
        spanner.normalizeTextLine()
        return spanner
    }

    /// `direction()` puts a line that has no placement below, unless its `default-y` puts it above
    /// (`P2:3817-3825`, `setSLinePlacement`); above is the style's side for a text line, a trill and a gradual tempo
    /// change, so only below is saved.
    private static func placeLine(_ spanner: inout Spanner, facts: MusicXMLDirectionFacts) {
        if (facts.placement ?? "below") == "below" { spanner.placement = .below }
    }
}

extension Spanner {
    /// Keeps only what a text line saves (`TWrite::writeProperty` against `TextLine::propertyDefault`): no hook,
    /// a solid line and an empty begin text are its defaults. All-default line properties are `nil`.
    mutating func normalizeTextLine() {
        var properties = lineProperties ?? LineProperties()
        if properties.beginHook == LineHookType.none { properties.beginHook = nil }
        if properties.endHook == LineHookType.none { properties.endHook = nil }
        if properties.lineType == .solid { properties.lineType = nil }
        if properties.lineVisible == true { properties.lineVisible = nil }
        lineProperties = properties == LineProperties() ? nil : properties
        if beginText?.isEmpty == true { beginText = nil }
    }
}
