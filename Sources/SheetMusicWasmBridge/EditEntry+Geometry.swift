import JavaScriptKit
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

#if !canImport(CoreGraphics)
    /// `FoundationEssentials` has no `CGFloat`/`CGPoint`; anchor to Layout's
    /// stubs the same way the bridge's other geometry files do. Swift imports
    /// are file-scoped, so this has to be repeated here.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// Full-score-addressed editing hit result.
///
/// `kind` is `"note"`, `"rest"` or `"tuplet"`. `pitch` / `tpc` carry the
/// selected note's current values; non-note hits use `-1` / `0`.
@JS public struct EditHitItem {
    public var kind: String
    public var partIndex: Int
    public var staffIndexInPart: Int
    public var measureIndex: Int
    public var voiceIndex: Int
    public var elementIndex: Int
    public var noteIndexInChord: Int
    public var pitch: Int
    public var tpc: Int

    public init(
        kind: String,
        partIndex: Int,
        staffIndexInPart: Int,
        measureIndex: Int,
        voiceIndex: Int,
        elementIndex: Int,
        noteIndexInChord: Int,
        pitch: Int,
        tpc: Int,
    ) {
        self.kind = kind
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elementIndex = elementIndex
        self.noteIndexInChord = noteIndexInChord
        self.pitch = pitch
        self.tpc = tpc
    }
}

@JS public struct EditCaretRect {
    public var xMM: Double
    public var yMM: Double
    public var widthMM: Double
    public var heightMM: Double

    public init(xMM: Double, yMM: Double, widthMM: Double, heightMM: Double) {
        self.xMM = xMM
        self.yMM = yMM
        self.widthMM = widthMM
        self.heightMM = heightMM
    }
}

/// Android: `nativeEditingHitTest`.
///
/// `xMM` / `yMM` are document millimetres. The answer is re-addressed from the
/// cached filtered layout back to the full-score address via
/// `Score.engineCursorForFilteredTap`, using the hidden-staff set from
/// `LayoutDocumentCache.entry(for:)` only.
///
/// This is a hit test with slop, not a nearest-match seek: taps on empty paper
/// return `nil` so the browser can deselect. `playerSecondsAtPoint` deliberately
/// does the opposite for tap-to-seek and always chooses a playable neighbor when
/// the score has one.
@JS public func editingHitTest(handle: Int, xMM: Double, yMM: Double, activeVoice: Int) -> EditHitItem? {
    let scoreHandle = Int64(handle)
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle)
    else { return nil }

    let mmToPt = 72.0 / 25.4
    let point = CGPoint(x: CGFloat(xMM * mmToPt), y: CGFloat(yMM * mmToPt))
    guard #available(macOS 15.0, iOS 16.0, *) else { return nil }
    guard let filteredItem = entry.document.editingHitTest(at: point, activeVoice: activeVoice),
          case let .item(fullItem) = score.engineCursorForFilteredTap(
              .item(filteredItem), hiddenStaves: entry.hiddenStaves,
          )
    else { return nil }
    return editHitItem(from: fullItem, in: score)
}

/// Android: `nativeEditingCaretFrame`.
///
/// Takes the full-score-addressed fields returned by `editingHitTest`, translates
/// them back into the cached filtered layout via
/// `Score.translateCursorForHiddenStaves`, then asks
/// `LayoutDocument.editingCaretRect`.
@JS public func editingCaretRect(
    handle: Int,
    kind: String,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    noteIndexInChord: Int,
    minimumWidthMM: Double,
) -> EditCaretRect? {
    let scoreHandle = Int64(handle)
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle),
          let item = editItemID(
              kind: kind,
              partIndex: partIndex,
              staffIndexInPart: staffIndexInPart,
              measureIndex: measureIndex,
              voiceIndex: voiceIndex,
              elementIndex: elementIndex,
              noteIndexInChord: noteIndexInChord,
          ),
          case let .item(filteredItem) = score.translateCursorForHiddenStaves(
              .item(item), hiddenStaves: entry.hiddenStaves,
          )
    else { return nil }

    let mmToPt = 72.0 / 25.4
    let ptToMM = 25.4 / 72.0
    guard let rect = entry.document.editingCaretRect(
        for: filteredItem,
        in: entry.filteredScore,
        minimumWidth: CGFloat(minimumWidthMM * mmToPt),
    ) else { return nil }
    return EditCaretRect(
        xMM: Double(rect.minX) * ptToMM,
        yMM: Double(rect.minY) * ptToMM,
        widthMM: Double(rect.width) * ptToMM,
        heightMM: Double(rect.height) * ptToMM,
    )
}

private func editHitItem(from item: ScoreItemID, in score: Score) -> EditHitItem? {
    switch item {
    case let .note(id):
        let note = score[id]
        return EditHitItem(
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
        return EditHitItem(
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
        return EditHitItem(
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
    case .clef:
        return nil
    }
}

private func editItemID(
    kind: String,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    noteIndexInChord: Int,
) -> ScoreItemID? {
    let staff = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndexInPart)
    switch kind {
    case "note":
        return .note(NoteID(
            staff: staff,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: elementIndex,
            noteIndexInChord: noteIndexInChord,
        ))
    case "rest":
        return .rest(RestID(
            staff: staff,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: elementIndex,
        ))
    case "tuplet":
        return .tuplet(TupletID(
            staff: staff,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            startElementIndex: elementIndex,
        ))
    default:
        return nil
    }
}
