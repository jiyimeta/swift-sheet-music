import SheetMusicCore
import SheetMusicEditWire
import SheetMusicLayout
import Testing
import Wirelet

@Suite("Element selection — identity")
struct ScoreElementSelectionIdentityTests {
    private static let anchor = VoiceElementID(
        staff: StaffAddress(partIndex: 2, staffIndexInPart: 1),
        measureIndex: 7, voiceIndex: 3, elementIndex: 11,
    )

    private static let anchored: [ScoreElementID] = [
        .dynamic(anchor: anchor), .fermata(anchor: anchor), .breath(anchor: anchor),
        .tempo(anchor: anchor), .spanner(anchor: anchor, kind: .hairpin),
        .articulation(anchor: anchor, kind: .accent),
    ]

    private static let barAddressed: [ScoreElementID] = [
        .keySignature(measureIndex: 13), .timeSignature(measureIndex: 13),
        .barLine(measureIndex: 13, role: .explicit),
        .barLine(measureIndex: 13, role: .startRepeat),
        .barLine(measureIndex: 13, role: .trailing),
    ]

    @Test("Anchored elements preserve the anchor's position", arguments: anchored)
    func anchoredPosition(_ id: ScoreElementID) {
        let item = ScoreItemID.element(id)
        #expect(id.anchor == Self.anchor)
        #expect(id.measureIndexIfAddressedByBar == nil)
        #expect(item.staff == StaffAddress(partIndex: 2, staffIndexInPart: 1))
        #expect(item.measureIndex == 7)
        #expect(item.voiceIndex == 3)
        #expect(item.elementIndex == 11)
        #expect(item.elementID == id)
        #expect(item.textID == nil)
    }

    @Test("Bar addresses preserve the bar and approximate the remaining position", arguments: barAddressed)
    func barPosition(_ id: ScoreElementID) {
        let item = ScoreItemID.element(id)
        #expect(id.anchor == nil)
        #expect(id.measureIndexIfAddressedByBar == 13)
        #expect(item.staff == StaffAddress(partIndex: 0, staffIndexInPart: 0))
        #expect(item.measureIndex == 13)
        #expect(item.voiceIndex == 0)
        #expect(item.elementIndex == 0)
        #expect(item.elementID == id)
        #expect(item.textID == nil)
    }

    @Test("An element hit round-trips through selection", arguments: anchored + barAddressed)
    func targetRoundTrip(_ id: ScoreElementID) throws {
        let target = ScoreHitTarget(elementID: id)
        #expect(target.elementID == id)
        #expect(target.textID == nil)
        let item = try #require(target.selectableItem)
        #expect(item == .element(id))
        let selection = ScoreSelection.single(item)
        #expect(selection == .single(.element(id)))
        #expect(try ScoreHitTarget(elementID: #require(item.elementID)) == target)
    }

    @Test("Non-element identities do not acquire an element identity")
    func nonElementIdentity() {
        let target = ScoreHitTarget.harmony(anchor: Self.anchor)
        #expect(target.elementID == nil)
        #expect(target.textID == .harmony(anchor: Self.anchor))
        #expect(target.selectableItem?.elementID == nil)
        #expect(ScoreHitTarget.beam(notes: []).elementID == nil)
    }

    @Test("The hit vocabulary names the same kind as the selection vocabulary")
    func matchingTargetKinds() {
        let targets: [ScoreHitTarget] = [
            .dynamic(anchor: Self.anchor), .fermata(anchor: Self.anchor), .breath(anchor: Self.anchor),
            .tempo(anchor: Self.anchor), .spanner(anchor: Self.anchor, kind: .hairpin),
            .articulation(anchor: Self.anchor, kind: .accent),
            .keySignature(measureIndex: 13), .timeSignature(measureIndex: 13),
            .barLine(measureIndex: 13, role: .explicit),
            .barLine(measureIndex: 13, role: .startRepeat),
            .barLine(measureIndex: 13, role: .trailing),
        ]
        let identities = Self.anchored + Self.barAddressed
        #expect(targets.count == identities.count)
        for (target, id) in zip(targets, identities) {
            #expect(ScoreHitTarget(elementID: id) == target)
            #expect(target.elementID == id)
            #expect(target.selectableItem == .element(id))
        }
    }

    @Test("Filtered element cursors re-stamp anchors and preserve bar addresses")
    func filteredCursorAddresses() {
        let measures = Array(repeating: Measure(voices: [Voice(elements: [.rest(duration: .measure)])]), count: 14)
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "piano", longName: "Piano"),
            staves: [Staff(measures: measures), Staff(measures: measures)],
        )])
        let top = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let hidden: Set<StaffAddress> = [top]
        let filtered = VoiceElementID(staff: top, measureIndex: 7, voiceIndex: 3, elementIndex: 11)
        let full = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 1),
            measureIndex: 7, voiceIndex: 3, elementIndex: 11,
        )
        let constructors: [(VoiceElementID) -> ScoreElementID] = [
            { .dynamic(anchor: $0) }, { .fermata(anchor: $0) }, { .breath(anchor: $0) },
            { .tempo(anchor: $0) }, { .spanner(anchor: $0, kind: .pedal) },
            { .articulation(anchor: $0, kind: .unknown(subtype: "custom-mark")) },
        ]
        for makeID in constructors {
            let filteredCursor = ScoreCursor.item(.element(makeID(filtered)))
            let fullCursor = ScoreCursor.item(.element(makeID(full)))
            #expect(score.engineCursorForFilteredTap(filteredCursor, hiddenStaves: hidden) == fullCursor)
            #expect(score.translateCursorForHiddenStaves(fullCursor, hiddenStaves: hidden) == filteredCursor)
        }
        for id in Self.barAddressed {
            let cursor = ScoreCursor.item(.element(id))
            // The approximate top-staff path resolves, so an accidental beat fallback is observable.
            #expect(score.resolveTickInMeasure(for: .element(id)) == 0)
            #expect(score.engineCursorForFilteredTap(cursor, hiddenStaves: hidden) == cursor)
            #expect(score.translateCursorForHiddenStaves(cursor, hiddenStaves: hidden) == cursor)
        }
    }

    @Test("Spanner identity uses the domain raw spelling on the wire")
    func spannerRawString() throws {
        let wire = ScoreElementIDWire(from: .spanner(anchor: Self.anchor, kind: .hairpin))
        guard case let .spanner(_, kind) = wire else {
            Issue.record("Expected a spanner wire identity")
            return
        }
        #expect(kind == "HairPin")
        #expect(try wire.decoded() == .spanner(anchor: Self.anchor, kind: .hairpin))
    }

    @Test("Unknown spanner spellings are rejected", arguments: ["Tie", "hairpin", "", "Future"])
    func invalidSpannerKind(_ kind: String) {
        let wire = ScoreItemIDWire.element(.spanner(anchor: VoiceElementIDWire(from: Self.anchor), kind: kind))
        #expect(throws: WireFormatError.self) {
            _ = try ScoreItemIDCodec.decode(wire.encodeToData())
        }
        #expect(throws: WireFormatError.self) {
            _ = try ScoreItemIDCodec.decodeArray([wire].encodeToData())
        }
    }

    @Test("Element identity survives single and array wire encoding", arguments: anchored + barAddressed)
    func wireRoundTrip(_ id: ScoreElementID) throws {
        let item = ScoreItemID.element(id)
        let decoded = try ScoreItemIDCodec.decode(ScoreItemIDCodec.encode(item))
        #expect(decoded == item)
        #expect(Set([item]).contains(decoded))
        let decodedTarget = try ScoreHitTarget(elementID: #require(decoded.elementID))
        #expect(Set([ScoreHitTarget(elementID: id)]).contains(decodedTarget))
        let items: [ScoreItemID] = [.text(.rehearsalMark(measureIndex: 2)), item]
        #expect(try ScoreItemIDCodec.decodeArray(ScoreItemIDCodec.encodeArray(items)) == items)
    }

    @Test("Kind payloads remain distinct even when an unknown articulation spells a known token")
    func kindPayloads() throws {
        let kinds: [ChordArticulation.Kind] = [
            .staccato, .staccatissimo, .tenuto, .accent, .marcato,
            .accentStaccato, .marcatoStaccato, .unknown(subtype: "articAccent"),
            .unknown(subtype: "custom-mark"),
        ]
        let ids = kinds.map { ScoreElementID.articulation(anchor: Self.anchor, kind: $0) }
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids.map { ScoreHitTarget(elementID: $0) }).count == ids.count)
        for id in ids {
            let item = ScoreItemID.element(id)
            #expect(try ScoreItemIDCodec.decode(ScoreItemIDCodec.encode(item)) == item)
        }
        let spanners: [Spanner.Kind] = [
            .volta, .slur, .hairpin, .pedal, .ottava, .textLine,
            .glissando, .vibrato, .trill, .palmMute, .letRing, .other,
        ]
        for kind in spanners {
            let item = ScoreItemID.element(.spanner(anchor: Self.anchor, kind: kind))
            #expect(try ScoreItemIDCodec.decode(ScoreItemIDCodec.encode(item)) == item)
        }
    }
}
