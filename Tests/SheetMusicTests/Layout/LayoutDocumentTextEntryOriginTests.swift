#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// Off Apple there is no one `CGPoint`: `SheetMusicCore` declares a shim
    /// (`Score/CGCompat+WASI.swift`) and so does `SheetMusicLayout`
    /// (`Fonts/CGTypes+Android.swift`), and this file imports both modules, so
    /// the bare name is ambiguous. Anchor to the Layout definition, which is
    /// what `LayoutDocument` element origins are. Same fix, same reason, as the
    /// bridge targets — see `SheetMusicBridgeCore/LayoutBridge.swift`.
    ///
    /// The `canImport` guard above only decides whether CoreGraphics is
    /// imported; it does not disambiguate a name, so it cannot cover this.
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

@Suite("LayoutDocument text-entry origins")
struct LayoutDocumentTextEntryOriginTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let staff = StaffAddress(
        partIndex: 0, staffIndexInPart: 0,
    )

    @Test func staffAndSystemTextOriginsMatchTheirFinalLayoutElements() throws {
        var score = Self.score()
        let first = Self.anchor(element: 0)
        let second = Self.anchor(element: 1)
        _ = try SetStaffText(
            anchor: first, text: "same", isSystemText: false,
        ).apply(to: &score)
        _ = try SetStaffText(
            anchor: second, text: "same", isSystemText: true,
        ).apply(to: &score)
        let document = Self.layout(score)
        let staffOrigin = try #require(document.staffTextOrigin(
            at: first, text: "same", style: .staffText,
        ))
        let systemOrigin = try #require(document.staffTextOrigin(
            at: second, text: "same", style: .systemText,
        ))
        let expectedStaff = try Self.staffTextElementOrigin(
            in: document, text: "same", style: .staffText,
        )
        let expectedSystem = try Self.staffTextElementOrigin(
            in: document, text: "same", style: .systemText,
        )

        #expect(staffOrigin == expectedStaff)
        #expect(systemOrigin == expectedSystem)
        #expect(staffOrigin != systemOrigin)
    }

    @Test func duplicateTextUsesTheOriginNearestItsAnchor() throws {
        var score = Self.score()
        let first = Self.anchor(element: 0)
        let second = Self.anchor(element: 1)
        _ = try SetStaffText(
            anchor: first, text: "pizz.", isSystemText: false,
        ).apply(to: &score)
        _ = try SetStaffText(
            anchor: second, text: "pizz.", isSystemText: false,
        ).apply(to: &score)
        let document = Self.layout(score)
        let firstOrigin = try #require(document.staffTextOrigin(
            at: first, text: "pizz.", style: .staffText,
        ))
        let secondOrigin = try #require(document.staffTextOrigin(
            at: second, text: "pizz.", style: .staffText,
        ))

        #expect(firstOrigin.x < secondOrigin.x)
    }

    @Test func harmonyOriginIsTheLeadingRunAnchor() throws {
        var score = Self.score()
        let anchor = Self.anchor(element: 0)
        _ = try SetChordSymbol(
            at: anchor, name: "Am7", harmonyType: .standard,
        ).apply(to: &score)
        let document = Self.layout(score)
        let origin = try #require(document.harmonyOrigin(
            at: anchor, text: "Am7",
        ))
        let expected = try Self.harmonyElementOrigin(
            in: document, text: "Am7",
        )

        #expect(origin == expected)
    }

    @Test func rehearsalMarkOriginIncludesTheFramePadding() throws {
        var score = Self.score()
        let anchor = Self.anchor(element: 0)
        _ = try SetRehearsalMark(
            measureIndex: 0, text: "A",
        ).apply(to: &score)
        let document = Self.layout(score)
        let origin = try #require(document.rehearsalMarkTextOrigin(
            at: anchor,
        ))
        let (rawOrigin, system) = try Self.rehearsalMarkElementOrigin(
            in: document,
        )
        let pad = RehearsalMarkFrame.paddingSp(sp: system.sp)

        #expect(origin == CGPoint(
            x: rawOrigin.x + pad,
            y: rawOrigin.y - pad,
        ))
    }

    private static func score() -> Score {
        let chord = VoiceElement.chord(Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
        ))
        return Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "piano"),
                staves: [Staff(measures: [Measure(voices: [Voice(
                    elements: [chord, chord],
                )])])],
            )],
        )
    }

    private static func layout(_ score: Score) -> LayoutDocument {
        LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 28),
            availableWidth: 800,
        )
    }

    private static func anchor(element: Int) -> VoiceElementID {
        VoiceElementID(
            staff: staff,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: element,
        )
    }

    private static func staffTextElementOrigin(
        in document: LayoutDocument,
        text: String,
        style: TextStyleType,
    ) throws -> CGPoint {
        let (system, measure) = try firstMeasure(in: document)
        let local = try #require(measure.elements.compactMap { element -> CGPoint? in
            guard case let .staffText(candidate, origin, _, candidateStyle) = element,
                  candidate == text,
                  candidateStyle == style
            else { return nil }
            return origin
        }.first)
        return absolute(local, system: system, measure: measure)
    }

    private static func harmonyElementOrigin(
        in document: LayoutDocument,
        text: String,
    ) throws -> CGPoint {
        let (system, measure) = try firstMeasure(in: document)
        let harmony = try #require(measure.elements.compactMap { element -> LayoutHarmony? in
            guard case let .harmony(candidate) = element,
                  candidate.harmony.name == text
            else { return nil }
            return candidate
        }.first)
        return absolute(
            CGPoint(
                x: CGFloat(harmony.anchorX),
                y: CGFloat(harmony.y),
            ),
            system: system,
            measure: measure,
        )
    }

    private static func rehearsalMarkElementOrigin(
        in document: LayoutDocument,
    ) throws -> (CGPoint, LayoutSystem) {
        let (system, measure) = try firstMeasure(in: document)
        let local = try #require(measure.elements.compactMap { element -> CGPoint? in
            guard case let .rehearsalMark(_, origin, _, _) = element
            else { return nil }
            return origin
        }.first)
        return (absolute(local, system: system, measure: measure), system)
    }

    private static func firstMeasure(
        in document: LayoutDocument,
    ) throws -> (LayoutSystem, LayoutMeasure) {
        let system = try #require(document.systems.first)
        let measure = try #require(system.measures.first)
        return (system, measure)
    }

    private static func absolute(
        _ local: CGPoint,
        system: LayoutSystem,
        measure: LayoutMeasure,
    ) -> CGPoint {
        CGPoint(
            x: system.origin.x + measure.origin.x + local.x,
            y: system.origin.y + measure.origin.y + local.y,
        )
    }
}
