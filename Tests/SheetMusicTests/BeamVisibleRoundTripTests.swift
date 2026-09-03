import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `Chord.beamVisible` used to be decode-only: `MSCXDecoder+Voice` read `<Beam><visible>0</visible></Beam>` onto
/// the next chord, and no encoder wrote it back, so a hidden beam survived import but not save. Pinned here from
/// the encode side; the decode side is `HiddenVoiceBeamTests`.
@Suite("Beam visibility round trip")
struct BeamVisibleRoundTripTests {
    private static let note = Note(pitch: 60, tpc: 14)

    private static func flags(_ voice: Voice) -> [Bool] {
        voice.elements.compactMap { if case let .chord(c) = $0 { c.beamVisible } else { nil } }
    }

    @Test("a hidden beam is written as a <Beam> sibling right before its leading chord, and decodes back")
    func hiddenBeamRoundTrips() throws {
        let voice = Voice(elements: [
            .chord(Chord(duration: .eighth, notes: [Self.note], beamVisible: false)),
            .chord(Chord(duration: .eighth, notes: [Self.note])),
            .rest(duration: .quarter),
            .rest(duration: .half),
        ])
        let encoded = try voice.encode()
        #expect(encoded.children.map(\.name) == ["Beam", "Chord", "Chord", "Rest", "Rest"])
        #expect(encoded.children[0].first("visible")?.text == "0")
        #expect(encoded.children[0].children.count == 1)
        #expect(try Self.flags(Voice.decode(encoded)) == [false, true, true, true])
    }

    @Test("a hidden beam on a rest is written the same way — the decoder lands the flag on rests too")
    func hiddenBeamOnRest() throws {
        var rest = Chord(duration: .eighth, notes: [])
        rest.beamVisible = false
        let voice = Voice(elements: [
            .chord(Chord(duration: .eighth, notes: [Self.note])), .chord(rest),
            .rest(duration: .quarter), .rest(duration: .half),
        ])
        let encoded = try voice.encode()
        #expect(encoded.children.map(\.name) == ["Chord", "Beam", "Rest", "Rest", "Rest"])
        #expect(try Self.flags(Voice.decode(encoded)) == [true, false, true, true])
    }

    @Test("the <Beam> goes after the chord's grace notes, where MuseScore writes it")
    func beamFollowsGraces() throws {
        var lead = Chord(duration: .eighth, notes: [Self.note], beamVisible: false)
        lead.graceNotesBefore = [GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [Self.note])]
        let voice = Voice(elements: [
            .chord(lead), .chord(Chord(duration: .eighth, notes: [Self.note])),
            .rest(duration: .quarter), .rest(duration: .half),
        ])
        let names = try voice.encode().children.map(\.name)
        #expect(names.prefix(3) == ["Chord", "Beam", "Chord"]) // grace <Chord>, then <Beam>, then the parent
    }

    @Test("a visible beam writes no <Beam> at all")
    func visibleBeamOmitsTag() throws {
        let voice = Voice(elements: [
            .chord(Chord(duration: .eighth, notes: [Self.note])), .chord(Chord(duration: .eighth, notes: [Self.note])),
            .rest(duration: .quarter), .rest(duration: .half),
        ])
        #expect(try !(voice.encode().children.contains { $0.name == "Beam" }))
    }
}
