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
        case let .keySignature(s, f, p):
            return .keySignature(sharps: s, flats: f, origin: shift(p))
        case let .timeSignature(n, d, p):
            return .timeSignature(
                numerator: n, denominator: d, origin: shift(p),
            )
        case let .barLine(s, p):
            return .barLine(subtype: s, origin: shift(p))
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
            )
        case let .textMark(k, t, p):
            return .textMark(kind: k, text: t, origin: shift(p))
        case let .fermata(s, p):
            return .fermata(subtype: s, origin: shift(p))
        case let .articulation(kind, p, isAbove):
            return .articulation(
                kind: kind,
                origin: shift(p),
                isAbove: isAbove,
            )
        case let .measureRepeat(c, p):
            return .measureRepeat(count: c, origin: shift(p))
        case let .multiMeasureRest(c, p):
            // Multi-measure rest contributes no special translation logic;
            // shift the anchor origin for correct staff stacking.
            return .multiMeasureRest(count: c, origin: shift(p))
        case let .beam(from, to, direction, level):
            return .beam(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                direction: direction,
                level: level,
            )
        case let .glissandoLine(from, to, wavy, text):
            return .glissandoLine(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                wavy: wavy,
                text: text,
            )
        case let .arpeggioWiggle(top, bot, subtype):
            return .arpeggioWiggle(
                top: shift(top),
                bottom: shift(bot),
                subtype: subtype,
            )
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
        case let .lyricsMelisma(from, to):
            return .lyricsMelisma(
                fromOrigin: shift(from),
                toOrigin: shift(to),
            )
        case let .lyricHyphen(from, to):
            return .lyricHyphen(
                fromOrigin: shift(from),
                toOrigin: shift(to),
            )
        case let .staffText(text, p, color, isSystem):
            // Emitted by `placeMeasureElements` in staff-local
            // coords (relative to a virtual staff with top at
            // sp * 2), so the per-staff `dy` must be applied for
            // the text to land above its OWN staff. Without this
            // shift every staff's text rendered above staff 0.
            return .staffText(
                text: text,
                origin: shift(p),
                color: color,
                isSystemText: isSystem,
            )
        case let .rehearsalMark(text, p, frame, color):
            // Same staff-local origin convention as `.staffText`;
            // shift onto the system's actual top-staff y.
            return .rehearsalMark(
                text: text, origin: shift(p),
                frame: frame, color: color,
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
        case .note, .marker, .jump, .measureNumber, .staffName,
             .spannerSegment, .tieArc:
            return element
        }
    }
}
