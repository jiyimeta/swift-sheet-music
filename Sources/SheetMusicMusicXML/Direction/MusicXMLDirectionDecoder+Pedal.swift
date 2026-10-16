import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// One `<pedal>` (`MusicXmlParserDirection::pedal`, `P2:5340-5458`). Its `number` is never read: MuseScore keeps one
/// pedal slot (`P2:5344`).
struct MusicXMLPedalFact: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// `start`, `resume` or `sostenuto`.
        case start(resume: Bool, sostenuto: Bool)
        /// `stop` or `discontinue`.
        case stop(discontinue: Bool)
        case change
    }

    let kind: Kind
    /// `line`, as written.
    let line: String?
    /// `sign`, resolved: absent, it is "yes" when the line is not drawn or the type is `start`, else "no"
    /// (`P2:5349-5358` — MuseScore's deliberate default, as many exporters omit it).
    let sign: String
    let color: ScoreColor?

    /// `nil` for `continue` and any other type, which make nothing.
    init?(_ node: XMLTreeNode) {
        let type = node.attributes["type"] ?? ""
        switch type {
        case "start": kind = .start(resume: false, sostenuto: false)
        case "resume": kind = .start(resume: true, sostenuto: false)
        case "sostenuto": kind = .start(resume: false, sostenuto: true)
        case "stop": kind = .stop(discontinue: false)
        case "discontinue": kind = .stop(discontinue: true)
        case "change": kind = .change
        default: return nil
        }
        let line = node.attributes["line"]
        self.line = line
        let written = node.attributes["sign"] ?? ""
        sign = written.isEmpty ? (line != "yes" || type == "start" ? "yes" : "no") : written
        color = node.attributes["color"].flatMap { MusicXMLColor.parse($0) }
    }

    /// `line="yes"`: the line is drawn.
    var drawsLine: Bool {
        line == "yes"
    }
}

/// The pedal texts MuseScore writes into a pedal (`P2:5396-5418`).
enum MusicXMLPedalText {
    static let sostenuto = "<sym>keyboardPedalSost</sym>"
    static let sostenutoContinue =
        "<sym>keyboardPedalParensLeft</sym><sym>keyboardPedalSost</sym><sym>keyboardPedalParensRight</sym>"
    static let up = "<sym>keyboardPedalUp</sym>"
}

extension MusicXMLDirectionDecoder {
    /// A direction's pedals as events in the one pedal slot: a start, a stop with its edit, or for a change the stop
    /// half and then the new pedal. The stops come before the starts, as for every spanner (`P2:3777-3839`).
    static func pedalEvents(
        _ facts: MusicXMLDirectionFacts,
    ) -> (stops: [MusicXMLDirectionEvent.Payload], starts: [MusicXMLDirectionEvent.Payload]) {
        let slot = MusicXMLSpannerSlot(family: .pedal, number: 0)
        var stops: [MusicXMLDirectionEvent.Payload] = []
        var starts: [MusicXMLDirectionEvent.Payload] = []
        for pedal in facts.pedals {
            switch pedal.kind {
            case let .start(resume, sostenuto):
                starts.append(.spannerStart(slot, startedPedal(pedal, resume: resume, sostenuto: sostenuto, facts)))
            case let .stop(discontinue):
                let change = MusicXMLSpannerStopEdit.Change.pedalStop(
                    discontinue: discontinue, line: pedal.line, sign: pedal.sign,
                )
                stops.append(.spannerStop(slot, MusicXMLSpannerStopEdit(change)))
            case .change:
                stops.append(.spannerStop(slot, MusicXMLSpannerStopEdit(.pedalChange(line: pedal.line))))
                starts.append(.spannerStart(slot, changedPedal(pedal, facts)))
            }
        }
        return (stops, starts)
    }

    /// A `start`, `resume` or `sostenuto` pedal (`P2:5389-5409`): the line drawn when `line="yes"`; with no line or
    /// with a sign, the style's texts (a sostenuto's own); else no texts and a 90° begin hook (none for `resume`).
    private static func startedPedal(
        _ pedal: MusicXMLPedalFact, resume: Bool, sostenuto: Bool, _ facts: MusicXMLDirectionFacts,
    ) -> Spanner {
        var spanner = basePedal(pedal, facts)
        var properties = Spanner.LineProperties(lineVisible: pedal.drawsLine)
        if !pedal.drawsLine || pedal.sign == "yes" {
            if sostenuto {
                spanner.beginText = MusicXMLPedalText.sostenuto
                spanner.continueText = MusicXMLPedalText.sostenutoContinue
            }
        } else {
            spanner.beginText = ""
            spanner.continueText = ""
            properties.beginHook = resume ? Spanner.LineHookType.none : .hook90
        }
        spanner.lineProperties = properties
        spanner.normalizePedal()
        return spanner
    }

    /// The new pedal a `change` begins (`P2:5439-5452`): a 45° begin hook, a 90° end hook.
    private static func changedPedal(_ pedal: MusicXMLPedalFact, _ facts: MusicXMLDirectionFacts) -> Spanner {
        var spanner = basePedal(pedal, facts)
        spanner.lineProperties = Spanner.LineProperties(
            beginHook: .hook45, endHook: .hook90, lineVisible: pedal.drawsLine,
        )
        if pedal.sign == "no" {
            spanner.beginText = ""
            spanner.continueText = ""
        }
        spanner.normalizePedal()
        return spanner
    }

    /// MuseScore's `Pedal` with the direction's visibility (`P2:3826`), the pedal's color and the direction's side
    /// when it is not the styled one (below, `P2:3817-3825`).
    private static func basePedal(_ pedal: MusicXMLPedalFact, _ facts: MusicXMLDirectionFacts) -> Spanner {
        var spanner = Spanner(kind: .pedal, rawType: "Pedal", visible: facts.visible, isEndMarker: false)
        spanner.elementProperties.color = pedal.color
        if facts.placement == "above" { spanner.placement = .above }
        return spanner
    }
}

extension MusicXMLSpannerStopEdit.Change {
    /// What a pedal's stop does to the pedal it closes.
    ///
    /// - `pedalStop` (`P2:5411-5421`): `line` sets the line's visibility; when the line is not drawn or the stop has a
    ///   sign, and the pedal has no end hook yet, the end text is the pedal-up sign; else a 90° end hook (none for
    ///   `discontinue`). When the stop came first, it edited a fresh pedal (line drawn unless `line="no"`, no end
    ///   hook), and the start then rewrote everything but the end text (`P2:5389-5407`): only that survives.
    /// - `pedalChange` (`P2:5427-5433`): a 45° end hook, and `line` sets the visibility.
    /// - `lineStop`: a bracket's or dashes' stop (`MusicXMLLineStop.apply`).
    func apply(_ spanner: inout Spanner, stopCameFirst: Bool) {
        var properties = spanner.lineProperties ?? Spanner.LineProperties()
        switch self {
        case let .pedalStop(discontinue, line, sign):
            let freshVisible = line != "no"
            if stopCameFirst {
                if !freshVisible || sign == "yes" { spanner.endText = MusicXMLPedalText.up }
            } else {
                properties.lineVisible = Self.lineVisible(line, current: properties.lineVisible)
                let visible = properties.lineVisible ?? true
                let endHook = properties.endHook ?? Spanner.LineHookType.none
                if !visible || sign == "yes", endHook == Spanner.LineHookType.none {
                    spanner.endText = MusicXMLPedalText.up
                } else {
                    properties.endHook = discontinue ? Spanner.LineHookType.none : .hook90
                }
            }
        case let .pedalChange(line):
            properties.endHook = .hook45
            properties.lineVisible = Self.lineVisible(line, current: properties.lineVisible)
        case let .lineStop(stop):
            stop.apply(&spanner, stopCameFirst: stopCameFirst)
            return
        }
        spanner.lineProperties = properties
        spanner.normalizePedal()
    }

    /// A stop's `line`: "yes" draws the line, "no" hides it, anything else leaves it as it is.
    private static func lineVisible(_ line: String?, current: Bool?) -> Bool? {
        switch line {
        case "yes": true
        case "no": false
        default: current
        }
    }
}

extension Spanner {
    /// Keeps only what differs from a pedal's defaults, as MuseScore writes only those (`TWrite`, the item's
    /// `propertyDefault` / `Pedal::getPropertyStyle`, `dom/pedal.cpp:105-119`): no hook, a drawn line, the style's
    /// texts — which are empty once a begin hook is set, and the pedal-up sign at the end once the line is hidden.
    /// All-default line properties are `nil`.
    mutating func normalizePedal() {
        var properties = lineProperties ?? LineProperties()
        if properties.beginHook == LineHookType.none { properties.beginHook = nil }
        if properties.endHook == LineHookType.none { properties.endHook = nil }
        if properties.lineVisible == true { properties.lineVisible = nil }
        lineProperties = properties == LineProperties() ? nil : properties
        let hooked = properties.beginHook != nil
        if hooked, beginText?.isEmpty == true { beginText = nil }
        if hooked, continueText?.isEmpty == true { continueText = nil }
        if properties.lineVisible == false, endText == MusicXMLPedalText.up { endText = nil }
    }
}
