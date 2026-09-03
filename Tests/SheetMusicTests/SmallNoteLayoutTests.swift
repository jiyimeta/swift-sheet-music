import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's own CoreGraphics shims also export `CGFloat`
    /// (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so anchor explicitly to
    /// SheetMusicLayout's own definition instead of leaving it ambiguous.
    ///
    /// `private typealias` keeps this file-scoped — a module-scope `typealias CGFloat` here
    /// would collide with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

@Suite("SmallNote layout mag")
struct SmallNoteLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    // MARK: - Helpers

    /// Build a minimal one-measure score whose sole chord has
    /// `isSmall` set on its note according to the argument, run
    /// it through `LayoutEngine.layout`, and return the `mag`
    /// extracted from the first `.chord` layout element found.
    @available(macOS 15.0, iOS 16.0, *)
    private func chordMag(isSmall: Bool) -> CGFloat? {
        let note = Note(pitch: 60, tpc: 14, isSmall: isSmall)
        let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "p1",
            instrument: Instrument(id: "piano"),
            staves: [staff],
        )
        let score = Score(division: 480, parts: [part])
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(),
            availableWidth: 800,
        )
        let elements = doc.systems.flatMap { sys in
            sys.measures.flatMap(\.elements)
        }
        for el in elements {
            if case let .chord(
                _, _, _, _, _, _, _, _, _, _, mag,
            ) = el {
                return mag
            }
        }
        return nil
    }

    // MARK: - Tests

    @Test("Small note chord gets 0.7 mag")
    func smallChordGetsReducedMag() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        #expect(chordMag(isSmall: true) == 0.7)
    }

    @Test("Normal chord gets 1.0 mag")
    func normalChordMagIsOne() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        #expect(chordMag(isSmall: false) == 1.0)
    }
}
