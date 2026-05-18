import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("LayoutEngine tempo auto-placement")
struct TempoLayoutTests {
    /// Build a one-measure score with a tempo + chord at beat 1.
    /// Returns the absolute Y of the tempo glyph and of the first
    /// notehead so callers can compute the clearance between them.
    ///
    /// Mirrors the harmony auto-placer's test strategy: absolute Y
    /// alone isn't a useful gauge because the per-staff top padding
    /// expands to absorb the autoplace shift — the staff sinks down
    /// instead of the text moving up — but the visible gap above
    /// the notehead grows.
    @available(macOS 15.0, iOS 16.0, *)
    private static func tempoAndNoteY(
        forPitch pitch: Int,
    ) -> (tempo: CGFloat, note: CGFloat)? {
        let note = Note(pitch: pitch, tpc: 17)
        let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
        let voice = Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(chord),
        ])
        let measure = Measure(voices: [voice])
        let systemMeasure = SystemMeasure(elements: [
            PositionedSystemElement(
                position: .start,
                element: .tempo(Tempo(beatsPerSecond: 3.1)),
            ),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [measure])],
            )],
            systemMeasures: [systemMeasure],
        )
        let document = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 28),
            availableWidth: 800,
        )
        var tempoY: CGFloat?
        var noteY: CGFloat?
        for system in document.systems {
            for measure in system.measures {
                let absY = system.origin.y + measure.origin.y
                for el in measure.elements {
                    if case let .textMark(.tempo, _, p) = el, tempoY == nil {
                        tempoY = absY + p.y
                    }
                    if case let .chord(notes, _, _, _, _, _, _, _, _) = el,
                       noteY == nil,
                       let n = notes.first
                    {
                        noteY = absY + n.origin.y
                    }
                }
            }
        }
        guard let t = tempoY, let n = noteY else { return nil }
        return (t, n)
    }

    /// A high note (F6, three ledger lines above the treble staff)
    /// would render ABOVE the tempo's default Y. Without the
    /// auto-placement pass the metronome glyph collides with the
    /// notehead. Verified by checking the tempo's Y sits ABOVE
    /// (smaller, screen-y) the notehead — and stays above it for
    /// notes pushed even higher.
    @available(macOS 15.0, iOS 16.0, *)
    @Test func tempoClearsHighNoteheads() throws {
        // staffSize=28 → sp = 7 pt. 1 sp clearance is the visible
        // gap that MuseScore's default `tempoText.minDistance`
        // (0.5 sp) produces once you add the glyph's half-height.
        for pitch in [83, 86, 89, 92, 95] {
            let (tempo, note) = try #require(Self.tempoAndNoteY(forPitch: pitch))
            // Tempo's centre Y must sit strictly above the notehead's
            // centre Y, with at least 1 sp clearance. (Without the
            // autoplace pass this gap is NEGATIVE — tempo Y > note Y.)
            #expect(note - tempo > 7.0, "pitch=\(pitch) tempoY=\(tempo) noteY=\(note)")
        }
    }

    /// When the chord stays well inside the staff, the autoplace pass
    /// must NOT push the tempo any higher than necessary — its Y
    /// relative to the staff should match the default placement
    /// (`staffMidY - sp * 4`). We verify this by comparing two
    /// in-staff pitches: both should yield the same tempo-relative-
    /// to-system-top Y, because the staff itself doesn't move.
    @available(macOS 15.0, iOS 16.0, *)
    @Test func tempoUntouchedWhenChordFitsInStaff() throws {
        // E5 (pitch 76) — top space. Stem direction defaults to
        // DOWN, chord top is the notehead — well below tempo
        // default. Autoplace must NOT engage.
        let e5 = try #require(Self.tempoAndNoteY(forPitch: 76))
        // B5 (pitch 83) — one ledger line below the top of the
        // ledger area, still close to the staff. Same lack of
        // autoplace expected; tempo should sit at the same Y.
        let b5 = try #require(Self.tempoAndNoteY(forPitch: 83))
        // Both tempos must be at the SAME absolute Y (the staff
        // didn't have to move down to give the tempo room).
        #expect(abs(e5.tempo - b5.tempo) < 0.5)
    }
}
