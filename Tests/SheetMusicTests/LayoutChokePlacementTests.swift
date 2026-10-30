import CoreGraphics
import Foundation
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// The choke is drawn after the note, at the upper right of the chord's top notehead — where Weinberg / PAS and most
/// published drum parts print it — rather than above the chord. Right of the head and of anything already right of it
/// (dots, an up stem's flag), its baseline near the head's top whichever way the stem points, with room made so the
/// next chord does not run into it.
@Suite("LayoutEngine choke placement")
struct LayoutChokePlacementTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private struct Mark {
        let origin: CGPoint
        let ink: CGRect
        let baselineY: CGFloat
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func laidOut(_ chords: [Chord]) -> LayoutDocument {
        let measure = Measure(voices: [Voice(elements: chords.map { .chord($0) })])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [measure])])],
        )
        return LayoutArticulationTests.laidOut(score)
    }

    private static func chord(
        _ pitches: [(Int, Int)], _ duration: NoteDuration, choked: Bool = true,
        also extra: [ChordArticulation] = [],
    ) -> Chord {
        Chord(
            duration: duration,
            notes: ChordNotes(pitches.map { Note(pitch: $0.0, tpc: $0.1) }),
            articulations: (choked ? [ChordArticulation(kind: .chokeCymbal)] : []) + extra,
        )
    }

    /// The room the spacing reserves follows the value the chord is DRAWN as: a two-note tremolo's half written as a
    /// whole gets the whole head's width, not the half's.
    @Test("A choke's reserved reach follows the drawn value")
    func reachFollowsTheDrawnValue() {
        let metrics = StaffMetrics(staffSize: 20)
        var doubled = Self.chord([(49, 14)], .half)
        doubled.isWrittenDoubled = true
        #expect(LayoutEngine.chokeReach(of: doubled, metrics: metrics)
            == LayoutEngine.chokeReach(of: Self.chord([(49, 14)], .whole), metrics: metrics))
    }

    /// A chord without the choke reserves nothing, so a score with no choke is spaced exactly as before.
    @Test("An unchoked chord reserves no reach", arguments: [NoteDuration.quarter, .eighth, .half, .whole])
    func unchokedReservesNothing(duration: NoteDuration) {
        let metrics = StaffMetrics(staffSize: 20)
        #expect(LayoutEngine.chokeReach(of: Self.chord([(49, 14)], duration, choked: false), metrics: metrics) == 0)
    }

    /// Every chord of the first bar, in order, as its notes and stem.
    private static func chords(_ doc: LayoutDocument) -> [(notes: [LayoutChordNote], stem: StemDirection)] {
        (doc.systems.first?.measures.first?.elements ?? []).compactMap {
            if case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = $0 { (notes, stem) } else { nil }
        }
    }

    /// Every choke of the first bar, in order, with its drawn ink and baseline.
    private static func marks(_ doc: LayoutDocument) -> [Mark] {
        let sp = doc.metrics.sp
        let em = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        let provider = FontMetrics.provider
        let baselineFromCenter = (provider.ascent(font: em) - provider.descent(font: em)) / 2
        return (doc.systems.first?.measures.first?.elements ?? []).compactMap {
            guard case let .articulation(kind, origin, isAbove, _) = $0, kind == .chokeCymbal else { return nil }
            let ink = LayoutElementShape.smuflGlyphRect(
                codepoint: ArticulationGlyph.codepoint(kind: kind, isAbove: isAbove), center: origin, sp: sp,
            )
            return Mark(origin: origin, ink: ink, baselineY: origin.y + baselineFromCenter * sp)
        }
    }

    /// The top notehead's drawn center: its origin, moved by a mirrored second's shift.
    private static func topHead(_ chord: (notes: [LayoutChordNote], stem: StemDirection), sp: CGFloat) -> CGPoint? {
        guard let top = chord.notes.min(by: { $0.origin.y < $1.origin.y }) else { return nil }
        return CGPoint(x: top.origin.x + top.mirrorDx(stem: chord.stem, sp: sp), y: top.origin.y)
    }

    @Test("A choke sits right of the top notehead, its baseline at the head's top, on either stem", arguments: [
        (67, 15, StemDirection.up), // G4
        (72, 14, StemDirection.down), // C5
    ] as [(Int, Int, StemDirection)])
    func sitsAfterTheNote(pitch: Int, tpc: Int, stem: StemDirection) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut([Self.chord([(pitch, tpc)], .quarter)])
        let sp = doc.metrics.sp
        let chord = try #require(Self.chords(doc).first)
        #expect(chord.stem == stem)
        let mark = try #require(Self.marks(doc).first)
        let head = try #require(Self.topHead(chord, sp: sp))
        let headRight = head.x + StemGeometry.attachDx(sp: sp)
        #expect(mark.ink.minX > headRight, "ink \(mark.ink.minX), head right \(headRight)")
        let headTop = head.y - sp / 2
        #expect(abs(mark.baselineY - headTop) <= sp, "baseline \(mark.baselineY), head top \(headTop)")
    }

    @Test("A choke on a dotted chord sits right of its last dot", arguments: [1, 2])
    func clearsTheDots(dots: Int) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut([Self.chord([(72, 14)], NoteDuration.quarter.dotted(dots))])
        let sp = doc.metrics.sp
        let chord = try #require(Self.chords(doc).first)
        let mark = try #require(Self.marks(doc).first)
        let head = try #require(Self.topHead(chord, sp: sp))
        let lastDotRight = head.x + sp * (DotGeometry.firstOffsetSp + CGFloat(dots - 1) * DotGeometry.spacingSp
            + DotGeometry.radiusSp)
        #expect(mark.ink.minX > lastDotRight, "ink \(mark.ink.minX), last dot right \(lastDotRight)")
    }

    /// A stem-up flag hangs right of the stem down to about the notehead's top, the height the mark sits at.
    @Test("A choke on an unbeamed stem-up eighth sits right of its flag")
    func clearsTheFlag() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut([Self.chord([(67, 15)], .eighth)])
        let sp = doc.metrics.sp
        let chord = try #require(Self.chords(doc).first)
        #expect(chord.stem == .up)
        let mark = try #require(Self.marks(doc).first)
        let head = try #require(Self.topHead(chord, sp: sp))
        let flagRight = head.x + StemGeometry.attachDx(sp: sp)
            + LayoutEngine.bravuraAdvance(SMuFLCodepoint.flag8thUp, metrics: doc.metrics)
        #expect(mark.ink.minX > flagRight, "ink \(mark.ink.minX), flag right \(flagRight)")
    }

    @Test("A choke on a two-note chord sits by the top note", arguments: [
        [(67, 15), (74, 16)], // G4 + D5
        [(60, 14), (64, 18)], // C4 + E4, stem up
        [(72, 14), (74, 16)], // C5 + D5, a second
    ] as [[(Int, Int)]])
    func sitsByTheTopNote(pitches: [(Int, Int)]) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut([Self.chord(pitches, .quarter)])
        let sp = doc.metrics.sp
        let chord = try #require(Self.chords(doc).first)
        let mark = try #require(Self.marks(doc).first)
        let headsRight = chord.notes.map { $0.origin.x + $0.mirrorDx(stem: chord.stem, sp: sp) }.max() ?? 0
        #expect(mark.ink.minX > headsRight + StemGeometry.attachDx(sp: sp))
        let head = try #require(Self.topHead(chord, sp: sp))
        #expect(abs(mark.baselineY - (head.y - sp / 2)) <= sp, "baseline \(mark.baselineY), top head \(head.y)")
    }

    /// Short values at the engine's natural width, where the gap a duration earns is narrowest: each choke has to
    /// keep clear of the next chord's notehead, and the bar's last one of the barline.
    @Test("The next chord and the barline keep clear of a choke", arguments: [
        NoteDuration.sixteenth, .thirtySecond, NoteDuration.sixteenth.dotted(1),
    ])
    func nextChordKeepsClear(duration: NoteDuration) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut([
            Self.chord([(72, 14)], duration), Self.chord([(72, 14)], duration),
            Self.chord([(67, 15)], duration), Self.chord([(67, 15)], duration),
        ])
        let sp = doc.metrics.sp
        let chords = Self.chords(doc)
        let marks = Self.marks(doc)
        try #require(chords.count == 4 && marks.count == 4)
        for (mark, next) in zip(marks, chords.dropFirst()) {
            let nextLeft = (next.notes.map(\.origin.x).min() ?? 0) - StemGeometry.attachDx(sp: sp)
            #expect(mark.ink.maxX < nextLeft, "ink right \(mark.ink.maxX), next head left \(nextLeft)")
        }
        let measure = try #require(doc.systems.first?.measures.first)
        let barX = try #require(measure.elements.lazy.compactMap { element -> CGFloat? in
            if case let .barLine(_, origin, _, _, .trailing) = element { origin.x } else { nil }
        }.first)
        let last = try #require(marks.last)
        #expect(last.ink.maxX < barX, "ink right \(last.ink.maxX), barline \(barX)")
    }

    /// The choke stands beside the head, so a mark above the chord takes the place it would have had alone.
    @Test("A choke does not push a marcato off the chord")
    func leavesTheStackAlone() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let marcato = ChordArticulation(kind: .marcato)
        let alone = Self.laidOut([Self.chord([(72, 14)], .quarter, choked: false, also: [marcato])])
        let both = Self.laidOut([Self.chord([(72, 14)], .quarter, also: [marcato])])
        func marcatoY(_ doc: LayoutDocument) -> CGFloat? {
            (doc.systems.first?.measures.first?.elements ?? []).lazy.compactMap {
                if case let .articulation(.marcato, origin, _, _) = $0 { origin.y } else { nil }
            }.first
        }
        let expected = try #require(marcatoY(alone))
        #expect(try #require(marcatoY(both)) == expected)
    }

    @Test("A choke drawn after the note is still the one articulation the hit tester selects")
    func staysSelectable() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut([Self.chord([(67, 15)], .quarter)])
        let anchors = (doc.systems.first?.measures.first?.elements ?? []).compactMap { element -> VoiceElementID? in
            if case let .articulation(.chokeCymbal, _, _, anchor) = element { anchor } else { nil }
        }
        let anchor = try #require(anchors.first)
        let target = ScoreHitTarget.articulation(anchor: anchor, kind: .chokeCymbal)
        let tester = ScoreHitTester(document: doc)
        let box = try #require(tester.elementHitRect(for: target))
        #expect(tester.hitElement(at: CGPoint(x: box.midX, y: box.midY)) == target)
    }
}
