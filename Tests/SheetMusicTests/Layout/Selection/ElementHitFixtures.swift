import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

enum ElementHitFixtures {
    static let anchor = VoiceElementID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
        measureIndex: 0, voiceIndex: 0, elementIndex: 1,
    )
    static let metrics = StaffMetrics(staffSize: 40)
    static let origin = CGPoint(x: 80, y: 80)
    static let noteID = NoteID(
        staff: anchor.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
    )

    struct Sample: Sendable {
        let element: LayoutElement
        let id: ScoreElementID
    }

    static let samples: [Sample] = [
        Sample(
            element: .textMark(kind: .dynamic(anchor: anchor), text: "mf", origin: origin),
            id: .dynamic(anchor: anchor),
        ),
        Sample(
            element: .fermata(subtype: "fermataAbove", origin: origin, anchor: anchor),
            id: .fermata(anchor: anchor),
        ),
        Sample(
            element: .breath(kind: .breathMark(.comma), origin: origin, anchor: anchor),
            id: .breath(anchor: anchor),
        ),
        Sample(
            element: .textMark(kind: .tempo(anchor: anchor), text: "Allegro", origin: origin),
            id: .tempo(anchor: anchor),
        ),
        Sample(
            element: .articulation(kind: .accent, origin: origin, isAbove: true, anchor: anchor),
            id: .articulation(anchor: anchor, kind: .accent),
        ),
        Sample(element: spanner(.hairpinOpen), id: .spanner(anchor: anchor, kind: .hairpin)),
        Sample(element: spanner(.pedal), id: .spanner(anchor: anchor, kind: .pedal)),
        Sample(
            element: spanner(.ottava(subtype: .eightVA, numbersOnly: false)),
            id: .spanner(anchor: anchor, kind: .ottava),
        ),
        Sample(element: spanner(.volta(endings: [1])), id: .spanner(anchor: anchor, kind: .volta)),
        Sample(
            element: .keySignature(sharps: 4, flats: 0, clef: .bass, origin: origin, measureIndex: 0),
            id: .keySignature(measureIndex: 0),
        ),
        Sample(
            element: .timeSignature(numerator: 12, denominator: 8, origin: origin, measureIndex: 0),
            id: .timeSignature(measureIndex: 0),
        ),
        Sample(element: bar("end-repeat"), id: .barLine(measureIndex: 0, role: .explicit)),
    ]

    static let variants: [Sample] = [
        Sample(element: .keySignature(
            sharps: 0, flats: 7, clef: .treble, naturals: [4, 1, 5, 2], origin: origin, measureIndex: 0,
        ), id: .keySignature(measureIndex: 0)),
        Sample(element: .timeSignature(
            numerator: 12, denominator: 16, origin: origin, measureIndex: 0,
        ), id: .timeSignature(measureIndex: 0)),
        Sample(
            element: .textMark(kind: .dynamic(anchor: anchor), text: "very soft", origin: origin),
            id: .dynamic(anchor: anchor),
        ),
        Sample(
            element: .textMark(kind: .tempo(anchor: anchor), text: "\u{E1D5} = 120", origin: origin),
            id: .tempo(anchor: anchor),
        ),
        Sample(element: spanner(.hairpinClose), id: .spanner(anchor: anchor, kind: .hairpin)),
        Sample(element: spanner(.hairpinLine(crescendo: true)), id: .spanner(anchor: anchor, kind: .hairpin)),
        Sample(element: .keySignature(
            sharps: 0,
            flats: 0,
            clef: .treble,
            naturals: [4, 1],
            origin: origin,
            measureIndex: 0,
        ), id: .keySignature(measureIndex: 0)),
        Sample(element: .timeSignature(
            numerator: 4,
            denominator: 4,
            symbol: .common,
            origin: origin,
            measureIndex: 0,
        ), id: .timeSignature(measureIndex: 0)),
    ]

    static var signatures: [Sample] {
        (samples + variants).filter {
            switch $0.id {
            case .keySignature, .timeSignature: true
            default: false
            }
        }
    }

    static func spanner(
        _ kind: LayoutElement.SpannerKind, anchor: VoiceElementID? = ElementHitFixtures.anchor,
    ) -> LayoutElement {
        .spannerSegment(
            kind: kind, fromOrigin: origin, toOrigin: CGPoint(x: 180, y: 80),
            continuesLeft: false, continuesRight: false, text: "", anchor: anchor,
        )
    }

    static func bar(_ subtype: String?, measureIndex: Int? = 0) -> LayoutElement {
        .barLine(
            subtype: subtype,
            origin: origin,
            halfHeight: 20,
            measureIndex: measureIndex,
            role: .explicit,
        )
    }

    static func chord(_ duration: NoteDuration = .quarter, beamed: Bool = false) -> LayoutElement {
        .chord(
            notes: [LayoutChordNote(
                noteID: noteID, step: 0, accidental: nil, origin: origin,
                tieForward: nil, tieBack: nil, hasGlissando: false,
            )], duration: duration, stem: .up, stemOrigin: CGPoint(x: 85.9, y: 45),
            hasArpeggio: false, arpeggioRawType: nil, isBeamed: beamed,
            voiceIndex: 0, stemExtension: 0, stemIsInvisible: false, mag: 1,
        )
    }

    static func document(
        _ elements: [LayoutElement], spanners: [LayoutElement] = [],
        invisibleElements: [LayoutElement] = [], invisibleSpanners: [LayoutElement] = [],
        markers: [LayoutElement] = [], jumps: [LayoutElement] = [],
        metrics: StaffMetrics = ElementHitFixtures.metrics,
    ) -> LayoutDocument {
        let system = LayoutSystem(
            origin: CGPoint(x: 30, y: 40), size: CGSize(width: 300, height: 200),
            measures: [LayoutMeasure(
                measureIndex: 0, origin: CGPoint(x: 20, y: 10), width: 240,
                elements: elements, markers: markers, jumps: jumps, invisibleElements: invisibleElements,
            )],
            staffOrigins: [], partLabels: [], spanners: spanners, sp: metrics.sp,
            invisibleSpanners: invisibleSpanners,
        )
        return LayoutDocument(size: CGSize(width: 400, height: 300), systems: [system], metrics: metrics)
    }
}
