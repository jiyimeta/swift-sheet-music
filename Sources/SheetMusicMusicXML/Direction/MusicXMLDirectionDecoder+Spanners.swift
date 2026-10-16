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

/// A direction's spanner starts and stops, as events the part's pairing closes (`MusicXMLSpannerPairing`): the stops
/// first, then the starts (`P2:3777-3839`), all at the direction's tick on its staff.
extension MusicXMLDirectionDecoder {
    static func appendSpanners(
        _ facts: MusicXMLDirectionFacts, staff: Int, tick: Fraction, context: Context, to output: inout Output,
    ) {
        func append(_ payload: MusicXMLDirectionEvent.Payload) {
            output.events.append(MusicXMLDirectionEvent(
                measure: context.measure, staff: staff, tick: tick, payload: payload,
            ))
        }
        for wedge in facts.wedges where !wedge.isStart {
            let slot = MusicXMLSpannerSlot(family: .hairpin, number: wedge.number)
            append(.spannerStop(slot, MusicXMLSpannerStopEdit()))
        }
        for wedge in facts.wedges {
            guard let subtype = wedge.subtype else { continue }
            let slot = MusicXMLSpannerSlot(family: .hairpin, number: wedge.number)
            append(.spannerStart(slot, hairpin(subtype, wedge: wedge, facts: facts)))
        }
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
