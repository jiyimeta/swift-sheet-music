@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
@testable import SheetMusicWasmBridge
import Testing

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

#if !canImport(CoreGraphics)
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

@Suite("edit geometry entry points")
struct EditGeometryEntryTests {
    private static let ptToMM = 25.4 / 72.0

    @Test("editingHitTest returns note fields and editingCaretRect returns millimetres")
    func hitTestAndCaretRectForNote() throws {
        let handle = try Self.loadedHandle(score: SampleScore.score())
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297, options: Self.layoutOptions())
        let document = try #require(LayoutDocumentCache.value(for: Int64(handle)))
        let point = try #require(Self.noteAnchor(in: document))

        let hit = try #require(editingHitTest(
            handle: handle,
            xMM: Double(point.x) * Self.ptToMM,
            yMM: Double(point.y) * Self.ptToMM,
            activeVoice: 0,
        ))
        #expect(hit.kind == "note")
        #expect(hit.partIndex == 0)
        #expect(hit.staffIndexInPart == 0)
        #expect(hit.measureIndex == 0)
        #expect(hit.voiceIndex == 0)
        #expect(hit.elementIndex == 0)
        #expect(hit.noteIndexInChord == 0)
        #expect(hit.pitch == 60)
        #expect(hit.tpc == 14)

        let caret = try #require(editingCaretRect(
            handle: handle,
            kind: hit.kind,
            partIndex: hit.partIndex,
            staffIndexInPart: hit.staffIndexInPart,
            measureIndex: hit.measureIndex,
            voiceIndex: hit.voiceIndex,
            elementIndex: hit.elementIndex,
            noteIndexInChord: hit.noteIndexInChord,
            minimumWidthMM: 3,
        ))
        #expect(caret.widthMM >= 3)
        #expect(caret.heightMM > 0)
    }

    @Test("editingHitTest returns nil on empty paper")
    func hitTestMissReturnsNil() throws {
        let handle = try Self.loadedHandle(score: SampleScore.score())
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297, options: Self.layoutOptions())

        #expect(editingHitTest(handle: handle, xMM: 0, yMM: -500 * Self.ptToMM, activeVoice: 0) == nil)
    }

    @Test("editingHitTest and editingCaretRect use the cached hidden-staff set")
    func hitTestAndCaretUseCachedHiddenStaves() throws {
        let handle = try Self.loadedHandle(score: SampleScore.twoStaffScore())
        defer { releaseScore(handle: handle) }
        _ = computeLayout(
            handle: handle,
            pageWidthMM: 210,
            pageHeightMM: 297,
            options: Self.layoutOptions(hiddenStaves: [HiddenStaff(partIndex: 0, staffIndexInPart: 0)]),
        )
        let document = try #require(LayoutDocumentCache.value(for: Int64(handle)))
        let point = try #require(Self.noteAnchor(in: document))

        let hit = try #require(editingHitTest(
            handle: handle,
            xMM: Double(point.x) * Self.ptToMM,
            yMM: Double(point.y) * Self.ptToMM,
            activeVoice: 0,
        ))
        #expect(hit.kind == "note")
        #expect(hit.partIndex == 0)
        #expect(hit.staffIndexInPart == 1)
        #expect(hit.pitch == 48)

        let caret = editingCaretRect(
            handle: handle,
            kind: hit.kind,
            partIndex: hit.partIndex,
            staffIndexInPart: hit.staffIndexInPart,
            measureIndex: hit.measureIndex,
            voiceIndex: hit.voiceIndex,
            elementIndex: hit.elementIndex,
            noteIndexInChord: hit.noteIndexInChord,
            minimumWidthMM: 1,
        )
        #expect(caret != nil)
    }

    @Test("editingHitTest re-addresses tuplets past a hidden earlier staff")
    func hitTestTupletUsesFullScoreStaff() throws {
        let handle = try Self.loadedHandle(score: Self.tupletOnSecondStaffScore())
        defer { releaseScore(handle: handle) }
        _ = computeLayout(
            handle: handle,
            pageWidthMM: 210,
            pageHeightMM: 297,
            options: Self.layoutOptions(hiddenStaves: [HiddenStaff(partIndex: 0, staffIndexInPart: 0)]),
        )
        let document = try #require(LayoutDocumentCache.value(for: Int64(handle)))
        let point = try #require(Self.tupletAnchor(in: document))

        let hit = try #require(editingHitTest(
            handle: handle,
            xMM: Double(point.x) * Self.ptToMM,
            yMM: Double(point.y) * Self.ptToMM,
            activeVoice: 0,
        ))
        #expect(hit.kind == "tuplet")
        #expect(hit.partIndex == 0)
        #expect(hit.staffIndexInPart == 1)
        #expect(hit.measureIndex == 0)
        #expect(hit.voiceIndex == 0)
        #expect(hit.elementIndex == 1)
        #expect(hit.noteIndexInChord == -1)
        #expect(hit.pitch == -1)
        #expect(hit.tpc == 0)

        // Spec §7.1: a tuplet id carets like any other selectable item — the round-tripped full-score
        // fields must translate back past the hidden staff and anchor to the bracket's first member.
        let caret = try #require(editingCaretRect(
            handle: handle,
            kind: hit.kind,
            partIndex: hit.partIndex,
            staffIndexInPart: hit.staffIndexInPart,
            measureIndex: hit.measureIndex,
            voiceIndex: hit.voiceIndex,
            elementIndex: hit.elementIndex,
            noteIndexInChord: hit.noteIndexInChord,
            minimumWidthMM: 1,
        ))
        #expect(caret.widthMM >= 1)
        #expect(caret.heightMM > 0)
    }

    @Test("editingCaretRect rejects unknown kinds")
    func caretRectRejectsUnknownKind() throws {
        let handle = try Self.loadedHandle(score: SampleScore.score())
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297, options: Self.layoutOptions())

        #expect(editingCaretRect(
            handle: handle,
            kind: "clef",
            partIndex: 0,
            staffIndexInPart: 0,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
            noteIndexInChord: -1,
            minimumWidthMM: 1,
        ) == nil)
    }

    private static func loadedHandle(score: Score) throws -> Int {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: score)))
        #expect(handle != 0)
        return handle
    }

    private static func layoutOptions(hiddenStaves: [HiddenStaff] = []) -> LayoutOptions {
        LayoutOptions(
            layoutMode: 0,
            staffSize: 28,
            honorLayoutBreaks: true,
            collapseMultiMeasureRests: false,
            showsInvisibleElements: false,
            showsLyrics: true,
            transposeSemitones: 0,
            hiddenStaves: hiddenStaves,
            clefOverrides: [],
        )
    }

    private static func noteAnchor(in document: LayoutDocument) -> CGPoint? {
        guard let system = document.systems.first, let measure = system.measures.first else { return nil }
        let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
        for element in measure.elements {
            guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = element,
                  let note = notes.first
            else { continue }
            return CGPoint(
                x: base.x + note.origin.x + note.mirrorDx(stem: stem, sp: system.sp),
                y: base.y + note.origin.y,
            )
        }
        return nil
    }

    private static func tupletAnchor(in document: LayoutDocument) -> CGPoint? {
        guard let system = document.systems.first, let measure = system.measures.first else { return nil }
        let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
        for element in measure.elements {
            guard case let .tupletLabel(from, to, _, _, _, tupletID) = element,
                  tupletID != nil
            else { continue }
            return CGPoint(x: base.x + (from.x + to.x) / 2, y: base.y + (from.y + to.y) / 2)
        }
        return nil
    }

    private static func tupletOnSecondStaffScore() -> Score {
        let hiddenVoice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 48, tpc: 14)])),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
        let third = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))
        let visibleVoice = Voice(
            elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: third, notes: [Note(pitch: 60, tpc: 14)])),
                .chord(Chord(duration: third, notes: [Note(pitch: 62, tpc: 16)])),
                .chord(Chord(duration: third, notes: [Note(pitch: 64, tpc: 18)])),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
            ],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)],
        )
        return Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "piano", longName: "Piano"),
                staves: [
                    Staff(measures: [Measure(voices: [hiddenVoice])]),
                    Staff(measures: [Measure(voices: [visibleVoice])]),
                ],
            )],
            metaTags: ["workTitle": "wasm tuplet geometry", "composer": "test"],
        )
    }
}
