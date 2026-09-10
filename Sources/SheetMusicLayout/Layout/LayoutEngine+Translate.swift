// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// Shift an element's origin(s) by a vertical offset, for stacking
    /// staves that were placed in staff-0-local coordinates.
    static func translate( // swiftlint:disable:this function_body_length
        element: LayoutElement, dy: CGFloat,
    ) -> LayoutElement {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: p.y + dy)
        }
        switch element {
        case let .clef(t, p, anchor):
            return .clef(rawType: t, origin: shift(p), anchor: anchor)
        case let .keySignature(s, f, clef, naturals, p, measureIndex):
            return .keySignature(
                sharps: s, flats: f, clef: clef, naturals: naturals,
                origin: shift(p), measureIndex: measureIndex,
            )
        case let .timeSignature(n, d, symbol, p, measureIndex):
            return .timeSignature(
                numerator: n, denominator: d, symbol: symbol,
                origin: shift(p), measureIndex: measureIndex,
            )
        case let .barLine(s, p, halfHeight, measureIndex, role):
            return .barLine(
                subtype: s, origin: shift(p), halfHeight: halfHeight,
                measureIndex: measureIndex, role: role,
            )
        case let .ledgerLine(from, to, thickness):
            return .ledgerLine(
                from: shift(from), to: shift(to), thickness: thickness,
            )
        case let .rest(d, p, vi, rid, hll):
            return .rest(
                duration: d, origin: shift(p),
                voiceIndex: vi, restID: rid,
                hasLegerLine: hll,
            )
        case let .chord(
            notes,
            dur,
            stem,
            so,
            arp,
            art,
            beamed,
            vi,
            stemExt,
            stemHidden,
            mag,
        ):
            let shiftedNotes = notes.map {
                LayoutChordNote(
                    noteID: $0.noteID,
                    step: $0.step,
                    accidental: $0.accidental,
                    origin: shift($0.origin),
                    tieForward: $0.tieForward,
                    tieBack: $0.tieBack,
                    hasGlissando: $0.hasGlissando,
                    headType: $0.headType,
                    mirror: $0.mirror,
                    isInvisible: $0.isInvisible,
                    color: $0.color,
                    accidentalBracket: $0.accidentalBracket,
                    parentheses: $0.parentheses,
                )
            }
            return .chord(
                notes: shiftedNotes,
                duration: dur,
                stem: stem,
                stemOrigin: shift(so),
                hasArpeggio: arp,
                arpeggioRawType: art,
                isBeamed: beamed,
                voiceIndex: vi,
                stemExtension: stemExt,
                stemIsInvisible: stemHidden,
                mag: mag,
            )
        case let .textMark(k, t, p):
            return .textMark(kind: k, text: t, origin: shift(p))
        case let .fermata(s, p, anchor):
            return .fermata(subtype: s, origin: shift(p), anchor: anchor)
        case let .breath(kind, p, anchor):
            return .breath(kind: kind, origin: shift(p), anchor: anchor)
        case let .articulation(kind, p, isAbove, anchor):
            return .articulation(
                kind: kind,
                origin: shift(p),
                isAbove: isAbove,
                anchor: anchor,
            )
        case let .measureRepeat(c, p):
            return .measureRepeat(count: c, origin: shift(p))
        case let .multiMeasureRest(c, p):
            // Multi-measure rest contributes no special translation logic;
            // shift the anchor origin for correct staff stacking.
            return .multiMeasureRest(count: c, origin: shift(p))
        case let .beam(from, to, direction, level, color):
            return .beam(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                direction: direction,
                level: level,
                color: color,
            )
        case let .glissandoLine(from, to, wavy, text):
            return .glissandoLine(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                wavy: wavy,
                text: text,
            )
        case let .guitarBend(from, vertex, to, slight):
            // All three points live in the same frame, so they shift
            // together (the slight bend's `vertex` and `toOrigin` are
            // absolute here, not offsets from `fromOrigin`).
            return .guitarBend(
                fromOrigin: shift(from),
                vertex: shift(vertex),
                toOrigin: shift(to),
                slight: slight,
            )
        case let .legacyBend(shape):
            // Every piece is in one frame, so the shape shifts whole.
            return .legacyBend(
                shape: shape.translated(by: CGPoint(x: 0, y: dy)),
            )
        case let .arpeggioWiggle(top, bot, subtype):
            return .arpeggioWiggle(
                top: shift(top),
                bottom: shift(bot),
                subtype: subtype,
            )
        case let .chordLine(shape, origin, thickness):
            // The shape payload is origin-relative, so only the origin
            // moves.
            return .chordLine(
                shape: shape, origin: shift(origin), thickness: thickness,
            )
        case let .tremoloBars(anchor, barCount):
            let shifted: TremoloAnchor
            switch anchor {
            case let .single(c):
                shifted = .single(center: shift(c))
            case let .between(left, right):
                shifted = .between(
                    leftStemMid: shift(left),
                    rightStemMid: shift(right),
                )
            }
            return .tremoloBars(anchor: shifted, barCount: barCount)
        case let .tupletLabel(
            from,
            to,
            text,
            bracket,
            above,
            tid,
        ):
            return .tupletLabel(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                text: text,
                hasBracket: bracket,
                isAbove: above,
                tupletID: tid,
            )
        case let .lyricsMelisma(from, to, placement):
            return .lyricsMelisma(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                placement: placement,
            )
        case let .lyricHyphen(from, to, placement):
            return .lyricHyphen(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                placement: placement,
            )
        case let .staffText(text, p, color, style, anchor, placement):
            // Emitted by `placeMeasureElements` in staff-local coords
            // (relative to a virtual staff with top at sp * 2), so the
            // per-staff `dy` must be applied for the text to land above
            // its OWN staff. Without this shift every staff's text
            // rendered above staff 0.
            return .staffText(
                text: text,
                origin: shift(p),
                color: color,
                style: style,
                anchor: anchor,
                placement: placement,
            )
        case let .rehearsalMark(text, p, frame, color, measureIndex, placement):
            // Same staff-local origin convention as `.staffText`;
            // shift onto the system's actual top-staff y.
            return .rehearsalMark(
                text: text, origin: shift(p),
                frame: frame, color: color,
                measureIndex: measureIndex,
                placement: placement,
            )
        case let .harmony(lh):
            // Apply per-staff dy to the anchor point. The runs are
            // laid out relative to `anchorX`, so their `x` values
            // are unaffected.
            return .harmony(LayoutHarmony(
                harmony: lh.harmony,
                anchorX: lh.anchorX,
                y: lh.y + Double(dy),
                runs: lh.runs,
                width: lh.width,
                anchor: lh.anchor,
                placement: lh.placement,
            ))
        case let .graceChord(
            notes, dur, stem, so, relX, slash, mag, vi,
        ):
            let shiftedNotes = notes.map {
                LayoutChordNote(
                    noteID: $0.noteID,
                    step: $0.step,
                    accidental: $0.accidental,
                    origin: shift($0.origin),
                    tieForward: $0.tieForward,
                    tieBack: $0.tieBack,
                    hasGlissando: $0.hasGlissando,
                    headType: $0.headType,
                    mirror: $0.mirror,
                    isInvisible: $0.isInvisible,
                    color: $0.color,
                    accidentalBracket: $0.accidentalBracket,
                    parentheses: $0.parentheses,
                )
            }
            return .graceChord(
                notes: shiftedNotes,
                duration: dur,
                stem: stem,
                stemOrigin: shift(so),
                relativeX: relX,
                hasSlash: slash,
                mag: mag,
                voiceIndex: vi,
            )
        case let .measureNumber(text, p):
            // Emitted into the pass-1 per-staff buffer (staff 0 only)
            // in staff-local coords (staff top at sp * 2), same
            // convention as `.staffText` / `.rehearsalMark` above —
            // shift onto the system's actual top-staff y.
            return .measureNumber(text: text, origin: shift(p))
        case let .spannerSegment(
            kind, from, to, continuesLeft, continuesRight, text, anchor,
        ):
            // Both endpoints share one anchor Y, but shifting them
            // independently is what keeps this correct if a sloped
            // segment ever appears.
            return .spannerSegment(
                kind: kind,
                fromOrigin: shift(from),
                toOrigin: shift(to),
                continuesLeft: continuesLeft,
                continuesRight: continuesRight,
                text: text,
                anchor: anchor,
            )
        case let .marker(kind, text, origin, identity):
            return .marker(kind: kind, text: text, origin: shift(origin), identity: identity)
        case let .jump(text, origin, identity):
            return .jump(text: text, origin: shift(origin), identity: identity)
        case let .staffName(text, origin):
            return .staffName(text: text, origin: shift(origin))
        case .note, .tieArc:
            return element
        }
    }

    /// Shift an annotation's origin horizontally, for
    /// `HorizontalClampPass` pulling text back inside the system.
    ///
    /// Deliberately narrow: only the kinds the clamp pass is allowed to
    /// move are handled, and everything else passes through untouched.
    /// A general `dx` counterpart to `translate(element:dy:)` would have
    /// to answer what "move a chord sideways" means for its beams,
    /// ties and tick columns — questions no caller has.
    static func translateX(
        element: LayoutElement, dx: CGFloat,
    ) -> LayoutElement {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + dx, y: p.y)
        }
        switch element {
        case let .staffText(text, p, color, style, anchor, placement):
            return .staffText(
                text: text, origin: shift(p),
                color: color, style: style, anchor: anchor, placement: placement,
            )
        case let .textMark(k, t, p):
            return .textMark(kind: k, text: t, origin: shift(p))
        case let .rehearsalMark(text, p, frame, color, measureIndex, placement):
            return .rehearsalMark(
                text: text, origin: shift(p),
                frame: frame, color: color, measureIndex: measureIndex, placement: placement,
            )
        default:
            return element
        }
    }
}
