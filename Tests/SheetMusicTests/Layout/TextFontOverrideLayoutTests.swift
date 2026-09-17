#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// Core, Layout and Foundation each vend portable CG stand-ins off Apple; anchor to Layout's, file-scoped.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// A text's authored font override — face, size, style on `TextProperties` — must reach every place layout
/// MEASURES that text: its ink and hit rects, the skyline, and (for a lyric) the chord spacing it drives. And a
/// text that carries no such override must lay out exactly as before overrides were honored.
///
/// Written against the score model and the pre-existing layout API only, so the same file states the gap on a
/// tree that predates the fix: every "wider" expectation here failed there, because the override was stored and
/// never read.
@Suite("Text font overrides reach layout")
struct TextFontOverrideLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let metrics = StaffMetrics(staffSize: 28)
    private static let big = TextProperties(size: 24)

    // MARK: - Fixtures

    /// Two quarter chords whose lyrics are `lyric`; every lane text sits on the first beat.
    private static func score(
        lyric: TextProperties = TextProperties(),
        staffText: TextProperties = TextProperties(),
        rehearsal: RehearsalMark = RehearsalMark(text: "Chorus"),
        tempo: Tempo = Tempo(beatsPerSecond: 2),
    ) -> Score {
        func chord() -> VoiceElement {
            .chord(Chord(
                duration: .quarter, notes: ChordNotes([Note(pitch: 72, tpc: 14)]),
                lyrics: [Lyric(text: "Wonderful", properties: lyric)],
            ))
        }
        let lane: [PositionedSystemElement] = [
            PositionedSystemElement(position: .start, element: .tempo(tempo)),
            PositionedSystemElement(
                position: .start, element: .staffText(StaffText(text: "espressivo", properties: staffText)),
                originalStaff: staff,
            ),
            PositionedSystemElement(position: .start, element: .rehearsalMark(rehearsal)),
        ]
        return Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "voice"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: [
                chord(), chord(), .rest(duration: .half),
            ])])])],
        )], systemMeasures: [SystemMeasure(elements: lane)])
    }

    private static func layout(_ score: Score) -> LayoutDocument {
        LayoutEngine.layout(score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: 900)
    }

    private static func elements(_ document: LayoutDocument) -> [LayoutElement] {
        document.systems.flatMap(\.measures).flatMap(\.elements)
    }

    private static func lyrics(_ document: LayoutDocument) -> [LayoutElement] {
        elements(document).filter { if case .textMark(.lyrics, _, _) = $0 { true } else { false } }
    }

    private static func first(_ document: LayoutDocument, _ matches: (LayoutElement) -> Bool) throws -> LayoutElement {
        let found = elements(document).first(where: matches)
        return try #require(found)
    }

    /// Width of the union of an element's ink rects; records an issue and answers 0 when it has none.
    private static func inkWidth(_ element: LayoutElement) -> CGFloat {
        guard let rects = TextInkGeometry.rects(for: element, metrics: metrics), let first = rects.first else {
            Issue.record("no ink rects for \(element)")
            return 0
        }
        return rects.dropFirst().reduce(first) { $0.union($1) }.width
    }

    private static func isStaffText(_ element: LayoutElement) -> Bool {
        if case .staffText = element { true } else { false }
    }

    private static func isRehearsalMark(_ element: LayoutElement) -> Bool {
        if case .rehearsalMark = element { true } else { false }
    }

    private static func isTempo(_ element: LayoutElement) -> Bool {
        if case .textMark(.tempo, _, _) = element { true } else { false }
    }

    // MARK: - Lyrics

    @Test("a lyric's size override widens its ink and pushes the next syllable along")
    func lyricSizeReachesInkAndSpacing() throws {
        let plain = Self.layout(Self.score())
        let large = Self.layout(Self.score(lyric: Self.big))
        let plainLyrics = Self.lyrics(plain)
        let largeLyrics = Self.lyrics(large)
        try #require(plainLyrics.count == 2 && largeLyrics.count == 2)
        #expect(Self.inkWidth(largeLyrics[0]) > Self.inkWidth(plainLyrics[0]) * 1.5)

        func gap(_ pair: [LayoutElement]) -> CGFloat {
            guard case let .textMark(_, _, left) = pair[0], case let .textMark(_, _, right) = pair[1] else { return 0 }
            return right.x - left.x
        }
        #expect(gap(largeLyrics) > gap(plainLyrics))
    }

    // MARK: - Lane texts

    @Test("a staff text's size override widens its ink rect")
    func staffTextSizeReachesInk() throws {
        let plain = try Self.first(Self.layout(Self.score()), Self.isStaffText)
        let large = try Self.first(Self.layout(Self.score(staffText: Self.big)), Self.isStaffText)
        #expect(Self.inkWidth(large) > Self.inkWidth(plain) * 1.5)
    }

    @Test("a rehearsal mark's size override widens its letters and the frame around them")
    func rehearsalSizeReachesInkAndFrame() throws {
        let plain = try Self.first(Self.layout(Self.score()), Self.isRehearsalMark)
        let large = try Self.first(
            Self.layout(Self.score(rehearsal: RehearsalMark(text: "Chorus", properties: Self.big))),
            Self.isRehearsalMark,
        )
        #expect(Self.inkWidth(large) > Self.inkWidth(plain) * 1.2)
    }

    @Test("an authored frameType is drawn while the mark's own frame is the default, as the encoder saves it")
    func rehearsalFrameTypeFollowsTheEncoderRule() throws {
        func rects(_ mark: RehearsalMark) throws -> [CGRect] {
            let element = try Self.first(Self.layout(Self.score(rehearsal: mark)), Self.isRehearsalMark)
            return try #require(TextInkGeometry.rects(for: element, metrics: Self.metrics))
        }
        let circled = try rects(RehearsalMark(text: "Chorus", frame: .circle))
        let authored = try rects(RehearsalMark(
            text: "Chorus", frame: .rectangle, properties: TextProperties(frameType: .circle),
        ))
        let boxed = try rects(RehearsalMark(text: "Chorus", frame: .rectangle))
        #expect(authored == circled)
        #expect(authored != boxed)
        // A mark whose own frame is not the default keeps it: that is the frame a save writes.
        let unframed = try rects(RehearsalMark(
            text: "Chorus", frame: .none, properties: TextProperties(frameType: .circle),
        ))
        let unframedByItsOwnFrame = try rects(RehearsalMark(text: "Chorus", frame: .none))
        #expect(unframed == unframedByItsOwnFrame)
    }

    @Test("a tempo marking's size override widens its ink rects")
    func tempoSizeReachesInk() throws {
        let plain = try Self.first(Self.layout(Self.score()), Self.isTempo)
        let large = try Self.first(
            Self.layout(Self.score(tempo: Tempo(beatsPerSecond: 2, properties: Self.big))), Self.isTempo,
        )
        #expect(Self.inkWidth(large) > Self.inkWidth(plain) * 1.5)
    }

    // MARK: - No override, no change

    /// The hard constraint. Frame fields are not a font override, so a score carrying only those lays out
    /// identically to one carrying nothing — every origin, width and element.
    @Test("frame-only properties take the unoverridden path and lay out identically")
    func frameOnlyPropertiesChangeNothing() {
        let padding = TextProperties(framePadding: 0.75)
        let plain = Self.layout(Self.score())
        let framed = Self.layout(Self.score(
            lyric: padding,
            staffText: TextProperties(frameType: .rectangle, framePadding: 0.75),
            rehearsal: RehearsalMark(text: "Chorus", properties: padding),
            tempo: Tempo(beatsPerSecond: 2, properties: padding),
        ))
        #expect(framed == plain)
    }
}
