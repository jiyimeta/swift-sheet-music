#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Maps a point in `LayoutDocument` coordinates to the nearest playable cursor (a chord onset or a rest) on the staff
/// closest to the touch.
///
/// Returns `nil` when the chosen system / staff / measure has no playable elements (e.g. an empty staff under the
/// touched X).
@available(macOS 15.0, iOS 16.0, *)
public func nearestCursor(at point: CGPoint, in document: LayoutDocument) -> ScoreCursor? {
    guard let system = chooseSystem(forY: point.y, in: document.systems) else {
        return nil
    }
    let sp = system.sp
    guard let staffIndex = chooseStaffIndex(
        forY: point.y, system: system, sp: sp,
    ), staffIndex < system.staffAddresses.count else {
        return nil
    }
    let chosenStaff = system.staffAddresses[staffIndex]
    guard let measure = chooseMeasure(forX: point.x, system: system) else {
        return nil
    }
    return chooseEvent(
        in: measure, system: system,
        staff: chosenStaff, point: point, sp: sp,
    )
}

@available(macOS 15.0, iOS 16.0, *)
private func chooseSystem(
    forY y: CGFloat, in systems: [LayoutSystem],
) -> LayoutSystem? {
    guard !systems.isEmpty else { return nil }
    if let containing = systems.first(where: {
        y >= $0.origin.y && y <= $0.origin.y + $0.size.height
    }) {
        return containing
    }
    return systems.min { lhs, rhs in
        verticalDistance(y: y, system: lhs) < verticalDistance(y: y, system: rhs)
    }
}

@available(macOS 15.0, iOS 16.0, *)
private func verticalDistance(y: CGFloat, system: LayoutSystem) -> CGFloat {
    if y < system.origin.y { return system.origin.y - y }
    let bottom = system.origin.y + system.size.height
    if y > bottom { return y - bottom }
    return 0
}

/// Returns the index (into `staffOrigins` / `staffAddresses`) of the staff whose centerline is closest to `y`. A
/// 5-line staff is 4 sp tall, so the centerline sits 2 sp below `staffOrigins[i].y`.
@available(macOS 15.0, iOS 16.0, *)
private func chooseStaffIndex(
    forY y: CGFloat, system: LayoutSystem, sp: CGFloat,
) -> Int? {
    guard !system.staffOrigins.isEmpty else { return nil }
    return system.staffOrigins.indices.min { lhs, rhs in
        let midL = system.origin.y + system.staffOrigins[lhs].y + 2 * sp
        let midR = system.origin.y + system.staffOrigins[rhs].y + 2 * sp
        return abs(y - midL) < abs(y - midR)
    }
}

@available(macOS 15.0, iOS 16.0, *)
private func chooseMeasure(
    forX x: CGFloat, system: LayoutSystem,
) -> LayoutMeasure? {
    guard !system.measures.isEmpty else { return nil }
    if let containing = system.measures.first(where: { measure in
        let lo = system.origin.x + measure.origin.x
        let hi = lo + measure.width
        return x >= lo && x <= hi
    }) {
        return containing
    }
    return system.measures.min { lhs, rhs in
        horizontalDistance(x: x, system: system, measure: lhs)
            < horizontalDistance(x: x, system: system, measure: rhs)
    }
}

@available(macOS 15.0, iOS 16.0, *)
private func horizontalDistance(
    x: CGFloat, system: LayoutSystem, measure: LayoutMeasure,
) -> CGFloat {
    let lo = system.origin.x + measure.origin.x
    let hi = lo + measure.width
    if x < lo { return lo - x }
    if x > hi { return x - hi }
    return 0
}

@available(macOS 15.0, iOS 16.0, *)
private func chooseEvent(
    in measure: LayoutMeasure,
    system: LayoutSystem,
    staff: StaffAddress,
    point: CGPoint,
    sp: CGFloat,
) -> ScoreCursor? {
    let baseX = system.origin.x + measure.origin.x

    // Staff membership is decided by the element's own `NoteID.staff` / `RestID.staff`, not by the notehead's visual Y
    // position. A visual Y band would reject chords whose first note needs a ledger line (high/low notes sitting more
    // than ~2.5 sp from the centerline) and snap the tap to an in-band neighbor instead.
    var best: (cursor: ScoreCursor, dx: CGFloat)?
    for element in measure.elements {
        switch element {
        case let .chord(notes, _, stem, _, _, _, _, _, _, _):
            guard let first = notes.first, first.noteID.staff == staff else { continue }
            let anchorX = baseX + first.origin.x + first.mirrorDx(stem: stem, sp: sp)
            let dx = abs(anchorX - point.x)
            if best.map({ dx < $0.dx }) ?? true {
                best = (.item(.note(first.noteID)), dx)
            }
        case let .rest(_, origin, _, restID, _):
            guard restID.staff == staff else { continue }
            let anchorX = baseX + origin.x
            let dx = abs(anchorX - point.x)
            if best.map({ dx < $0.dx }) ?? true {
                best = (.item(.rest(restID)), dx)
            }
        default:
            continue
        }
    }
    return best?.cursor
}

/// Hit-test a tap (in `LayoutDocument` coordinates) and return an engine-ready, full-score-addressed
/// cursor — the single entry point both iOS and the Android JNI bridge call. Returns `nil` when the
/// tap hit no playable element.
@available(macOS 15.0, iOS 16.0, *)
public func nearestEngineCursor(
    at point: CGPoint, in document: LayoutDocument,
    score: Score, hiddenStaves: Set<StaffAddress>,
) -> ScoreCursor? {
    guard let cursor = nearestCursor(at: point, in: document) else { return nil }
    return score.engineCursorForFilteredTap(cursor, hiddenStaves: hiddenStaves)
}
