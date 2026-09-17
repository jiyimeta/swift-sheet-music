@testable import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, SheetMusicCore and SheetMusicLayout both export portable
    /// `CGFloat` / `CGPoint` shims, so anchor explicitly to SheetMusicLayout's definitions.
    ///
    /// `private typealias` keeps these file-scoped — a module-scope alias here would collide
    /// with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// A glissando as a selectable item: the identity the layout stamps on every drawn half, the clicks the line and
/// its label take (and the ones the noteheads keep), the boxes a host anchors a popover to, and the command that
/// removes it.
@Suite("A glissando line is a selectable item")
struct GlissandoSelectionTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let staff1 = StaffAddress(partIndex: 0, staffIndexInPart: 1)

    private static func start(_ staff: StaffAddress = staff0) -> NoteID {
        NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)
    }

    /// One bar: C4 sweeping into G4, both half notes so the line between them is long enough to read.
    private static func voice(_ glissando: Glissando?) -> Voice {
        Voice(elements: [
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14, glissando: glissando)])),
            .chord(Chord(duration: .half, notes: [Note(pitch: 67, tpc: 15)])),
        ])
    }

    private static func score(
        _ glissando: Glissando? = Glissando(visualType: .straight), staves: Int = 1,
    ) -> Score {
        Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "x"),
            staves: IdentifiedArray(Array(
                repeating: Staff(measures: [Measure(voices: [voice(glissando)])]), count: staves,
            )),
        )])
    }

    /// Two whole-note bars two octaves apart, wrapped onto two systems: the glissando is split into a BEGIN and an
    /// END half, one per system. Same shape as `GlissandoLayoutEmissionTests`' cross-system fixture.
    private static func splitScore() -> Score {
        let a = Note(pitch: 60, tpc: 14, glissando: Glissando(visualType: .straight))
        let b = Note(pitch: 84, tpc: 14)
        return Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "x"),
            staves: [Staff(measures: [
                Measure(voices: [Voice(elements: [.chord(Chord(duration: .whole, notes: [a]))])]),
                Measure(voices: [Voice(elements: [.chord(Chord(duration: .whole, notes: [b]))])]),
            ])],
        )])
    }

    private static func layout(_ score: Score, split: Bool = false) -> LayoutDocument {
        LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(wrapToViewWidth: split),
            availableWidth: split ? 200 : 800,
        )
    }

    /// Every drawn glissando half, with its endpoints already in document coordinates.
    private static func lines(
        _ document: LayoutDocument,
    ) -> [(id: ScoreElementID?, from: CGPoint, to: CGPoint)] {
        document.systems.flatMap { system in
            system.spanners.compactMap { element in
                guard case let .glissandoLine(from, to, _, _, _) = element else { return nil }
                return (
                    element.elementID,
                    CGPoint(x: system.origin.x + from.x, y: system.origin.y + from.y),
                    CGPoint(x: system.origin.x + to.x, y: system.origin.y + to.y),
                )
            }
        }
    }

    private static func midpoint(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
        CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
    }

    /// Document-space center of the notehead at `elementIndex`, the point a click aimed at the note lands on.
    private static func notehead(_ document: LayoutDocument, elementIndex: Int) -> CGPoint? {
        for system in document.systems {
            for measure in system.measures {
                for element in measure.elements {
                    guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element,
                          let note = notes.first, note.noteID.elementIndex == elementIndex
                    else { continue }
                    return CGPoint(
                        x: system.origin.x + measure.origin.x + note.origin.x,
                        y: system.origin.y + measure.origin.y + note.origin.y,
                    )
                }
            }
        }
        return nil
    }

    // MARK: - Layout identity

    @Test("A drawn glissando names the note it is stored on")
    func layoutCarriesStartingNote() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let lines = Self.lines(Self.layout(Self.score()))
        #expect(lines.count == 1)
        #expect(lines.first?.id == .glissando(start: Self.start()))
    }

    @Test("Both halves of a glissando split across a system break carry the one identity")
    func splitHalvesShareOneIdentity() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let document = Self.layout(Self.splitScore(), split: true)
        #expect(document.systems.count == 2)
        let expected = ScoreElementID.glissando(start: Self.start())
        #expect(document.systems.allSatisfy { system in
            system.spanners.filter { if case .glissandoLine = $0 { true } else { false } }.count == 1
        })
        let lines = Self.lines(document)
        try #require(lines.count == 2)
        #expect(lines.allSatisfy { $0.id == expected })
        // One rect per drawn half, each around its own half — a host anchors a popover to the half that was hit.
        let tester = ScoreHitTester(document: document)
        let rects = tester.elementHitRects(for: ScoreHitTarget(elementID: expected))
        try #require(rects.count == 2)
        for (index, line) in lines.enumerated() {
            #expect(rects[index].contains(Self.midpoint(line.from, line.to)))
        }
        // Their union spans the break, which is why a host is given the pieces rather than the envelope.
        let union = try #require(tester.elementHitRect(for: ScoreHitTarget(elementID: expected)))
        #expect(union.height > rects[0].height + rects[1].height)
    }

    // MARK: - Hit testing

    @Test("A click on the line selects the glissando, in every shape the hit surface answers with")
    func clickOnTheLine() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let document = Self.layout(Self.score())
        let line = try #require(Self.lines(document).first)
        let point = Self.midpoint(line.from, line.to)
        let tester = ScoreHitTester(document: document)
        let expected = ScoreElementID.glissando(start: Self.start())
        let target = try #require(tester.hitTest(at: point))
        #expect(target == .glissando(start: Self.start()))
        #expect(target.elementID == expected)
        #expect(target.textID == nil)
        #expect(target.selectableItem == .element(expected))
        #expect(tester.itemID(at: point) == .element(expected))
        let rects = tester.elementHitRects(for: target)
        #expect(rects.count == 1)
        #expect(try #require(tester.elementHitRect(for: target)).contains(point))
    }

    @Test("A click on either notehead still selects the note, not the line between them", arguments: [0, 1])
    func noteheadsKeepTheirClicks(_ elementIndex: Int) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let document = Self.layout(Self.score())
        let point = try #require(Self.notehead(document, elementIndex: elementIndex))
        let note = NoteID(
            staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: elementIndex, noteIndexInChord: 0,
        )
        #expect(ScoreHitTester(document: document).hitTest(at: point) == .note(note))
    }

    /// Hand-built geometry so the distances are exact: sp = 10, and the line is a 45° diagonal.
    private static func spanner(
        from: CGPoint, to: CGPoint, wavy: Bool = false, text: String? = nil,
    ) -> LayoutElement {
        .glissandoLine(fromOrigin: from, toOrigin: to, wavy: wavy, text: text, start: start())
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func tester(_ elements: [LayoutElement]) -> ScoreHitTester {
        ScoreHitTester(document: ElementHitFixtures.document([], spanners: elements))
    }

    @Test("The reach is measured from the line, not from the box around it")
    func distanceNotBoundingBox() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // System origin is (30, 40); the segment runs from (70, 100) to (170, 200) in document space.
        let tester = Self.tester([Self.spanner(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 140, y: 160))])
        let target = ScoreHitTarget.glissando(start: Self.start())
        let mid = CGPoint(x: 120, y: 150)
        #expect(tester.hitTest(at: mid) == target)
        // ±6 points across the line (0.6 sp) is inside the 0.7 sp reach; ±8 is outside it.
        let step = (6 / CGFloat(2).squareRoot()).rounded(.towardZero)
        #expect(tester.hitTest(at: CGPoint(x: mid.x + step, y: mid.y - step)) == target)
        #expect(tester.hitTest(at: CGPoint(x: mid.x - step, y: mid.y + step)) == target)
        let past = 8 / CGFloat(2).squareRoot()
        #expect(tester.hitTest(at: CGPoint(x: mid.x + past, y: mid.y - past)) == nil)
        // Deep inside the segment's bounding box, 63 points from the line itself.
        #expect(tester.hitTest(at: CGPoint(x: 165, y: 105)) == nil)
    }

    @Test("The label takes the clicks aimed at it, and only where one is drawn", arguments: [false, true])
    func labelTakesItsOwnClicks(_ labeled: Bool) {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let text = labeled ? "gliss." : nil
        let long = Self.tester([Self.spanner(
            from: CGPoint(x: 40, y: 100), to: CGPoint(x: 240, y: 100), text: text,
        )])
        // 10 points above the line's middle: past the line's own 7-point reach, inside the label's ink.
        let overLabel = CGPoint(x: 170, y: 130)
        #expect(long.hitTest(at: overLabel) == (labeled ? .glissando(start: Self.start()) : nil))
        #expect(long.hitTest(at: CGPoint(x: 170, y: 140)) == .glissando(start: Self.start()))
        // A line shorter than the label is drawn without it — MuseScore's own width gate — so it claims nothing.
        let short = Self.tester([Self.spanner(
            from: CGPoint(x: 40, y: 100), to: CGPoint(x: 50, y: 100), text: text,
        )])
        #expect(short.hitTest(at: CGPoint(x: 75, y: 130)) == nil)
    }

    @Test("A wavy line is measured from the wiggle's ink, which is wider than a stroke")
    func wavyLineUsesItsGlyphInk() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let from = CGPoint(x: 40, y: 100)
        let to = CGPoint(x: 240, y: 100)
        let target = ScoreHitTarget.glissando(start: Self.start())
        let straight = Self.tester([Self.spanner(from: from, to: to)])
        let wavy = Self.tester([Self.spanner(from: from, to: to, wavy: true)])
        #expect(wavy.hitTest(at: CGPoint(x: 170, y: 140)) == target)
        let straightBox = try #require(straight.elementHitRect(for: target))
        let wavyBox = try #require(wavy.elementHitRect(for: target))
        #expect(wavyBox.height > straightBox.height)
        // The wiggle run is centered and fits whole glyphs, so it covers at most the line and never more.
        #expect(wavyBox.width <= straightBox.width)
        #expect(wavyBox.width > straightBox.width / 2)
        // **The band reaches the line it is drawn on.** The glyph is placed by its text band, the same anchor
        // `glyphInkRects` measures every other glyph with, and against Bravura's wiggle that puts the ink just
        // above the line and touching it. A band anchored anywhere else — on the baseline, say — would still
        // report a taller box while sitting clear of the line it is supposed to be drawn along.
        #expect(wavyBox.minY < 140)
        #expect(wavyBox.maxY >= 140)
        #expect(wavyBox.maxY < 140 + wavyBox.height)
    }

    /// A straight stroke has real thickness, and the rect a host anchors to must carry it: a zero-height rectangle
    /// contains no point at all, so `CGRect.contains` would answer false for every click on a horizontal line.
    @Test("A horizontal stroke's hit rect is as tall as the stroke is drawn")
    func straightLineHitRectCarriesItsStroke() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let target = ScoreHitTarget.glissando(start: Self.start())
        let straight = Self.tester([Self.spanner(
            from: CGPoint(x: 40, y: 100), to: CGPoint(x: 240, y: 100),
        )])
        let box = try #require(straight.elementHitRect(for: target))
        #expect(box.height > 0)
        // The document places this system at (30, 40), so the line is drawn at y = 140.
        #expect(box.contains(CGPoint(x: 170, y: 140)))
    }

    /// A wavy line fits whole wiggle glyphs and centers them, so one shorter than a single glyph draws nothing at
    /// all. Blank paper takes no clicks — the reason this hit test measures ink rather than a bounding box.
    @Test("A wavy line too short for one wiggle is not hittable")
    func wavyLineShorterThanOneGlyphIsNotHittable() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let tester = Self.tester([Self.spanner(
            from: CGPoint(x: 40, y: 100), to: CGPoint(x: 42, y: 100), wavy: true,
        )])
        #expect(tester.hitTest(at: CGPoint(x: 41, y: 100)) == nil)
        #expect(tester.elementHitRect(for: .glissando(start: Self.start())) == nil)
    }

    @Test("A line the layout left unnamed is not reported at all")
    func unnamedLineIsNotHittable() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let tester = Self.tester([.glissandoLine(
            fromOrigin: CGPoint(x: 40, y: 100), toOrigin: CGPoint(x: 240, y: 100), wavy: false, text: nil,
        )])
        #expect(tester.hitTest(at: CGPoint(x: 170, y: 140)) == nil)
    }

    // MARK: - Removal

    @Test("The identity resolves to the command that clears the note's glissando, and back")
    func removalClearsTheGlissando() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score()
        let before = score
        let document = Self.layout(score)
        let line = try #require(Self.lines(document).first)
        let target = try #require(ScoreHitTester(document: document).hitTest(at: Self.midpoint(line.from, line.to)))
        let id = try #require(target.elementID)
        let command = try #require(id.removalCommand)
        #expect(command.affectedLocation == VoiceElementID(Self.start()))
        let inverse = try command.apply(to: &score)
        #expect(score[Self.start()]?.glissando == nil)
        #expect(Self.lines(Self.layout(score)).isEmpty)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
        #expect(Self.lines(Self.layout(score)).first?.id == id)
    }

    // MARK: - Identity arithmetic

    @Test("The identity answers from its starting note, and names no bar or staff of its own")
    func identityPositions() {
        let id = ScoreElementID.glissando(start: Self.start())
        let item = ScoreItemID.element(id)
        #expect(id.anchor == VoiceElementID(Self.start()))
        #expect(id.measureIndexIfAddressedByBar == nil)
        #expect(id.staffIfAddressed == nil)
        #expect(item.staff == Self.staff0)
        #expect(item.measureIndex == 0)
        #expect(item.voiceIndex == 0)
        #expect(item.elementIndex == 0)
        #expect(item.textID == nil)
        #expect(item.elementID == id)
        // A hit target round-trips through the identity without a translation table.
        let target = ScoreHitTarget(elementID: id)
        #expect(target == .glissando(start: Self.start()))
        #expect(target.elementID == id)
        #expect(target.selectableItem == item)
        // Two notes of one chord carry two glissandi, and the identities stay apart.
        let sibling = ScoreElementID.glissando(start: NoteID(
            staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 1,
        ))
        #expect(sibling != id)
        #expect(ScoreHitTarget(elementID: sibling) != target)
    }

    @Test("Mapping voice slots moves the starting note with its chord")
    func mappingFollowsTheStartingNote() {
        let id = ScoreItemID.element(.glissando(start: Self.start()))
        let moved = id.mappingVoiceElements { location in
            VoiceElementID(
                staff: location.staff, measureIndex: location.measureIndex,
                voiceIndex: location.voiceIndex, elementIndex: location.elementIndex + 4,
            )
        }
        #expect(moved == .element(.glissando(start: NoteID(
            staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4, noteIndexInChord: 0,
        ))))
        #expect(id.mappingVoiceElements { _ in nil } == nil)
    }

    @Test("A tap on a filtered layout re-stamps the starting note onto the full-score staff, and back")
    func filteredStaffRestamp() {
        let score = Self.score(staves: 2)
        let hidden: Set<StaffAddress> = [Self.staff0]
        let full = ScoreCursor.item(.element(.glissando(start: Self.start(Self.staff1))))
        let filtered = ScoreCursor.item(.element(.glissando(start: Self.start(Self.staff0))))
        #expect(score.engineCursorForFilteredTap(filtered, hiddenStaves: hidden) == full)
        #expect(score.translateCursorForHiddenStaves(full, hiddenStaves: hidden) == filtered)
        #expect(score.engineCursorForFilteredTap(full, hiddenStaves: []) == full)
        #expect(score.translateCursorForHiddenStaves(full, hiddenStaves: []) == full)
    }
}
