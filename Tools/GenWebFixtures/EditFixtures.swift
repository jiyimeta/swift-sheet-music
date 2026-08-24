import Foundation
import SheetMusicCore
import SheetMusicLayout

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

#if !canImport(CoreGraphics)
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

extension GenWebFixtures {
    static let ptToMM = 25.4 / 72.0
    static let mmToPt = 72.0 / 25.4

    struct SampleEditExpectations: Encodable {
        let probes: [EditGeometryProbe]
    }

    struct EditGeometryProbe: Encodable {
        let xMM: Double
        let yMM: Double
        let activeVoice: Int
        let minimumWidthMM: Double
        let hit: ExpectedEditHit
        let caret: ExpectedCaretRect
    }

    struct ExpectedEditHit: Encodable {
        let kind: String
        let partIndex: Int
        let staffIndexInPart: Int
        let measureIndex: Int
        let voiceIndex: Int
        let elementIndex: Int
        let noteIndexInChord: Int
        let pitch: Int
        let tpc: Int
    }

    struct ExpectedCaretRect: Encodable {
        let xMM: Double
        let yMM: Double
        let widthMM: Double
        let heightMM: Double
    }

    static func makeSampleEditExpectations(score: Score, document: LayoutDocument) -> SampleEditExpectations {
        guard #available(macOS 15.0, *) else {
            fail("macOS 15 or newer required for edit hit-test expectations", code: 16)
        }
        guard let point = firstNoteAnchor(in: document),
              let hit = document.editingHitTest(at: point, activeVoice: 0)
        else {
            fail("could not find a sample edit hit-test probe", code: 13)
        }
        guard let expectedHit = expectedEditHit(from: hit, in: score) else {
            fail("sample edit probe resolved to an unsupported hit item", code: 14)
        }
        guard let caret = document.editingCaretRect(
            for: hit,
            in: score,
            minimumWidth: 3 * mmToPt,
        ) else {
            fail("could not compute a sample edit caret rect", code: 15)
        }

        return SampleEditExpectations(probes: [
            EditGeometryProbe(
                xMM: Double(point.x) * ptToMM,
                yMM: Double(point.y) * ptToMM,
                activeVoice: 0,
                minimumWidthMM: 3,
                hit: expectedHit,
                caret: expectedCaretRect(caret),
            ),
        ])
    }

    private static func firstNoteAnchor(in document: LayoutDocument) -> CGPoint? {
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

    private static func expectedEditHit(from item: ScoreItemID, in score: Score) -> ExpectedEditHit? {
        switch item {
        case let .note(id):
            let note = score[id]
            return ExpectedEditHit(
                kind: "note",
                partIndex: id.staff.partIndex,
                staffIndexInPart: id.staff.staffIndexInPart,
                measureIndex: id.measureIndex,
                voiceIndex: id.voiceIndex,
                elementIndex: id.elementIndex,
                noteIndexInChord: id.noteIndexInChord,
                pitch: note?.pitch ?? -1,
                tpc: note?.tpc ?? 0,
            )
        case let .rest(id):
            return ExpectedEditHit(
                kind: "rest",
                partIndex: id.staff.partIndex,
                staffIndexInPart: id.staff.staffIndexInPart,
                measureIndex: id.measureIndex,
                voiceIndex: id.voiceIndex,
                elementIndex: id.elementIndex,
                noteIndexInChord: -1,
                pitch: -1,
                tpc: 0,
            )
        case let .tuplet(id):
            return ExpectedEditHit(
                kind: "tuplet",
                partIndex: id.staff.partIndex,
                staffIndexInPart: id.staff.staffIndexInPart,
                measureIndex: id.measureIndex,
                voiceIndex: id.voiceIndex,
                elementIndex: id.startElementIndex,
                noteIndexInChord: -1,
                pitch: -1,
                tpc: 0,
            )
        default:
            return nil
        }
    }

    private static func expectedCaretRect(_ rect: CGRect) -> ExpectedCaretRect {
        ExpectedCaretRect(
            xMM: Double(rect.minX) * ptToMM,
            yMM: Double(rect.minY) * ptToMM,
            widthMM: Double(rect.width) * ptToMM,
            heightMM: Double(rect.height) * ptToMM,
        )
    }
}
