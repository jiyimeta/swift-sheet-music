#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// A beam whose chords are drawn on two staves — a right hand's arpeggio running down into the bass staff. Its line
/// can only be drawn once the system knows where both staves sit, so placement sets its members' stems and leaves the
/// beam to `LayoutEngine.layOutCrossStaffBeams`, which runs after the staff origins are fixed (as MuseScore lays its
/// cross beams out only after vertical spacing, `rendering/score/pagelayout.cpp:314-316`).
struct CrossStaffBeam: Equatable {
    struct Member: Equatable {
        /// The chord, at the address it is written at (its home staff).
        let chord: VoiceElementID
        /// Its effective move; 0 for a member drawn on its own staff.
        let staffMove: Int
        /// Its beam level (1 = eighth, 2 = sixteenth, …).
        let level: Int
    }

    let members: [Member]
    let color: ScoreColor?
    /// `Chord.beamVisible` of the group's leading chord: false hides the bars, not the beaming.
    let isVisible: Bool
}

/// One chord of a cross-staff beam as `LayoutEngine.crossStaffBeamSlant` reads it.
struct CrossBeamChord: Equatable {
    let isBelowBeam: Bool
    /// The flat index of the staff it is drawn on.
    let staff: Int
    /// The staff line, in half-spaces down from the top line, of the notehead nearest the beam (`Chord::line()`).
    let line: Int
    /// System y of the notehead its stem grows from.
    let stemRootY: CGFloat
}

extension LayoutEngine {
    /// The move from which a chord of a beam across staves is drawn below it: `ceil((min + max) / 2)` of the members'
    /// moves (`beambase.cpp:113-117`, `ChordRest::isBelowCrossBeam`).
    static func crossStaffBeamSplit(_ moves: [Int]) -> Int? {
        guard let lowest = moves.min(), let highest = moves.max(), lowest != highest else { return nil }
        return Int((Double(lowest + highest) / 2).rounded(.up))
    }

    /// The stem of every chord of a voice's beams across two staves, by element index: up below the beam, down above
    /// it. Settled before the chords are placed, so their noteheads and marks take the side the beam gives them — a
    /// cross beam decides its chords' stems over any direction of their own (`ChordLayout::computeUpBeamCase`,
    /// `rendering/score/chordlayout.cpp:1276-1285`, reached before the explicit direction once a chord is beamed).
    static func crossStaffBeamStems(
        groups: [BeamGroup], voiceIndex: Int, movedChords: [VoiceSlot: MovedChordPlacement],
    ) -> [Int: StemDirection] {
        var stems: [Int: StemDirection] = [:]
        for group in groups {
            let moves = group.memberIndices.map {
                movedChords[VoiceSlot(voiceIndex: voiceIndex, elementIndex: $0)]?.staffMove ?? 0
            }
            guard let split = crossStaffBeamSplit(moves) else { continue }
            for (position, member) in group.memberIndices.enumerated() {
                stems[member] = moves[position] >= split ? .up : .down
            }
        }
        return stems
    }

    /// Sets the stems of a beam group whose members are drawn on two staves and describes the group for
    /// `layOutCrossStaffBeams`; nil when fewer than two of its chords were placed.
    ///
    /// MuseScore splits such a beam at `ceil((min + max) / 2)` of its members' moves (`beambase.cpp:113-117`): a chord
    /// whose move reaches the split is drawn below the beam, with its stem up; the rest above it, stem down
    /// (`ChordRest::isBelowCrossBeam`, `dom/chordrest.cpp:1297-1300`). Each stem stops at its notehead nearest the beam
    /// for now, so the staff's vertical extent does not take in a stem the other staff will meet: MuseScore leaves a
    /// cross-beamed stem out of the skyline on that side (`infrastructure/skyline.cpp:46-89`).
    static func prepareCrossStaffBeam( // swiftlint:disable:this function_parameter_count
        group: BeamGroup, moves: [Int], voice: Voice, voiceIndex: Int,
        staffAddress: StaffAddress, measureIndex: Int,
        chordOutIndex: [Int: Int], out: inout [LayoutElement],
    ) -> CrossStaffBeam? {
        guard let split = crossStaffBeamSplit(moves) else { return nil }
        var members: [CrossStaffBeam.Member] = []
        var color: ScoreColor?
        for (position, memberIndex) in group.memberIndices.enumerated() {
            guard let outIndex = chordOutIndex[memberIndex],
                  case let .chord(notes, duration, _, stemOrigin, arpeggio, arpeggioType, _, voiceIdx, _, hidden, mag)
                  = out[outIndex],
                  case let .chord(model) = voice.elements[memberIndex]
            else { continue }
            let isBelowBeam = moves[position] >= split
            let stem: StemDirection = isBelowBeam ? .up : .down
            let nearestY = isBelowBeam
                ? (notes.map(\.origin.y).min() ?? stemOrigin.y)
                : (notes.map(\.origin.y).max() ?? stemOrigin.y)
            out[outIndex] = .chord(
                notes: notes, duration: duration, stem: stem, stemOrigin: CGPoint(x: stemOrigin.x, y: nearestY),
                hasArpeggio: arpeggio, arpeggioRawType: arpeggioType, isBeamed: true, voiceIndex: voiceIdx,
                stemExtension: 0, stemIsInvisible: hidden, mag: mag,
            )
            color = color ?? notes.compactMap(\.color).first
            members.append(CrossStaffBeam.Member(
                chord: VoiceElementID(
                    staff: staffAddress, measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: memberIndex,
                ),
                staffMove: moves[position],
                level: beamLevel(model.drawnDuration),
            ))
        }
        guard members.count >= 2 else { return nil }
        let leadVisible: Bool = {
            guard let first = group.memberIndices.first, case let .chord(chord) = voice.elements[first] else {
                return true
            }
            return chord.beamVisible
        }()
        return CrossStaffBeam(members: members, color: color, isVisible: leadVisible)
    }

    /// Draws one measure's cross-staff beams now that the staves are placed: finds each member chord in the buffer of
    /// the staff it is drawn on, sets its stem to meet the beam, and adds the beam's bars to the buffer of the staff
    /// the group is written on. `elements` are staff-local, by flat staff index; `staffOriginY` places each staff.
    ///
    /// The beam lies between the staves, centered midway between the innermost noteheads of the chords above it and
    /// below it, and slanted by `crossStaffBeamSlant` — MuseScore's layout of a beam with chords on both sides
    /// (`BeamTremoloLayout::calculateAnchorsCross`, `rendering/score/beamtremololayout.cpp:784-1053`). Not drawn: the
    /// re-centering MuseScore does when the secondary beams stack on one side of the primary. A group whose placed
    /// members all ended up on one side is beamed flat, a stem's length past them.
    static func layOutCrossStaffBeams( // swiftlint:disable:this function_body_length
        _ beams: [CrossStaffBeam],
        in elements: inout [Int: [LayoutElement]],
        flatIndex: (StaffAddress) -> Int?,
        staffOriginY: (Int) -> CGFloat,
        metrics: StaffMetrics,
    ) {
        for beam in beams {
            struct Placed {
                let staff: Int
                let index: Int
                let isBelowBeam: Bool
                let noteYs: [CGFloat]
                let stemX: CGFloat
                let level: Int
                let slantInput: CrossBeamChord
            }
            let staffMidY = metrics.staffHeight / 2 + metrics.sp * 2
            var placed: [Placed] = []
            for member in beam.members {
                let home = member.chord.staff
                let drawn = StaffAddress(
                    partIndex: home.partIndex, staffIndexInPart: home.staffIndexInPart + member.staffMove,
                )
                guard let staff = flatIndex(drawn), let buffer = elements[staff],
                      let index = buffer.firstIndex(where: { element in
                          guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element,
                                let id = notes.first?.noteID
                          else { return false }
                          return id.staff == home && id.measureIndex == member.chord.measureIndex
                              && id.voiceIndex == member.chord.voiceIndex
                              && id.elementIndex == member.chord.elementIndex
                      }),
                      case let .chord(notes, _, stem, stemOrigin, _, _, _, _, _, _, _) = buffer[index]
                else { continue }
                let originY = staffOriginY(staff)
                let side = metrics.sp * 0.59 * (stem == .up ? 1 : -1)
                let localYs = notes.map(\.origin.y)
                // The notehead nearest the beam, and the one the stem grows from.
                let nearY = (stem == .up ? localYs.min() : localYs.max()) ?? stemOrigin.y
                let rootY = (stem == .up ? localYs.max() : localYs.min()) ?? stemOrigin.y
                placed.append(Placed(
                    staff: staff, index: index, isBelowBeam: stem == .up,
                    noteYs: localYs.map { $0 + originY }, stemX: stemOrigin.x + side, level: member.level,
                    slantInput: CrossBeamChord(
                        isBelowBeam: stem == .up, staff: staff,
                        line: Int(((nearY - staffMidY) / (metrics.sp / 2)).rounded()) + 4,
                        stemRootY: rootY + originY,
                    ),
                ))
            }
            guard placed.count >= 2, let writtenOn = beam.members.first.flatMap({ flatIndex($0.chord.staff) }),
                  let firstX = placed.first?.stemX, let lastX = placed.last?.stemX
            else { continue }
            let aboveInner = placed.filter { !$0.isBelowBeam }.compactMap { $0.noteYs.max() }.max()
            let belowInner = placed.filter(\.isBelowBeam).compactMap { $0.noteYs.min() }.min()
            let midY: CGFloat
            var slant = 0
            switch (aboveInner, belowInner) {
            case let (above?, below?):
                midY = (above + below) / 2
                slant = crossStaffBeamSlant(
                    placed.map(\.slantInput), beamWidth: (lastX - firstX) / metrics.sp, sp: metrics.sp,
                )
            case let (above?, nil): midY = above + metrics.defaultStemLength
            case let (nil, below?): midY = below - metrics.defaultStemLength
            case (nil, nil): continue
            }
            // A positive slant rises to the right: the start sits half of it below the center, the end half above.
            let rise = CGFloat(slant) * metrics.sp / 4
            let startY = midY + rise / 2
            let endY = midY - rise / 2
            func beamY(at x: CGFloat) -> CGFloat {
                lastX == firstX ? midY : startY + (endY - startY) * (x - firstX) / (lastX - firstX)
            }
            for member in placed {
                guard case let .chord(
                    notes,
                    duration,
                    stem,
                    stemOrigin,
                    arpeggio,
                    arpeggioType,
                    _,
                    voiceIndex,
                    _,
                    hidden,
                    mag,
                ) = elements[member.staff]?[member.index]
                else { continue }
                elements[member.staff]?[member.index] = .chord(
                    notes: notes, duration: duration, stem: stem,
                    stemOrigin: CGPoint(x: stemOrigin.x, y: beamY(at: member.stemX) - staffOriginY(member.staff)),
                    hasArpeggio: arpeggio, arpeggioRawType: arpeggioType, isBeamed: true, voiceIndex: voiceIndex,
                    stemExtension: 0, stemIsInvisible: hidden, mag: mag,
                )
            }
            guard beam.isVisible else { continue }
            let writtenOriginY = staffOriginY(writtenOn)
            let stemXs = placed.map { Optional($0.stemX) }
            let stemYs = placed.map { Optional(beamY(at: $0.stemX) - writtenOriginY) }
            let levels = placed.map(\.level)
            let direction: StemDirection = placed.first?.isBelowBeam == true ? .up : .down
            var bars: [LayoutElement] = []
            for level in 1 ... max(levels.max() ?? 0, 1) {
                var runStart: Int?
                for position in 0 ... levels.count {
                    let has = position < levels.count && levels[position] >= level
                    if has, runStart == nil {
                        runStart = position
                    } else if !has, let start = runStart {
                        emitBeamRun(
                            start: start, end: position - 1, level: level,
                            memberStemXs: stemXs, memberStemYs: stemYs, memberCount: levels.count,
                            beamYAt: { beamY(at: $0) - writtenOriginY }, direction: direction, color: beam.color,
                            metrics: metrics,
                            out: &bars,
                        )
                        runStart = nil
                    }
                }
            }
            elements[writtenOn, default: []].append(contentsOf: bars)
        }
    }

    /// MuseScore's slant for a beam with chords above and below it, in quarter spaces — positive rises to the right —
    /// from `chords` in beam order (`BeamTremoloLayout::calculateAnchorsCross`, `beamtremololayout.cpp:784-1053`).
    /// `beamWidth` is the distance between the first and last stems, in spaces.
    ///
    /// Two chords, one on each side, slant a quarter space per space between their stems' roots. Otherwise the
    /// first-to-last direction of the chords above the beam, of those below it, of the switches from one side to the
    /// other and of the moves between staves on one side must not disagree, and the slant is the smaller of the two
    /// sides' first-to-last steps; a middle chord reaching past an outer one, or a disagreement, keeps the beam flat.
    /// The bookkeeping of "middle" chords follows MuseScore's, quirks included: the second chord of a side never counts
    /// as one.
    static func crossStaffBeamSlant( // swiftlint:disable:this cyclomatic_complexity function_body_length
        _ chords: [CrossBeamChord], beamWidth: CGFloat, sp: CGFloat,
    ) -> Int {
        guard let first = chords.first else { return 0 }
        var topFirst: CrossBeamChord?
        var topLast: CrossBeamChord?
        var bottomFirst: CrossBeamChord?
        var bottomLast: CrossBeamChord?
        var maxMiddleTopLine = Int.min
        var minMiddleBottomLine = Int.max
        var prevTopLine = Int.min
        var prevBottomLine = Int.max
        var secondTopIsSame = false
        var secondBottomIsSame = false
        var penultimateTopIsSame = false
        var penultimateBottomIsSame = false
        var prevBelowBeam = first.isBelowBeam
        var hasBeamSideSwitch = false
        var beamSideSwitchDirection = 0
        var prevStaff = first.staff
        var hasStaffSwitch = false
        var staffSwitchDirection = 0
        var checkNextTop = false
        var checkNextBottom = false
        for chord in chords {
            if chord.isBelowBeam == prevBelowBeam, prevStaff != chord.staff {
                staffSwitchDirection = hasStaffSwitch ? 0 : (prevStaff - chord.staff < 0 ? -1 : 1)
                hasStaffSwitch = true
            }
            prevStaff = chord.staff
            if chord.isBelowBeam {
                if penultimateBottomIsSame {
                    minMiddleBottomLine = min(minMiddleBottomLine, prevBottomLine)
                    penultimateBottomIsSame = false
                }
                checkNextTop = false
                if let firstBelow = bottomFirst {
                    penultimateBottomIsSame = prevBottomLine == chord.line
                    if !penultimateBottomIsSame { minMiddleBottomLine = min(minMiddleBottomLine, prevBottomLine) }
                    if checkNextBottom {
                        secondBottomIsSame = chord.line == firstBelow.line
                        checkNextBottom = false
                    } else {
                        prevBottomLine = chord.line
                    }
                    bottomLast = chord
                } else {
                    bottomFirst = chord
                    checkNextBottom = true
                }
                if !prevBelowBeam {
                    beamSideSwitchDirection = hasBeamSideSwitch ? 0 : -1
                    hasBeamSideSwitch = true
                }
                prevBelowBeam = true
            } else {
                if penultimateTopIsSame {
                    maxMiddleTopLine = max(maxMiddleTopLine, prevTopLine)
                    penultimateTopIsSame = false
                }
                checkNextBottom = false
                if let firstAbove = topFirst {
                    penultimateTopIsSame = prevTopLine == chord.line
                    if !penultimateTopIsSame { maxMiddleTopLine = max(maxMiddleTopLine, prevTopLine) }
                    if checkNextTop {
                        secondTopIsSame = chord.line == firstAbove.line
                        checkNextTop = false
                    } else {
                        prevTopLine = chord.line
                    }
                    topLast = chord
                } else {
                    topFirst = chord
                    checkNextTop = true
                }
                if prevBelowBeam {
                    beamSideSwitchDirection = hasBeamSideSwitch ? 0 : 1
                    hasBeamSideSwitch = true
                }
                prevBelowBeam = false
            }
        }
        let maxSlope = crossStaffBeamMaxSlope(beamWidth: beamWidth)
        if topLast == nil, bottomLast == nil, let above = topFirst, let below = bottomFirst {
            let (head, tail) = first == above ? (above, below) : (below, above)
            let desired = Int(((head.stemRootY - tail.stemRootY) / sp).rounded())
            return min(abs(desired), maxSlope) * (desired < 0 ? -1 : 1)
        }
        let topFirstLine = topFirst?.line ?? 0
        let topLastLine = topLast?.line ?? 0
        let bottomFirstLine = bottomFirst?.line ?? 0
        let bottomLastLine = bottomLast?.line ?? 0
        let constrainTop = (topFirstLine > topLastLine && secondTopIsSame)
            || (topFirstLine < topLastLine && penultimateTopIsSame)
        let constrainBottom = (bottomFirstLine < bottomLastLine && secondBottomIsSame)
            || (bottomFirstLine > bottomLastLine && penultimateBottomIsSame)
        var topSlant = topFirstLine - topLastLine
        if constrainTop, topSlant != 0 { topSlant = topFirstLine < topLastLine ? -1 : 1 }
        let singleNoteTop = topLast == nil
        if singleNoteTop { topSlant = 0 }
        var bottomSlant = bottomFirstLine - bottomLastLine
        if constrainBottom, bottomSlant != 0 { bottomSlant = bottomFirstLine < bottomLastLine ? -1 : 1 }
        let singleNoteBottom = bottomLast == nil
        if singleNoteBottom { bottomSlant = 0 }
        let middleReachesPast = maxMiddleTopLine >= max(topFirstLine, topLastLine)
            || minMiddleBottomLine <= min(bottomFirstLine, bottomLastLine)
        let topDirection = topSlant.signum()
        let bottomDirection = bottomSlant.signum()
        let directions = [topDirection, bottomDirection, beamSideSwitchDirection, staffSwitchDirection]
        let overall = directions.first { $0 != 0 } ?? 0
        let disagrees = directions.contains { $0 != 0 && $0 != overall }
        let flattenNeutralSideSwitch = beamSideSwitchDirection == 0 && topDirection != bottomDirection
            && !(singleNoteTop || singleNoteBottom)
        guard !middleReachesPast, overall != 0, !flattenNeutralSideSwitch, !disagrees else { return 0 }
        let slant = if topSlant == 0 {
            bottomSlant
        } else if bottomSlant == 0 {
            topSlant
        } else {
            abs(topSlant) < abs(bottomSlant) ? topSlant : bottomSlant
        }
        return min(abs(slant), maxSlope) * (slant < 0 ? -1 : 1)
    }

    /// The steepest slant, in quarter spaces, a beam this many spaces wide takes (`BeamTremoloLayout::getMaxSlope`).
    static func crossStaffBeamMaxSlope(beamWidth: CGFloat) -> Int {
        switch beamWidth {
        case ..<3: 1
        case ..<5: 2
        case ..<7.5: 3
        case ..<10: 4
        case ..<15: 5
        case ..<20: 6
        default: 7
        }
    }
}
