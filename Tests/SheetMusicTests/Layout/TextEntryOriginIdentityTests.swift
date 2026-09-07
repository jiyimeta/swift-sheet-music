#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// Same ambiguity, same fix, as `LayoutDocumentTextEntryOriginTests` — see the note there.
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// What the text-and-proximity lookup could not do: tell two marks apart when they print the same string.
///
/// The origins these accessors return address a caret at a specific engraved glyph, so answering with the
/// neighbouring one is a visible bug — the caret lands on a mark the user is not editing. Identity carried from
/// emission (`LayoutElement.staffText`'s `anchor`, `LayoutHarmony.anchor`, `.rehearsalMark`'s `measureIndex`) is
/// what makes the answer unique.
@Suite("Text entry origin identity")
struct TextEntryOriginIdentityTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// Two staff texts with the SAME string in one bar resolve to their own origins, not to whichever one is
    /// nearer the anchor. First and last slot of the bar, so a wrong answer is unmistakable rather than a
    /// rounding difference.
    @Test func identicalStaffTextsInOneBarResolveSeparately() throws {
        var score = EditingFixtures.fourQuarterRests()
        let first = Self.anchor(element: 1)
        let last = Self.anchor(element: 4)
        _ = try SetStaffText(anchor: first, text: "solo", isSystemText: false).apply(to: &score)
        _ = try SetStaffText(anchor: last, text: "solo", isSystemText: false).apply(to: &score)

        let document = Self.layout(score)
        let a = try #require(document.staffTextOrigin(at: first, style: .staffText))
        let b = try #require(document.staffTextOrigin(at: last, style: .staffText))

        #expect(a.x < b.x)
    }

    /// The case proximity got wrong rather than merely got lucky on: an author `<offset x>` drags the mark on
    /// beat 1 to the RIGHT of the mark on beat 2, so ranking equal-text candidates by distance from the anchor
    /// hands beat 1's caret its neighbour's glyph — and hands both anchors the same point. Identity puts each
    /// caret on its own mark, and beat 1's engraved x is then the larger of the two.
    @Test func anOffsetTextDoesNotStealItsNeighboursCaret() throws {
        var score = EditingFixtures.fourQuarterRests()
        let first = Self.anchor(element: 1)
        let second = Self.anchor(element: 2)
        _ = try SetStaffText(anchor: first, text: "solo", isSystemText: false).apply(to: &score)
        _ = try SetStaffText(anchor: second, text: "solo", isSystemText: false).apply(to: &score)
        for index in score.systemMeasures[0].elements.indices
            where score.systemMeasures[0].elements[index].position == .start
        {
            guard case var .staffText(text) = score.systemMeasures[0].elements[index].element else { continue }
            text.offsetX = 50
            score.systemMeasures[0].elements[index].element = .staffText(text)
        }

        let document = Self.layout(score)
        let a = try #require(document.staffTextOrigin(at: first, style: .staffText))
        let b = try #require(document.staffTextOrigin(at: second, style: .staffText))

        #expect(a.x > b.x)
    }

    /// The same for chord symbols: two "Am7"s in one bar are two symbols, and each anchor answers with its own.
    ///
    /// The anchors are re-derived after the writes because a chord symbol is a voice element — `SetChordSymbol`
    /// inserts it immediately before the element it names, which shifts every later index by one.
    @Test func identicalChordSymbolsInOneBarResolveSeparately() throws {
        var score = EditingFixtures.fourQuarterRests()
        _ = try SetChordSymbol(at: Self.anchor(element: 4), name: "Am7").apply(to: &score)
        _ = try SetChordSymbol(at: Self.anchor(element: 1), name: "Am7").apply(to: &score)
        let rests = score.parts[0].staves[0].measures[0].voices[0]
            .elements.indices.filter { score.parts[0].staves[0].measures[0].voices[0].elements[$0].isRest }
        let first = try Self.anchor(element: #require(rests.first))
        let last = try Self.anchor(element: #require(rests.last))

        let document = Self.layout(score)
        let a = try #require(document.harmonyOrigin(at: first))
        let b = try #require(document.harmonyOrigin(at: last))

        #expect(a.x < b.x)
    }

    /// A rehearsal mark resolves against the bar it is on, so a document holding several does not answer with
    /// the first one every time.
    @Test func rehearsalMarkResolvesPerMeasure() throws {
        var score = EditingFixtures.twoMeasuresOfQuarterRests(key: 0)
        _ = try SetRehearsalMark(measureIndex: 0, text: "A").apply(to: &score)
        _ = try SetRehearsalMark(measureIndex: 1, text: "B").apply(to: &score)

        let document = Self.layout(score)
        let a = try #require(document.rehearsalMarkTextOrigin(
            at: VoiceElementID(
                staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2,
            ),
        ))
        let b = try #require(document.rehearsalMarkTextOrigin(
            at: VoiceElementID(
                staff: EditingFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0,
            ),
        ))

        #expect(a != b)
    }

    /// A `<Swing>` marking prints through the `.staffText` layout case but is not a staff text: it carries no
    /// anchor, so a caret opened on a staff text at the same beat cannot resolve to it. Without this, the two
    /// styles alone would not tell them apart.
    @Test func swingMarkingIsNotAStaffTextCandidate() throws {
        var score = EditingFixtures.fourQuarterRests()
        let anchor = Self.anchor(element: 1)
        score.systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(
                position: .start,
                element: .swing(Swing(text: "Swing", isSystemText: false)),
            ),
        ])]
        _ = try SetStaffText(anchor: anchor, text: "Swing", isSystemText: false).apply(to: &score)

        let document = Self.layout(score)
        _ = try #require(document.staffTextOrigin(at: anchor, style: .staffText))
        var anchors: [VoiceElementID?] = []
        for system in document.systems {
            for measure in system.measures {
                for element in measure.elements {
                    if case let .staffText(_, _, _, _, candidate) = element {
                        anchors.append(candidate)
                    }
                }
            }
        }

        // Both print "Swing" at the same beat in the same style; exactly one of them is the addressable mark.
        #expect(anchors.count == 2)
        #expect(anchors.compactMap(\.self) == [anchor])
    }

    /// The narrower-identity limit, dimension 1, pinned: a lane mark has no voice, layout must still name one,
    /// and it names the lowest-numbered voice with a chord or rest at that beat. Anchoring the write from voice
    /// 2 does not make the mark voice 2's — the voice-1 anchor is the one that answers, and voice 2's returns
    /// `nil`, which for a non-empty editor means no caret at all.
    ///
    /// Change this expectation only by making the miss ANSWER, never by making it answer with a different
    /// mark's origin.
    @Test func aLaneMarkIsFoundOnlyThroughItsLowestNumberedVoice() throws {
        var score = EditingFixtures.parityFixture()
        // Bar 1 of staff (0,0) is the fixture's two-voice bar: voice 1 holds four quarter rests, voice 2 a
        // single measure rest. Both start at the bar's downbeat, so the beat is genuinely shared.
        let secondVoice = VoiceElementID(
            staff: EditingFixtures.staff0, measureIndex: 1, voiceIndex: 1, elementIndex: 0,
        )
        let firstVoice = VoiceElementID(
            staff: EditingFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0,
        )
        _ = try SetStaffText(anchor: secondVoice, text: "pizz.", isSystemText: false).apply(to: &score)

        let document = Self.layout(score)

        #expect(document.staffTextOrigin(at: firstVoice, style: .staffText) != nil)
        #expect(document.staffTextOrigin(at: secondVoice, style: .staffText) == nil)
    }

    /// The narrower-identity limit, dimension 2, pinned: `SetStaffText` writes a system text with no staff, and
    /// a staff-less lane element is engraved on the canonical staff only — one glyph carrying a staff-(0,0)
    /// anchor. So the part-1 anchor that WROTE the mark cannot find it again, while a canonical-staff anchor at
    /// the same beat can.
    ///
    /// This is the case a multi-part score hits constantly, and the one a beat-shaped identity would fix.
    @Test func aSystemTextIsFoundOnlyThroughTheCanonicalStaff() throws {
        var score = EditingFixtures.parityFixture()
        // Staff (1,0) bar 0 is [timeSignature, measure rest]; element 1 is the rest, on the downbeat.
        let secondPart = VoiceElementID(
            staff: StaffAddress(partIndex: 1, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )
        // Staff (0,0) bar 0 is [timeSignature, C4, D4, rest, rest]; element 1 is the chord on the same downbeat.
        let canonical = VoiceElementID(
            staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )
        _ = try SetStaffText(anchor: secondPart, text: "rit.", isSystemText: true).apply(to: &score)

        let document = Self.layout(score)

        #expect(document.staffTextOrigin(at: canonical, style: .systemText) != nil)
        #expect(document.staffTextOrigin(at: secondPart, style: .systemText) == nil)
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
            staff: EditingFixtures.staff0,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: element,
        )
    }
}
