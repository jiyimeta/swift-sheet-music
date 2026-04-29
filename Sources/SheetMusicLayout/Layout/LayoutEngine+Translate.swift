import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    /// Shift an element's origin(s) by a vertical offset, for stacking
    /// staves that were placed in staff-0-local coordinates.
    static func translate(
        element: LayoutElement, dy: CGFloat
    ) -> LayoutElement {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: p.y + dy)
        }
        switch element {
        case .clef(let t, let p):
            return .clef(rawType: t, origin: shift(p))
        case .keySignature(let s, let f, let p):
            return .keySignature(sharps: s, flats: f, origin: shift(p))
        case .timeSignature(let n, let d, let p):
            return .timeSignature(
                numerator: n, denominator: d, origin: shift(p))
        case .barLine(let s, let p):
            return .barLine(subtype: s, origin: shift(p))
        case let .rest(d, p, vi, rid, hll):
            return .rest(
                duration: d, origin: shift(p),
                voiceIndex: vi, restID: rid,
                hasLegerLine: hll)
        case .chord(let notes, let dur, let stem, let so,
                    let arp, let art, let beamed, let vi):
            let shiftedNotes = notes.map {
                LayoutChordNote(
                    noteID: $0.noteID,
                    step: $0.step,
                    accidental: $0.accidental,
                    origin: shift($0.origin),
                    tieForward: $0.tieForward,
                    tieBack: $0.tieBack,
                    hasGlissando: $0.hasGlissando,
                    headType: $0.headType
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
                voiceIndex: vi
            )
        case .textMark(let k, let t, let p):
            return .textMark(kind: k, text: t, origin: shift(p))
        case .fermata(let s, let p):
            return .fermata(subtype: s, origin: shift(p))
        case .measureRepeat(let c, let p):
            return .measureRepeat(count: c, origin: shift(p))
        case .beam(let from, let to, let direction, let level):
            return .beam(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                direction: direction,
                level: level)
        case .glissandoLine(let from, let to, let wavy, let text):
            return .glissandoLine(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                wavy: wavy,
                text: text)
        case .arpeggioWiggle(let top, let bot, let subtype):
            return .arpeggioWiggle(
                top: shift(top),
                bottom: shift(bot),
                subtype: subtype)
        case .tupletLabel(let from, let to, let text, let bracket, let above):
            return .tupletLabel(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                text: text,
                hasBracket: bracket,
                isAbove: above)
        case .lyricsMelisma(let from, let to):
            return .lyricsMelisma(
                fromOrigin: shift(from),
                toOrigin: shift(to))
        case .lyricHyphen(let from, let to):
            return .lyricHyphen(
                fromOrigin: shift(from),
                toOrigin: shift(to))
        case .staffText(let text, let p, let color, let isSystem):
            // Emitted by `placeMeasureElements` in staff-local
            // coords (relative to a virtual staff with top at
            // sp * 2), so the per-staff `dy` must be applied for
            // the text to land above its OWN staff. Without this
            // shift every staff's text rendered above staff 0.
            return .staffText(
                text: text,
                origin: shift(p),
                color: color,
                isSystemText: isSystem)
        case .rehearsalMark(let text, let p, let frame, let color):
            // Same staff-local origin convention as `.staffText`;
            // shift onto the system's actual top-staff y.
            return .rehearsalMark(
                text: text, origin: shift(p),
                frame: frame, color: color)
        case .note, .marker, .jump, .measureNumber, .staffName,
             .spannerSegment, .tieArc:
            return element
        }
    }
}
