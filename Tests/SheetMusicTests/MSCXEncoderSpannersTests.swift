import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Round-trip coverage for note-level spanners (ties / glissandos
/// inside `<Note>`) and voice-level spanners (`.spanner(Spanner)` —
/// Volta, Slur, HairPin, Pedal, Ottava, TextLine).
///
/// The decoder ignores location offsets on tie/glissando spanners
/// and on end-side `<prev>` placeholders, so these round-trips do
/// not require cross-note or cross-measure coordination — only the
/// begin-side `<next><location><measures>` of a voice-level Volta
/// is consulted to recover `nextMeasuresOffset`.
@Suite("MSCXEncoder spanners")
struct MSCXEncoderSpannersTests {
    private func noteRoundTrip(_ note: Note) throws -> Note {
        let xml = note.encode()
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        return try Note.decode(#require(reparsed.first("Note")))
    }

    private func voiceRoundTrip(_ voice: Voice) throws -> Voice {
        let xml = try voice.encode()
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        return try Voice.decode(#require(reparsed.first("voice")))
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

    // MARK: - Voice-level spanners

    @Test("Voice-level Volta begin + end round-trip")
    func voltaBeginEndRoundTrip() throws {
        let begin = Spanner(
            kind: .volta, rawType: "Volta",
            nextMeasuresOffset: 1,
            voltaEndings: [1],
            visible: true
        )
        let end = Spanner(
            kind: .volta, rawType: "Volta",
            nextMeasuresOffset: 0,
            voltaEndings: [],
            visible: false
        )
        let voice = Voice(elements: [
            .spanner(begin),
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)])
            )),
            .spanner(end),
        ])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }

    @Test("Voice-level Slur begin + end round-trip")
    func slurBeginEndRoundTrip() throws {
        let begin = Spanner(
            kind: .slur, rawType: "Slur",
            nextMeasuresOffset: 0,
            visible: true
        )
        let end = Spanner(
            kind: .slur, rawType: "Slur",
            visible: false
        )
        let voice = Voice(elements: [
            .spanner(begin),
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)])
            )),
            .spanner(end),
        ])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }

    @Test("Voice-level HairPin / Pedal / Ottava / TextLine begin round-trip")
    func miscVoiceSpannerKindsRoundTrip() throws {
        let kinds: [(Spanner.Kind, String)] = [
            (.hairpin, "HairPin"),
            (.pedal, "Pedal"),
            (.ottava, "Ottava"),
            (.textLine, "TextLine"),
        ]
        for (kind, raw) in kinds {
            let begin = Spanner(
                kind: kind, rawType: raw,
                nextMeasuresOffset: 2,
                visible: true
            )
            let voice = Voice(elements: [.spanner(begin)])
            let decoded = try voiceRoundTrip(voice)
            #expect(decoded == voice, "\(raw) begin failed to round-trip")
        }
    }

    @Test("Voice-level Volta with multiple endings preserves the list")
    func voltaMultipleEndingsRoundTrip() throws {
        let begin = Spanner(
            kind: .volta, rawType: "Volta",
            nextMeasuresOffset: 2,
            voltaEndings: [1, 3],
            visible: true
        )
        let voice = Voice(elements: [.spanner(begin)])
        let decoded = try voiceRoundTrip(voice)
        guard case let .spanner(roundTripped) = decoded.elements[0] else {
            Issue.record("Expected .spanner element")
            return
        }
        #expect(roundTripped.voltaEndings == [1, 3])
        #expect(roundTripped.nextMeasuresOffset == 2)
    }

    @Test("Voice with .spanner no longer throws")
    func voiceWithSpannerEncodes() throws {
        let voice = Voice(elements: [
            .spanner(Spanner(kind: .slur, rawType: "Slur")),
        ])
        _ = try voice.encode()
    }
}
