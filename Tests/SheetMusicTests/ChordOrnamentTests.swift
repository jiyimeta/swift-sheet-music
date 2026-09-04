import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("ChordOrnament model")
struct ChordOrnamentModelTests {
    @Test func knownKindRoundTripsItsToken() {
        #expect(ChordOrnament.Kind(mscxToken: "ornamentTrill") == .trill)
        #expect(ChordOrnament.Kind.turnInverted.mscxToken == "ornamentTurnInverted")
        #expect(ChordOrnament.Kind(mscxToken: "ornamentNotAThing") == nil)
    }

    @Test func everyModeledKindHasADistinctTokenThatParsesBack() {
        var seen: Set<String> = []
        for kind in ChordOrnament.Kind.modeled {
            let token = kind.mscxToken
            #expect(token.hasPrefix("ornament"), "\(token) is not a SymId name")
            #expect(seen.insert(token).inserted, "duplicate token \(token)")
            #expect(ChordOrnament.Kind(mscxToken: token) == kind)
        }
        #expect(seen.count == 23)
    }

    @Test func unknownKeepsItsRawToken() {
        let kind = ChordOrnament.Kind.unknown(subtype: "ornamentNotAThing")
        #expect(kind.mscxToken == "ornamentNotAThing")
        #expect(kind != .trill)
    }

    @Test func intervalDefaultMatchesMuseScore() {
        #expect(ChordOrnament.Interval.default == .init(step: .second, quality: .auto))
        #expect(ChordOrnament.Interval.default.mscxToken == "second,auto")
    }

    @Test func intervalParsesTheWrittenPair() {
        #expect(
            ChordOrnament.Interval(mscxToken: "third,major")
                == .init(step: .third, quality: .major),
        )
    }

    @Test(arguments: ["", "third", "third,major,extra", "ninth,major", "third,wobbly"])
    func malformedIntervalFallsBackPerField(_ token: String) {
        // TConv::fromXml(const String&, OrnamentInterval) logs and keeps the
        // default rather than rejecting; a bad step keeps the default step and
        // a good quality still lands.
        let interval = ChordOrnament.Interval(mscxToken: token)
        #expect(interval.step == .second || interval.step == .third)
        #expect(interval.quality == .auto || interval.quality == .major)
    }

    @Test func chordDefaultsToNoOrnaments() {
        let chord = Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))
        #expect(chord.ornaments.isEmpty)
    }

    @Test func chordStoresOrnaments() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            ornaments: [ChordOrnament(
                kind: .trill,
                intervalAbove: .init(step: .third, quality: .major),
            )],
        )
        #expect(chord.ornaments.count == 1)
        #expect(chord.ornaments[0].intervalAbove == .init(step: .third, quality: .major))
    }

    private func fingerprint(_ ornaments: [ChordOrnament]) -> UInt64 {
        var hasher = FNV1a()
        hasher.combineOccupied(ornaments, tag: 33)
        return hasher.value
    }

    @Test func fingerprintSeparatesOrnamentKinds() {
        #expect(fingerprint([.init(kind: .trill)]) != fingerprint([.init(kind: .mordent)]))
    }

    @Test func fingerprintSeparatesAbsentFromExplicitlyFalse() {
        #expect(
            fingerprint([.init(kind: .trill, startOnUpperNote: nil)])
                != fingerprint([.init(kind: .trill, startOnUpperNote: false)]),
        )
    }

    @Test func fingerprintIgnoresPreservedMarkup() {
        let bare = ChordOrnament(kind: .trill)
        let withBag = ChordOrnament(
            kind: .trill,
            preservedMarkup: [PreservedXML(name: "Chord")],
        )
        #expect(fingerprint([bare]) == fingerprint([withBag]))
    }

    @Test func fingerprintOfNoOrnamentsFeedsNothing() {
        var hasher = FNV1a()
        let before = hasher.value
        hasher.combineOccupied([] as [ChordOrnament], tag: 33)
        #expect(hasher.value == before)
    }
}
