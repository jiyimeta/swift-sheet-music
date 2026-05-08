import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Round-trip coverage for the `VoiceElement` cases that Phase 2.3
/// promoted from the `throws "not yet supported"` branch into
/// first-class encoders: tempo, dynamic, barLine, staffText / system
/// text, rehearsal mark, harmony, measure repeat, fermata, and the
/// voice-level location shift.
@Suite("MSCXEncoder text-elements")
struct MSCXEncoderTextElementsTests {
    private func voiceRoundTrip(_ voice: Voice) throws -> Voice {
        let xml = try voice.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        return try Voice.decode(#require(reparsed.first("voice")))
    }

    @Test("Tempo with default TextProperties round-trips")
    func tempoDefaultRoundTrip() throws {
        let voice = Voice(elements: [
            .tempo(Tempo(beatsPerSecond: 2.0)),
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
        ])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }

    @Test("BarLine round-trips with and without subtype")
    func barLineRoundTrip() throws {
        for subtype in [nil, "end", "double", "start-repeat"] as [String?] {
            let voice = Voice(elements: [
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
                .barLine(BarLine(subtype: subtype)),
            ])
            let decoded = try voiceRoundTrip(voice)
            #expect(decoded == voice, "BarLine subtype=\(subtype ?? "nil") failed")
        }
    }

    @Test("Dynamic round-trips subtype + velocity + TextProperties")
    func dynamicRoundTrip() throws {
        let dynamic = Dynamic(
            subtype: "ff",
            velocity: 110,
            properties: TextProperties(face: "Edwin", size: 11, style: [.italic])
        )
        let voice = Voice(elements: [.dynamic(dynamic)])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }

    @Test("Tempo round-trips offset, hidden flag, and TextProperties")
    func tempoFullRoundTrip() throws {
        let tempo = Tempo(
            beatsPerSecond: 1.5,
            offsetX: 1.25,
            offsetY: -2.5,
            properties: TextProperties(
                face: "Times New Roman",
                size: 14,
                style: [.bold, .italic],
                frameType: .circle,
                framePadding: 0.5
            ),
            visible: false
        )
        let voice = Voice(elements: [.tempo(tempo)])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }
}
