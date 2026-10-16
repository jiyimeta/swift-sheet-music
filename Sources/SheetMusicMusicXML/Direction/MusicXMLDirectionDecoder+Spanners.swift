import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// One `<wedge>` (`MusicXmlParserDirection::wedge`, `P2:5470-5514`): a `crescendo` or `diminuendo` start, or a `stop`.
/// `continue` and any other type make nothing; `niente`, `spread` and `line-type` are not modeled.
struct MusicXMLWedgeFact: Sendable, Equatable {
    /// The hairpin a start makes; `nil` for a stop.
    let subtype: Spanner.HairpinPayload.Subtype?
    /// The 0-based slot number (`MusicXMLSpannerSlot.number`).
    let number: Int
    /// `color` on a start (`colorItem`, `P2:5488`).
    let color: ScoreColor?

    /// `nil` for a type that makes nothing, or a number no slot takes.
    init?(_ node: XMLTreeNode) {
        guard let number = MusicXMLSpannerSlot.number(node.attributes["number"]) else { return nil }
        switch node.attributes["type"] {
        case "crescendo": subtype = .crescendo
        case "diminuendo": subtype = .decrescendo
        case "stop": subtype = nil
        default: return nil
        }
        self.number = number
        color = subtype == nil ? nil : node.attributes["color"].flatMap { MusicXMLColor.parse($0) }
    }

    var isStart: Bool {
        subtype != nil
    }

    /// A second start (or stop) of the same number in one direction, which MuseScore skips (`spannerExists`,
    /// `P2:5477-5481`, `5502-5506`).
    func repeats(_ other: MusicXMLWedgeFact) -> Bool {
        isStart == other.isStart && number == other.number
    }
}

/// One `<octave-shift>` (`MusicXmlParserDirection::octaveShift`, `P2:5279-5330`): an `up` or `down` start of size 8,
/// 15 or 22, or a `stop`. A start of any other size makes nothing (`P2:5291-5292`); its stop still is one.
struct MusicXMLOctaveShiftFact: Sendable, Equatable {
    /// The ottava a start makes; `nil` for a stop.
    let subtype: Spanner.OttavaPayload.Subtype?
    /// The 0-based slot number (`MusicXMLSpannerSlot.number`).
    let number: Int
    /// `color` on a start (`P2:5316`).
    let color: ScoreColor?

    init?(_ node: XMLTreeNode) {
        guard let number = MusicXMLSpannerSlot.number(node.attributes["number"]) else { return nil }
        let size = Int(node.attributes["size"] ?? "") ?? 0
        switch (node.attributes["type"] ?? "", size) {
        case ("down", 8): subtype = .eightVA
        case ("down", 15): subtype = .fifteenMA
        case ("down", 22): subtype = .twentyTwoMA
        case ("up", 8): subtype = .eightVB
        case ("up", 15): subtype = .fifteenMB
        case ("up", 22): subtype = .twentyTwoMB
        case ("stop", _): subtype = nil
        default: return nil
        }
        self.number = number
        color = subtype == nil ? nil : node.attributes["color"].flatMap { MusicXMLColor.parse($0) }
    }

    var isStart: Bool {
        subtype != nil
    }

    /// A second start (or stop) of the same number in one direction, which MuseScore skips (`spannerExists`,
    /// `P2:5285-5289`, `5321-5325`).
    func repeats(_ other: MusicXMLOctaveShiftFact) -> Bool {
        isStart == other.isStart && number == other.number
    }

    /// The side MuseScore's style puts the ottava on (`styledef.cpp:638-641`): 8va / 15ma / 22ma above, the rest below.
    var styledPlacement: Placement {
        guard let subtype else { return .below }
        return switch subtype {
        case .eightVA, .fifteenMA, .twentyTwoMA: .above
        case .eightVB, .fifteenMB, .twentyTwoMB, .other: .below
        }
    }
}

/// A direction's spanner starts and stops, as events the part's pairing closes (`MusicXMLSpannerPairing`): the stops
/// first, then the starts (`P2:3777-3839`), at the direction's tick on its staff — except an ottava's stop, which
/// ignores `<offset>` (`P2:3786-3787`, `3801`). The Sibelius habit of ending an ottava a note early (`P2:3788-3794`)
/// is not mirrored here.
extension MusicXMLDirectionDecoder {
    static func appendSpanners(
        _ facts: MusicXMLDirectionFacts, staff: Int, tick: Fraction, context: Context, to output: inout Output,
    ) {
        func append(_ payload: MusicXMLDirectionEvent.Payload, at eventTick: Fraction) {
            output.events.append(MusicXMLDirectionEvent(
                measure: context.measure, staff: staff, tick: eventTick, payload: payload,
            ))
        }
        let pedals = pedalEvents(facts)
        for wedge in facts.wedges where !wedge.isStart {
            let slot = MusicXMLSpannerSlot(family: .hairpin, number: wedge.number)
            append(.spannerStop(slot, MusicXMLSpannerStopEdit()), at: tick)
        }
        for shift in facts.octaveShifts where !shift.isStart {
            let slot = MusicXMLSpannerSlot(family: .ottava, number: shift.number)
            append(.spannerStop(slot, MusicXMLSpannerStopEdit()), at: context.now)
        }
        for stop in pedals.stops {
            append(stop, at: tick)
        }
        for wedge in facts.wedges {
            guard let subtype = wedge.subtype else { continue }
            let slot = MusicXMLSpannerSlot(family: .hairpin, number: wedge.number)
            append(.spannerStart(slot, hairpin(subtype, wedge: wedge, facts: facts)), at: tick)
        }
        for shift in facts.octaveShifts {
            guard let subtype = shift.subtype else { continue }
            let slot = MusicXMLSpannerSlot(family: .ottava, number: shift.number)
            append(.spannerStart(slot, ottava(subtype, shift: shift, facts: facts)), at: tick)
        }
        for start in pedals.starts {
            append(start, at: tick)
        }
    }

    /// The begin side of an octave shift: MuseScore's `Ottava` with the direction's visibility and the shift's color,
    /// on the direction's `placement` when that is not the styled side; `default-y` is not consulted (`P2:5297`,
    /// `5306`).
    private static func ottava(
        _ subtype: Spanner.OttavaPayload.Subtype, shift: MusicXMLOctaveShiftFact, facts: MusicXMLDirectionFacts,
    ) -> Spanner {
        var spanner = Spanner(
            kind: .ottava, rawType: "Ottava", visible: facts.visible,
            ottava: Spanner.OttavaPayload(subtype: subtype), isEndMarker: false,
        )
        spanner.elementProperties.color = shift.color
        let placement: Placement? = switch facts.placementAttribute {
        case "above": .above
        case "below": .below
        default: nil
        }
        if let placement, placement != shift.styledPlacement { spanner.placement = placement }
        return spanner
    }

    /// The begin side of a wedge: MuseScore's `HairPin` with the direction's visibility (`P2:3826`) and the wedge's
    /// color. Its placement is never set: MuseScore stores a hairpin's side as its `<direction>`
    /// (`setSLinePlacement`, `P2:1641-1653`), which this model does not carry.
    private static func hairpin(
        _ subtype: Spanner.HairpinPayload.Subtype, wedge: MusicXMLWedgeFact, facts: MusicXMLDirectionFacts,
    ) -> Spanner {
        var spanner = Spanner(
            kind: .hairpin, rawType: "HairPin", visible: facts.visible,
            hairpin: Spanner.HairpinPayload(subtype: subtype), isEndMarker: false,
        )
        spanner.elementProperties.color = wedge.color
        return spanner
    }
}
