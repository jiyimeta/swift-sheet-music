import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `Tempo.decode` recovers the metronome beat unit (the note the marking counts in) from a `<Tempo>` element by
/// inverting MuseScore's followText math: `quartersPerBeat = beatsPerSecond * 60 / printedValue`.
@Suite("Tempo beat-unit decode")
struct TempoBeatUnitDecodeTests {
    /// Build a `<Tempo>` node the way the parser yields one: `<tempo>` (quarter-normalized bps), an optional
    /// `<followText>`, and a `<text>` whose printed value sits on a nested inline-formatting child.
    private func tempoNode(bps: String, followText: String?, printed: String?) -> XMLTreeNode {
        var children = [XMLTreeNode(name: "tempo", text: bps)]
        if let followText {
            children.append(XMLTreeNode(name: "followText", text: followText))
        }
        if let printed {
            children.append(XMLTreeNode(name: "text", children: [
                XMLTreeNode(name: "b", text: " = \(printed)"),
            ]))
        }
        return XMLTreeNode(name: "Tempo", children: children)
    }

    @Test("Quarter-note marking: bps 3, printed 180")
    func quarter() throws {
        let tempo = try Tempo.decode(tempoNode(bps: "3", followText: "1", printed: "180"))
        #expect(tempo.beatNote == .quarter)
        #expect(tempo.beatDots == 0)
        #expect(tempo.beatsPerMinute == 180)
    }

    @Test("Dotted-quarter marking (compound meter): bps 3, printed 120")
    func dottedQuarter() throws {
        let tempo = try Tempo.decode(tempoNode(bps: "3", followText: "1", printed: "120"))
        #expect(tempo.beatNote == .quarter)
        #expect(tempo.beatDots == 1)
        #expect(tempo.beatsPerMinute == 120)
    }

    @Test("Eighth-note marking: bps 1, printed 120")
    func eighth() throws {
        let tempo = try Tempo.decode(tempoNode(bps: "1", followText: "1", printed: "120"))
        #expect(tempo.beatNote == .eighth)
        #expect(tempo.beatDots == 0)
        #expect(tempo.beatsPerMinute == 120)
    }

    @Test("Half-note marking: bps 2, printed 60")
    func half() throws {
        let tempo = try Tempo.decode(tempoNode(bps: "2", followText: "1", printed: "60"))
        #expect(tempo.beatNote == .half)
        #expect(tempo.beatDots == 0)
    }

    @Test("followText off falls back to a plain quarter")
    func followTextOff() throws {
        let tempo = try Tempo.decode(tempoNode(bps: "3", followText: "0", printed: "120"))
        #expect(tempo.beatNote == .quarter)
        #expect(tempo.beatDots == 0)
    }

    @Test("Missing text falls back to a plain quarter")
    func noText() throws {
        let tempo = try Tempo.decode(tempoNode(bps: "3", followText: "1", printed: nil))
        #expect(tempo.beatNote == .quarter)
        #expect(tempo.beatDots == 0)
    }

    @Test("Non-standard ratio falls back to a plain quarter")
    func unmatchedRatio() throws {
        // bps 2.17 → 130.2 quarter-BPM; printed 100 → 1.302 quarters/beat, matching no standard note.
        let tempo = try Tempo.decode(tempoNode(bps: "2.17", followText: "1", printed: "100"))
        #expect(tempo.beatNote == .quarter)
        #expect(tempo.beatDots == 0)
    }

    @Test("Beat glyph: quarter is noteQuarterUp")
    func quarterGlyph() throws {
        let tempo = try Tempo.decode(tempoNode(bps: "3", followText: "1", printed: "180"))
        #expect(tempo.beatGlyph == "\u{E1D5}")
    }

    @Test("Beat glyph: dotted quarter appends an augmentation dot")
    func dottedQuarterGlyph() throws {
        let tempo = try Tempo.decode(tempoNode(bps: "3", followText: "1", printed: "120"))
        #expect(tempo.beatGlyph == "\u{E1D5}\u{E1E7}")
    }

    @Test("Beat glyph: eighth is note8thUp")
    func eighthGlyph() throws {
        let tempo = try Tempo.decode(tempoNode(bps: "1", followText: "1", printed: "120"))
        #expect(tempo.beatGlyph == "\u{E1D7}")
    }
}
