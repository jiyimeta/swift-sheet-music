#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// A dynamic clears every chord on its staff, not only its own voice's: with two voices on one staff the other voice's
/// stem reaches down through the dynamics' row. Autoplace only sees that stem where the skyline puts it, so the skyline
/// must put it where it is drawn.
@Suite("Dynamics clear the other voices")
struct DynamicsVoicesClearanceTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures

    /// The stem rect of a chord's skyline shape: the one taller than a notehead.
    private static func stemRect(_ chord: LayoutElement, metrics: StaffMetrics) -> CGRect? {
        LayoutElementShape.shape(for: chord, id: 0, xOffset: 0, metrics: metrics)?.rects.map(\.rect)
            .first { $0.height > 2 * metrics.sp }
    }

    @Test("a chord's skyline stem stands where the stem is drawn, on the notehead's edge, not its center")
    func skylineStemIsTheDrawnStem() throws {
        let document = try F.layout(F.load("dynamics-voices"))
        var checked = 0
        for element in document.systems.flatMap(\.measures).flatMap(\.elements) {
            guard case let .chord(notes, _, stem, _, _, _, _, _, extensionLength, _, _) = element else { continue }
            let drawn = try #require(StemGeometry.compute(
                noteOrigins: notes.map(\.origin), direction: stem, beamY: nil,
                defaultStemLength: F.metrics.defaultStemLength, stemExtension: extensionLength,
                stemThickness: F.metrics.stemThickness, sp: F.metrics.sp,
            ))
            let rect = try #require(Self.stemRect(element, metrics: F.metrics))
            #expect(abs(rect.midX - drawn.xStem) < 0.001)
            checked += 1
        }
        #expect(checked == 26)
    }

    /// `own/dynamics-voices` bar 2: voice 1's quarters (stems up) carry an f, voice 2's half notes (stems down) a pp,
    /// on the upper staff. MuseScore 4.7 sets the f clear of the half notes' stems.
    @Test(
        "no dynamic's ink overlaps a chord of its bar, the other voice's down-stem included",
        arguments: [(20, 725), (28, 900)] as [(Double, Double)],
    )
    func dynamicsClearChords(staffSize: Double, width: Double) throws {
        let document = try LayoutEngine.layout(
            score: F.load("dynamics-voices"), options: ScoreViewOptions(staffSize: CGFloat(staffSize)),
            availableWidth: CGFloat(width),
        )
        let metrics = StaffMetrics(staffSize: CGFloat(staffSize))
        var checked = 0
        for measure in document.systems.flatMap(\.measures) {
            let dynamics = measure.elements.filter { element in
                if case .textMark(.dynamic, _, _, _) = element { true } else { false }
            }
            let chords = measure.elements.filter { element in
                if case .chord = element { true } else { false }
            }
            for dynamic in dynamics {
                let ink = try #require(LayoutElementShape.shape(for: dynamic, id: 0, xOffset: 0, metrics: metrics))
                    .rects.map(\.rect)
                for chord in chords {
                    let shape = LayoutElementShape.shape(for: chord, id: 1, xOffset: 0, metrics: metrics)?
                        .rects.map(\.rect) ?? []
                    for inkRect in ink {
                        for chordRect in shape {
                            #expect(!inkRect.intersects(chordRect), "dynamic \(inkRect) overlaps chord \(chordRect)")
                        }
                    }
                }
                checked += 1
            }
        }
        #expect(checked == 5)
    }
}
