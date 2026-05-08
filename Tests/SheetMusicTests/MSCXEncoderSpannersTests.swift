import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Round-trip coverage for note-level spanners — ties and glissandos
/// emitted as `<Spanner>` children inside `<Note>`.
///
/// The decoder ignores location offsets on tie/glissando spanners
/// (it keys off the bare presence of `<next>` / `<prev>` and the
/// inner `<Glissando>` payload), so these round-trips do not require
/// any cross-note coordination.
@Suite("MSCXEncoder spanners")
struct MSCXEncoderSpannersTests {
    private func noteRoundTrip(_ note: Note) throws -> Note {
        let xml = note.encode()
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        return try Note.decode(#require(reparsed.first("Note")))
    }

    // MARK: - Note-level: ties

    @Test("Note round-trips tieForward")
    func tieForwardRoundTrip() throws {
        let note = Note(pitch: 60, tpc: 14, tieForward: 1)
        let decoded = try noteRoundTrip(note)
        #expect(decoded.tieForward == 1)
        #expect(decoded.tieBack == nil)
    }

    @Test("Note round-trips tieBack")
    func tieBackRoundTrip() throws {
        let note = Note(pitch: 60, tpc: 14, tieBack: 1)
        let decoded = try noteRoundTrip(note)
        #expect(decoded.tieForward == nil)
        #expect(decoded.tieBack == 1)
    }

    @Test("Note round-trips both tieForward and tieBack")
    func tieBothSidesRoundTrip() throws {
        let note = Note(pitch: 60, tpc: 14, tieForward: 1, tieBack: 1)
        let decoded = try noteRoundTrip(note)
        #expect(decoded.tieForward == 1)
        #expect(decoded.tieBack == 1)
    }

    // MARK: - Note-level: glissandos

    @Test("Note round-trips a chromatic straight glissando")
    func glissandoChromaticStraightRoundTrip() throws {
        let gliss = Glissando(
            style: .chromatic, visualType: .straight,
            easeIn: 0, easeOut: 0, text: nil
        )
        let note = Note(pitch: 60, tpc: 14, glissando: gliss)
        let decoded = try noteRoundTrip(note)
        #expect(decoded.glissando == gliss)
    }

    @Test("Note round-trips a wavy diatonic glissando with eases and label")
    func glissandoWavyDiatonicRoundTrip() throws {
        let gliss = Glissando(
            style: .diatonic, visualType: .wavy,
            easeIn: 25, easeOut: 75, text: "gliss."
        )
        let note = Note(pitch: 67, tpc: 17, glissando: gliss)
        let decoded = try noteRoundTrip(note)
        #expect(decoded.glissando == gliss)
    }

    @Test("Note round-trips every Glissando.Style case")
    func glissandoStylesRoundTrip() throws {
        let styles: [Glissando.Style] = [
            .chromatic, .diatonic, .whiteKeys, .blackKeys, .portamento,
        ]
        for style in styles {
            let gliss = Glissando(style: style, visualType: .straight)
            let note = Note(pitch: 60, tpc: 14, glissando: gliss)
            let decoded = try noteRoundTrip(note)
            #expect(
                decoded.glissando?.style == style,
                "style \(style) failed to round-trip"
            )
        }
    }
}
