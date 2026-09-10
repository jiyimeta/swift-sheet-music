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

extension ScoreElementSelectionIdentityTests {
    private static let arcStart = NoteID(
        staff: StaffAddress(partIndex: 2, staffIndexInPart: 1),
        measureIndex: 3, voiceIndex: 1, elementIndex: 4, noteIndexInChord: 2,
    )
    private static let arcEnd = NoteID(
        staff: StaffAddress(partIndex: 3, staffIndexInPart: 0),
        measureIndex: 5, voiceIndex: 1, elementIndex: 6, noteIndexInChord: 2,
    )
    private static let newIdentities: [ScoreElementID] = [
        .tie(start: arcStart, end: arcEnd),
        .slur(.chord(anchor: VoiceElementID(arcStart), ordinal: 1)),
        .slur(.voice(VoiceElementID(arcStart))),
        .jump(staff: arcStart.staff, measureIndex: 7, index: 2),
        .marker(staff: arcStart.staff, measureIndex: 7, index: 2),
    ]

    @Test("New identities preserve owners and distinguish list indices from voice slots", arguments: 0 ..< 5)
    func newIdentityPositions(_ index: Int) throws {
        let id = Self.newIdentities[index]
        let target = ScoreHitTarget(elementID: id)
        let item = try #require(target.selectableItem)
        #expect(target.elementID == id)
        #expect(target.textID == nil)
        #expect(item == .element(id))
        #expect(item.staff == StaffAddress(partIndex: 2, staffIndexInPart: 1))
        #expect(item.measureIndex == (index < 3 ? 3 : 7))
        #expect(item.voiceIndex == (index < 3 ? 1 : 0))
        #expect(item.elementIndex == (index < 3 ? 4 : 0))
        #expect(id.anchor == (index < 3 ? VoiceElementID(Self.arcStart) : nil))
        #expect(id.measureIndexIfAddressedByBar == nil)
        #expect(item.textID == nil)
    }

    @Test("Endpoint, ordinal, storage form, kind, and owning staff survive selection and wire mapping")
    func newIdentityDistinctness() throws {
        let owner = VoiceElementID(Self.arcStart)
        let otherEnd = NoteID(
            staff: Self.arcEnd.staff, measureIndex: 5, voiceIndex: 1,
            elementIndex: 7, noteIndexInChord: 2,
        )
        let pairs: [[ScoreElementID]] = [
            [Self.newIdentities[0], .tie(start: Self.arcStart, end: otherEnd)],
            [Self.newIdentities[1], .slur(.chord(anchor: owner, ordinal: 2))],
            [Self.newIdentities[1], Self.newIdentities[2]],
            [Self.newIdentities[3], Self.newIdentities[4]],
            [Self.newIdentities[3], .jump(staff: Self.arcEnd.staff, measureIndex: 7, index: 2)],
            [Self.newIdentities[4], .marker(staff: Self.arcEnd.staff, measureIndex: 7, index: 2)],
        ]
        for pair in pairs {
            let items = pair.map(ScoreItemID.element)
            let targets = pair.map { ScoreHitTarget(elementID: $0) }
            #expect(Set(pair).count == 2)
            #expect(Set(targets).count == 2)
            #expect(targets.compactMap(\.selectableItem) == items)
            let decoded = try ScoreItemIDCodec.decodeArray(ScoreItemIDCodec.encodeArray(items))
            #expect(decoded == items)
            #expect(Set(decoded).count == 2)
        }
    }

    private static func remapScore(staffCounts: [Int], voices: [Voice] = [Voice(elements: [])]) -> Score {
        let measures = Array(repeating: Measure(voices: voices), count: 8)
        return Score(division: 480, parts: IdentifiedArray(staffCounts.enumerated().map { index, count in
            Part(
                id: "P\(index)", instrument: Instrument(id: "piano", longName: "Piano"),
                staves: IdentifiedArray(Array(repeating: Staff(measures: measures), count: count)),
            )
        }))
    }

    private static func remapNote(_ part: Int, _ staff: Int, end: Bool = false) -> NoteID {
        NoteID(
            staff: StaffAddress(partIndex: part, staffIndexInPart: staff),
            measureIndex: end ? 5 : 3, voiceIndex: 1,
            elementIndex: end ? 6 : 4, noteIndexInChord: 2,
        )
    }

    @Test("Tie endpoints remap independently, including an unchanged start", arguments: [false, true])
    func tieEndpointRemapping(_ onlyEndMoves: Bool) {
        let score = Self.remapScore(staffCounts: [2, 2])
        let hidden: Set<StaffAddress> = [
            StaffAddress(partIndex: onlyEndMoves ? 1 : 0, staffIndexInPart: 0),
        ]
        let full = ScoreCursor.item(.element(.tie(
            start: Self.remapNote(0, onlyEndMoves ? 0 : 1),
            end: Self.remapNote(1, onlyEndMoves ? 1 : 0, end: true),
        )))
        let filtered = ScoreCursor.item(.element(.tie(
            start: Self.remapNote(0, 0), end: Self.remapNote(1, 0, end: true),
        )))
        #expect(score.translateCursorForHiddenStaves(full, hiddenStaves: hidden) == filtered)
        #expect(score.engineCursorForFilteredTap(filtered, hiddenStaves: hidden) == full)
        #expect(score.translateCursorForHiddenStaves(full, hiddenStaves: []) == full)
        #expect(score.engineCursorForFilteredTap(full, hiddenStaves: []) == full)
    }

    @Test("Both slur storage forms remap their owner without changing the ordinal", arguments: [false, true])
    func slurOwnerRemapping(_ standalone: Bool) {
        let score = Self.remapScore(staffCounts: [2])
        let hidden: Set<StaffAddress> = [StaffAddress(partIndex: 0, staffIndexInPart: 0)]
        let fullAnchor = VoiceElementID(Self.remapNote(0, 1))
        let filteredAnchor = VoiceElementID(Self.remapNote(0, 0))
        let fullID: SlurID = standalone ? .voice(fullAnchor) : .chord(anchor: fullAnchor, ordinal: 2)
        let filteredID: SlurID = standalone ? .voice(filteredAnchor) : .chord(anchor: filteredAnchor, ordinal: 2)
        let full = ScoreCursor.item(.element(.slur(fullID)))
        let filtered = ScoreCursor.item(.element(.slur(filteredID)))
        #expect(score.translateCursorForHiddenStaves(full, hiddenStaves: hidden) == filtered)
        #expect(score.engineCursorForFilteredTap(filtered, hiddenStaves: hidden) == full)
    }

    private static func navigation(_ staff: StaffAddress, marker: Bool) -> ScoreCursor {
        .item(.element(marker
                ? .marker(staff: staff, measureIndex: 7, index: 2)
                : .jump(staff: staff, measureIndex: 7, index: 2)))
    }

    @Test(
        "Navigation owners remap across hidden preceding staffs and fully hidden parts",
        arguments: [false, true],
        [false, true],
    )
    func navigationOwnerRemapping(_ marker: Bool, _ droppedPart: Bool) {
        let score = Self.remapScore(staffCounts: droppedPart ? [1, 1] : [2])
        let top = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let owner = StaffAddress(partIndex: droppedPart ? 1 : 0, staffIndexInPart: droppedPart ? 0 : 1)
        let full = Self.navigation(owner, marker: marker)
        let filtered = Self.navigation(top, marker: marker)
        #expect(score.translateCursorForHiddenStaves(full, hiddenStaves: [top]) == filtered)
        #expect(score.engineCursorForFilteredTap(filtered, hiddenStaves: [top]) == full)
        #expect(score.translateCursorForHiddenStaves(full, hiddenStaves: []) == full)
        #expect(score.engineCursorForFilteredTap(full, hiddenStaves: []) == full)
    }

    @Test("Hidden navigation owners use the existing beat or original-cursor fallback", arguments: [false, true])
    func hiddenNavigationOwner(_ marker: Bool) {
        let owner = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        let cursor = Self.navigation(owner, marker: marker)
        let score = Self.remapScore(staffCounts: [2])
        // Voice 0 exists, and its prefix before approximate slot 0 is empty: sum = 0.
        #expect(score.translateCursorForHiddenStaves(cursor, hiddenStaves: [owner])
            == .beat(measureIndex: 7, tickInMeasure: 0))
        let noVoice = Self.remapScore(staffCounts: [2], voices: [])
        #expect(noVoice.translateCursorForHiddenStaves(cursor, hiddenStaves: [owner]) == cursor)
        #expect(score.translateCursorForHiddenStaves(nil, hiddenStaves: [owner]) == nil)
        let top = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let bars: [ScoreElementID] = [
            .keySignature(measureIndex: 7), .timeSignature(measureIndex: 7),
            .barLine(measureIndex: 7, role: .trailing),
        ]
        for bar in bars {
            let barCursor = ScoreCursor.item(.element(bar))
            #expect(score.translateCursorForHiddenStaves(barCursor, hiddenStaves: [top]) == barCursor)
            #expect(score.engineCursorForFilteredTap(barCursor, hiddenStaves: [top]) == barCursor)
        }
    }

    @Test("A hidden tie start retains the existing tick fallback")
    func hiddenTieStartFallback() {
        let chord = VoiceElement.chord(Chord(duration: .quarter, notes: [
            Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18), Note(pitch: 67, tpc: 15),
        ]))
        let score = Self.remapScore(staffCounts: [2, 2], voices: [
            Voice(elements: []), Voice(elements: Array(repeating: chord, count: 7)),
        ])
        let full = ScoreCursor.item(.element(.tie(
            start: Self.remapNote(0, 0), end: Self.remapNote(1, 0, end: true),
        )))
        let hidden: Set<StaffAddress> = [StaffAddress(partIndex: 0, staffIndexInPart: 0)]
        // Four quarter chords before slot 4: 4 * 480 = 1920 ticks in measure 3.
        #expect(score.translateCursorForHiddenStaves(full, hiddenStaves: hidden)
            == .beat(measureIndex: 3, tickInMeasure: 1920))
        let missingVoice = Self.remapScore(staffCounts: [2, 2])
        #expect(missingVoice.translateCursorForHiddenStaves(full, hiddenStaves: hidden) == full)
    }

    @Test("An unmappable tie end never becomes an invented surviving endpoint")
    func unmappableTieEnd() {
        let score = Self.remapScore(staffCounts: [2, 2])
        let hidden: Set<StaffAddress> = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
        let full = ScoreCursor.item(.element(.tie(
            start: Self.remapNote(0, 0), end: Self.remapNote(1, 0, end: true),
        )))
        #expect(score.translateCursorForHiddenStaves(full, hiddenStaves: hidden) == full)
        let staleFiltered = ScoreCursor.item(.element(.tie(
            start: Self.remapNote(0, 0), end: Self.remapNote(1, 2, end: true),
        )))
        #expect(score.engineCursorForFilteredTap(staleFiltered, hiddenStaves: hidden) == staleFiltered)
    }
}
