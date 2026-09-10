import SheetMusicCore
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

/// Identities are positional: removal renumbers later entries; hosts must drop or re-derive a held selection.
@Suite("Real layout hit to removal command")
struct ScoreHitTesterRemovalTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = RemovalRoundTripFixtures

    @Test(
        "Either split tie half removes both links on the right full-score staff",
        arguments: [false, true],
        [0, 1],
    )
    func splitTie(_ filtered: Bool, _ half: Int) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = F.tie(filtered: filtered)
        let before = score
        let document = Self.layout(score, filtered: filtered)
        #expect(document.systems.count == 2)
        let selected = ScoreElementID.tie(start: F.note(0), end: F.note(1))
        let arcs = document.systems.flatMap(\.spanners).filter { $0.elementID == selected }
        try #require(arcs.count == 2)
        let point = try Self.arcPoint(document, id: selected, segment: half)
        let owner = filtered ? F.fullOwner : F.canonical
        let expectedID = ScoreElementID.tie(start: F.note(0, staff: owner), end: F.note(1, staff: owner))
        let inverse = try Self.remove(
            at: point,
            in: document,
            expected: selected,
            fullID: expectedID,
            filtered: filtered,
            score: &score,
        )
        #expect(score[F.note(0, staff: owner)]?.tieForward == nil)
        #expect(score[F.note(1, staff: owner)]?.tieBack == nil)
        var expected = before
        _ = try RemoveTie(start: F.note(0, staff: owner), end: F.note(1, staff: owner)).apply(to: &expected)
        #expect(score == expected)
        let after = Self.layout(score, filtered: filtered)
        #expect(Self.elements(after).allSatisfy { $0.elementID != selected })
        let neighbor = ScoreElementID.jump(staff: F.canonical, measureIndex: 1, index: 0)
        #expect(Self.elements(document).filter { $0.elementID == neighbor }.count == 1)
        #expect(Self.elements(after).filter { $0.elementID == neighbor }.count == 1)
        try Self.undo(inverse, score: &score, before: before, document: document, filtered: filtered)
    }

    @Test("Click either chord slur; content survives with the correct ordinal", arguments: [0, 1])
    func chordSlurs(_ ordinal: Int) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = F.slurs(standalone: false)
        let before = score
        let document = Self.layout(score)
        let selected = ScoreElementID.slur(.chord(anchor: F.slot(0), ordinal: ordinal))
        let removed = ordinal == 0 ? F.shortSlur : F.longSlur
        let survivor = ordinal == 0 ? F.longSlur : F.shortSlur
        #expect(Self.slurIDs(document, score: score, content: removed) == [selected])
        let point = try Self.arcPoint(document, id: selected)
        let inverse = try Self.remove(at: point, in: document, expected: selected, fullID: selected, score: &score)
        guard case var .chord(head) = before[F.slot(0)] else { Issue.record("expected chord"); return }
        head.spanners = [survivor]
        var expected = before
        expected[F.slot(0)] = .chord(head)
        #expect(score == expected)
        let after = Self.layout(score)
        #expect(Self.slurIDs(after, score: score, content: removed).isEmpty)
        // Removing ordinal 0 shifts old ordinal 1 to 0; removing 1 leaves old 0 unchanged.
        #expect(Self.slurIDs(after, score: score, content: survivor)
            == [.slur(.chord(anchor: F.slot(0), ordinal: 0))])
        try Self.undo(inverse, score: &score, before: before, document: document)
    }

    @Test("Standalone slur removal shifts the later slur slot from 3 to 2")
    func standaloneSlur() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = F.slurs(standalone: true)
        let before = score
        let document = Self.layout(score)
        let selected = ScoreElementID.slur(.voice(F.slot(0)))
        guard case let .spanner(later) = before[F.slot(3)] else { Issue.record("expected later slur"); return }
        #expect(Self.slurIDs(document, score: score, content: F.longSlur) == [selected])
        #expect(Self.slurIDs(document, score: score, content: later) == [.slur(.voice(F.slot(3)))])
        let point = try Self.arcPoint(document, id: selected)
        let inverse = try Self.remove(at: point, in: document, expected: selected, fullID: selected, score: &score)
        let old = before.parts[0].staves[0].measures[0].voices[0].elements
        #expect(score.parts[0].staves[0].measures[0].voices[0].elements.values == Array(old.dropFirst()))
        var expected = before
        expected.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[0].elements.removeSubrange(0 ..< 1)
            }
        }
        #expect(score == expected)
        #expect(score[F.slot(2)] == .spanner(later))
        let after = Self.layout(score)
        #expect(Self.slurIDs(after, score: score, content: F.longSlur).isEmpty)
        #expect(Self.slurIDs(after, score: score, content: later) == [.slur(.voice(F.slot(2)))])
        try Self.undo(inverse, score: &score, before: before, document: document)
    }

    @Test(
        "First-emitted navigation mark is removed; its survivor takes index zero",
        arguments: [false, true],
        [false, true],
    )
    func navigation(_ marker: Bool, _ filtered: Bool) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = F.navigation(filtered: filtered)
        let before = score
        let document = Self.layout(score, filtered: filtered)
        let selected: ScoreElementID = marker
            ? .marker(staff: F.canonical, measureIndex: 0, index: 0)
            : .jump(staff: F.canonical, measureIndex: 0, index: 0)
        let rect = try #require(ScoreHitTester(document: document)
            .elementHitRect(for: ScoreHitTarget(elementID: selected)))
        try #require(rect.width > 0 && rect.height > 0)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let owner = filtered ? F.fullOwner : F.canonical
        let fullID: ScoreElementID = marker
            ? .marker(staff: owner, measureIndex: 0, index: 0)
            : .jump(staff: owner, measureIndex: 0, index: 0)
        let inverse = try Self.remove(
            at: point,
            in: document,
            expected: selected,
            fullID: fullID,
            filtered: filtered,
            score: &score,
        )
        var expected = before
        let ref = MeasureRef(measureIndex: 0)
        var bar = try #require(expected[measure: ref, staff: owner])
        if marker { bar.markers = [bar.markers[1]] } else { bar.jumps = [bar.jumps[1]] }
        expected[measure: ref, staff: owner] = bar
        #expect(score == expected)
        let after = Self.elements(Self.layout(score, filtered: filtered))
        if marker {
            #expect(after.compactMap { element -> ScoreElementID? in
                if case let .marker(.coda, _, _, id) = element { return id }; return nil
            } == [selected])
            #expect(!after.contains { if case .marker(.segno, _, _, _) = $0 { true } else { false } })
            let prior = Self.elements(document).filter { if case .jump = $0 { true } else { false } }
            #expect(after.filter { if case .jump = $0 { true } else { false } }.compactMap(\.elementID)
                == prior.compactMap(\.elementID))
        } else {
            #expect(after.compactMap { element -> ScoreElementID? in
                if case let .jump("D.C.", _, id) = element { return id }; return nil
            } == [selected])
            #expect(!after.contains { if case .jump("D.S.", _, _) = $0 { true } else { false } })
            let prior = Self.elements(document).filter { if case .marker = $0 { true } else { false } }
            #expect(after.filter { if case .marker = $0 { true } else { false } }.compactMap(\.elementID)
                == prior.compactMap(\.elementID))
        }
        try Self.undo(inverse, score: &score, before: before, document: document, filtered: filtered)
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func layout(_ score: Score, filtered: Bool = false) -> LayoutDocument {
        LayoutEngine.layout(
            score: filtered ? score.filtered(hidingStaves: F.hidden) : score,
            options: .init(),
            availableWidth: 1000,
        )
    }

    private static func elements(_ document: LayoutDocument) -> [LayoutElement] {
        document.systems.flatMap { system in
            system.spanners + system.measures.flatMap { $0.elements + $0.markers + $0.jumps }
        }
    }

    private static func slurIDs(_ document: LayoutDocument, score: Score, content: Spanner) -> [ScoreElementID] {
        elements(document).compactMap { element in
            guard case let .slur(id)? = element.elementID else { return nil }
            let candidate: Spanner?
            switch id {
            case let .chord(anchor, ordinal):
                guard case let .chord(chord) = score[anchor] else { return nil }
                let slurs = chord.spanners.filter { $0.kind == .slur }
                candidate = slurs.indices.contains(ordinal) ? slurs[ordinal] : nil
            case let .voice(anchor):
                guard case let .spanner(spanner) = score[anchor] else { return nil }
                candidate = spanner
            }
            return candidate == content ? element.elementID : nil
        }
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func remove(
        at point: CGPoint,
        in document: LayoutDocument,
        expected: ScoreElementID,
        fullID: ScoreElementID,
        filtered: Bool = false,
        score: inout Score,
    ) throws -> any EditCommand {
        let target = try #require(ScoreHitTester(document: document).hitTest(at: point))
        #expect(target == ScoreHitTarget(elementID: expected))
        let item = try #require(target.selectableItem)
        #expect(item == .element(expected))
        let cursor = score.engineCursorForFilteredTap(.item(item), hiddenStaves: filtered ? F.hidden : [])
        guard case let .item(.element(id)) = cursor else { throw TestFailure.wrongCursor }
        #expect(id == fullID)
        return try ElementHitCommandChecks.remove(id, from: &score)
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func undo(
        _ inverse: any EditCommand,
        score: inout Score,
        before: Score,
        document: LayoutDocument,
        filtered: Bool = false,
    ) throws {
        #expect(score.stableFingerprint != before.stableFingerprint)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
        #expect(elements(layout(score, filtered: filtered)).compactMap(\.elementID)
            == elements(document).compactMap(\.elementID))
    }

    private enum TestFailure: Error { case wrongCursor, missingArcPoint }

    @available(macOS 15.0, iOS 16.0, *)
    private static func arcPoint(_ document: LayoutDocument, id: ScoreElementID, segment: Int = 0) throws -> CGPoint {
        let arcs = document.systems.flatMap { system in
            system.spanners.filter { $0.elementID == id }.map { ($0, system.origin) }
        }
        try #require(arcs.indices.contains(segment))
        let (element, base) = arcs[segment]
        let controls: [CGPoint]
        switch element {
        case let .tieArc(from, to, above, _):
            let c = TieArcGeometry.controlPoints(
                from: from,
                to: to,
                above: above,
                heightSp: TieArcGeometry.shoulderHeightSp(tieLengthSp: abs(to.x - from.x) / document.metrics.sp),
                sp: document.metrics.sp,
            )
            controls = [c.p0, c.p1, c.p2, c.p3]
        case let .spannerSegment(.slur, from, to, _, _, _, _):
            controls = [from, SpannerGeometry.slurControlPoint(from: from, to: to, sp: document.metrics.sp), to]
        default: throw TestFailure.missingArcPoint
        }
        // de Casteljau evaluates points on the rendered centerline, never inside an enclosing box.
        // Try the midpoint first (cubic weights 1/8,3/8,3/8,1/8; quadratic 1/4,1/2,1/4),
        // then interior dyadic samples to avoid another arc or a higher-priority note at that point.
        let samples: [CGFloat] = [0.5] + (1 ..< 32).map { CGFloat($0) / 32 }
        let tester = ScoreHitTester(document: document)
        for t in samples {
            var row = controls
            while row.count > 1 {
                row = zip(row, row.dropFirst()).map { a, b in
                    CGPoint(x: (1 - t) * a.x + t * b.x, y: (1 - t) * a.y + t * b.y)
                }
            }
            let point = CGPoint(x: row[0].x + base.x, y: row[0].y + base.y)
            if tester.hitTest(at: point) == ScoreHitTarget(elementID: id) { return point }
        }
        throw TestFailure.missingArcPoint
    }
}
