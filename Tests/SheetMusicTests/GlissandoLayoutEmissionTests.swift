import Foundation
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's own CoreGraphics shims also export `CGPoint`
    /// and `CGSize` (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so anchor
    /// explicitly to SheetMusicLayout's own definitions instead of leaving them ambiguous.
    ///
    /// `private typealias` keeps these file-scoped — a module-scope `typealias CGPoint` here
    /// would collide with the same pattern in every other file in this target that needs it.
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGSize = SheetMusicLayout.CGSize
#endif

/// Regression coverage for glissando line emission. A glissando on the
/// LAST chord of a voice in a measure used to be dropped when its
/// paired chord lived in the NEXT measure — the old placement-time
/// pairing only looked at chords within the same measure/voice. The
/// fix resolves glissandi in a post-pass (mirroring
/// `LayoutEngine+Ties.swift`) that can look past measure boundaries.
@Suite("Glissando layout emission (same-measure and cross-measure)")
struct GlissandoLayoutEmissionTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private typealias GlissLine = (
        from: CGPoint, to: CGPoint, wavy: Bool, text: String?,
    )

    /// All `.glissandoLine` spanners across every system, in system order.
    private static func glissandoLines(
        in systems: [LayoutSystem],
    ) -> [GlissLine] {
        systems.flatMap { system in
            system.spanners.compactMap { el -> GlissLine? in
                guard case let .glissandoLine(from, to, wavy, text) = el
                else { return nil }
                return (from, to, wavy, text)
            }
        }
    }

    /// First-note origin (measure-local) of every real chord
    /// (non-empty notes) in `measure`, in element order.
    private static func chordFirstNoteOrigins(
        in measure: LayoutMeasure,
    ) -> [CGPoint] {
        measure.elements.compactMap { el -> CGPoint? in
            guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = el,
                  let n = notes.first
            else { return nil }
            return CGPoint(
                x: measure.origin.x + n.origin.x,
                y: measure.origin.y + n.origin.y,
            )
        }
    }

    @Test("Same-measure glissando emits one spanner-level glissando line")
    func sameMeasureGlissandoEmitsLine() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let a = Note(
            pitch: 60, tpc: 14,
            glissando: Glissando(visualType: .straight),
        )
        let b = Note(pitch: 64, tpc: 18)
        let m = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [a])),
            .chord(Chord(duration: .quarter, notes: [b])),
        ])])
        let staff = Staff(measures: [m])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
        )
        let doc = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 800,
        )
        let lines = Self.glissandoLines(in: doc.systems)
        #expect(lines.count == 1)
        let origins = Self.chordFirstNoteOrigins(in: doc.systems[0].measures[0])
        #expect(origins.count == 2)
        if let line = lines.first, origins.count == 2 {
            let inset = doc.metrics.sp * 0.8
            #expect(abs(line.from.x - (origins[0].x + inset)) < 0.01)
            #expect(abs(line.from.y - origins[0].y) < 0.01)
            #expect(abs(line.to.x - (origins[1].x - inset)) < 0.01)
            #expect(abs(line.to.y - origins[1].y) < 0.01)
        }
    }

    @Test("Glissando on the last chord of a measure crosses into the next measure")
    func crossMeasureGlissandoEmitsLine() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // `a` is the ONLY (hence last) element of measure 0's voice;
        // `b` is the first element of measure 1's voice, same voice
        // index (0). This is the exact shape from the confirmed bug
        // report: a glissando on the last chord of a measure with no
        // "next chord" left in that same measure.
        let a = Note(
            pitch: 60, tpc: 14,
            glissando: Glissando(visualType: .straight),
        )
        let b = Note(pitch: 64, tpc: 18)
        let m1 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [a])),
        ])])
        let m2 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [b])),
        ])])
        let staff = Staff(measures: [m1, m2])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
        )
        let doc = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 800,
        )
        let lines = Self.glissandoLines(in: doc.systems)
        #expect(lines.count == 1)
    }

    @Test("Wavy glissando with text survives into the emitted line")
    func wavyAndTextSurvive() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let a = Note(
            pitch: 60, tpc: 14,
            glissando: Glissando(visualType: .wavy, text: "gliss."),
        )
        let b = Note(pitch: 64, tpc: 18)
        let m = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [a])),
            .chord(Chord(duration: .quarter, notes: [b])),
        ])])
        let staff = Staff(measures: [m])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
        )
        let doc = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 800,
        )
        let lines = Self.glissandoLines(in: doc.systems)
        #expect(lines.count == 1)
        #expect(lines.first?.wavy == true)
        #expect(lines.first?.text == "gliss.")
    }

    @Test("Cross-system glissando keeps both segments within their own system's vertical bounds")
    func crossSystemGlissandoStaysWithinSystemBounds() { // swiftlint:disable:this function_body_length
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // Two whole-note measures with a large pitch leap (so the two
        // notes sit at clearly different heights — the BEGIN and END
        // stubs must land at different y's), forced onto separate
        // systems the same way `TiePairingTests.tieAcrossSystemBreak`
        // forces the wrap: too-narrow `availableWidth` + `wrapToViewWidth`.
        let a = Note(
            pitch: 60, tpc: 14,
            glissando: Glissando(visualType: .straight),
        )
        let b = Note(pitch: 84, tpc: 14) // two octaves up: a large leap
        let m1 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [a])),
        ])])
        let m2 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [b])),
        ])])
        let staff = Staff(measures: [m1, m2])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
        )
        let opts = ScoreViewOptions(wrapToViewWidth: true)
        let doc = LayoutEngine.layout(
            score: score, options: opts, availableWidth: 200,
        )
        // Sanity: the wrap actually produced two systems, one measure
        // each, and the pair's two endpoints land in different systems.
        #expect(doc.systems.count == 2)
        let pairs = LayoutEngine.resolveGlissandi(for: doc, score: score)
        #expect(pairs.count == 1)
        if let pair = pairs.first {
            let fromIdx = LayoutEngine.systemIndex(
                for: pair.fromOrigin.y, in: doc.systems,
            )
            let toIdx = LayoutEngine.systemIndex(
                for: pair.toOrigin.y, in: doc.systems,
            )
            #expect(fromIdx != nil)
            #expect(toIdx != nil)
            #expect(fromIdx != toIdx)
        }

        let beginLines = Self.glissandoLines(in: [doc.systems[0]])
        let endLines = Self.glissandoLines(in: [doc.systems[1]])
        #expect(beginLines.count == 1)
        #expect(endLines.count == 1)
        guard let begin = beginLines.first, let end = endLines.first else { return }

        // Both y-coordinates of both segments must stay within that
        // system's local bounds — the document-ABSOLUTE-delta
        // regression sent one endpoint hundreds of points outside
        // its own system.
        let sys0Height = doc.systems[0].size.height
        let sys1Height = doc.systems[1].size.height
        #expect(begin.from.y >= 0 && begin.from.y <= sys0Height)
        #expect(begin.to.y >= 0 && begin.to.y <= sys0Height)
        #expect(end.from.y >= 0 && end.from.y <= sys1Height)
        #expect(end.to.y >= 0 && end.to.y <= sys1Height)

        // Each stub anchors at its OWN note's height: BEGIN touches
        // the source note (system 0), END touches the target note
        // (system 1). The far end of each stub is free to carry a
        // clamped pitch-space slope (checked below); the near end,
        // touching the notehead, never moves off it.
        guard let pair = pairs.first else { return }
        let sp = doc.metrics.sp
        let expectedFromLocalY = pair.fromOrigin.y - doc.systems[0].origin.y
        let expectedToLocalY = pair.toOrigin.y - doc.systems[1].origin.y
        #expect(abs(begin.from.y - expectedFromLocalY) < 0.5)
        #expect(abs(end.to.y - expectedToLocalY) < 0.5)

        // Vertical travel is hard-clamped to ±1.5 sp per segment.
        // This fixture's two-octave leap produces a raw pitch-space
        // delta far larger than that, so a passing assertion here
        // proves the clamp actually fires rather than passing
        // vacuously on a small leap.
        #expect(abs(begin.from.y - begin.to.y) <= 1.5 * sp + 0.01)
        #expect(abs(end.from.y - end.to.y) <= 1.5 * sp + 0.01)

        // Minimum visible run lengths — the specific complaint this
        // fix addresses: the BEGIN stub used to be ≈2.4 sp, too
        // short to clear the "gliss." label's width gate, and the
        // END stub used to shrink to ≈0.2 sp when the target was
        // the system's first note.
        let beginRun = begin.to.x - begin.from.x
        let expectedMinBeginRun = min(
            5 * sp,
            (doc.systems[0].size.width + 2 * sp) - begin.from.x,
        )
        #expect(beginRun >= expectedMinBeginRun - 0.01)
        let endRun = end.to.x - end.from.x
        #expect(endRun >= 2.5 * sp - 0.01)
    }

    @Test("Cross-system glissando falls back to horizontal stubs when staff addresses are unavailable")
    func crossSystemGlissandoFallsBackToHorizontalWithoutStaffAddresses() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // Hand-built systems with EMPTY `staffAddresses` (the shape
        // hand-built test fixtures use — real layouts always
        // populate it, see `LayoutEngine+SystemBuild.swift`).
        // `LayoutSystem.flatIndex(for:)` then returns `nil` for
        // both endpoints, and `attachGlissandi` must fall back to
        // horizontal stubs rather than crash or mis-slope.
        let metrics = StaffMetrics(staffSize: 28) // sp == 7
        let sys0 = LayoutSystem(
            origin: CGPoint(x: 0, y: 0),
            size: CGSize(width: 200, height: 150),
            measures: [],
            staffOrigins: [],
            partLabels: [],
            spanners: [],
            sp: metrics.sp,
        )
        let sys1 = LayoutSystem(
            origin: CGPoint(x: 0, y: 150),
            size: CGSize(width: 200, height: 150),
            measures: [],
            staffOrigins: [],
            partLabels: [],
            spanners: [],
            sp: metrics.sp,
        )
        // A large vertical difference between the two absolute
        // origins — if the fallback failed to gate on `flatIndex ==
        // nil` this would produce a large, clearly non-zero slope.
        let pair = LayoutEngine.GlissandoPair(
            fromOrigin: CGPoint(x: 150, y: 50),
            toOrigin: CGPoint(x: 50, y: 250),
            wavy: false,
            text: "gliss.",
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
        )
        let result = LayoutEngine.attachGlissandi(
            to: [sys0, sys1], pairs: [pair], metrics: metrics,
        )
        let beginLines = Self.glissandoLines(in: [result[0]])
        let endLines = Self.glissandoLines(in: [result[1]])
        #expect(beginLines.count == 1)
        #expect(endLines.count == 1)
        if let begin = beginLines.first {
            #expect(abs(begin.from.y - begin.to.y) < 0.01)
        }
        if let end = endLines.first {
            #expect(abs(end.from.y - end.to.y) < 0.01)
        }
    }
}
