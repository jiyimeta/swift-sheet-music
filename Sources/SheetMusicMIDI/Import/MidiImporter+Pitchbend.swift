import SheetMusicCore
import SheetMusicFoundation

extension MidiImporter {
    /// Pitch-bend range assumed when interpreting bend values back
    /// into semitones. Matches `MidiRenderer`'s output (`RPN 0:0`
    /// set to 12 semitones in the header).
    static let detectGlissandoBendRangeSemitones = 12

    /// Pure result type — measure index, the on-tick of the source
    /// note (used by `attachGlissandos` later to pin the attachment
    /// to a specific element), and the glissando to attach.
    struct GlissandoAttachment: Equatable {
        var measureIndex: Int
        var sourceOnTick: Int
        var pitch: Int
        var glissando: Glissando
    }

    /// Inspect every held note's pitch-bend stream and return
    /// attachments for those that match the narrow detection rules:
    /// monotonic bend that resolves to an integer-semitone offset
    /// matching the next noteOn's pitch on the same channel.
    static func detectGlissandos(
        measure: ImportMeasure,
        division: Int,
    ) -> [GlissandoAttachment] {
        struct Span {
            var channel: Int
            var pitch: Int
            var onTick: Int
            var offTick: Int
            var bends: [Int]
        }

        // Walk the event stream once to build per-note spans, each
        // carrying the pitch-bend values observed during the note.
        var open: [(channel: Int, pitch: Int, onTick: Int, bends: [Int])] = []
        var spans: [Span] = []
        for ev in measure.events {
            switch ev.event {
            case let .noteOn(c, p, v) where v > 0:
                open.append((c, p, ev.tick, []))
            case let .noteOn(c, p, _),
                 let .noteOff(c, p, _):
                if let i = open.firstIndex(where: { $0.channel == c && $0.pitch == p }) {
                    let n = open.remove(at: i)
                    spans.append(Span(
                        channel: c, pitch: p,
                        onTick: n.onTick, offTick: ev.tick, bends: n.bends,
                    ))
                }
            case let .pitchBend(c, value):
                for i in open.indices where open[i].channel == c {
                    open[i].bends.append(value)
                }
            default: break
            }
        }

        var attachments: [GlissandoAttachment] = []
        let semitoneStep = 8192 / detectGlissandoBendRangeSemitones // 682

        for span in spans where !span.bends.isEmpty {
            guard isMonotonic(span.bends) else { continue }
            guard let lastBend = span.bends.last else { continue }
            let last = lastBend - 8192 // signed, 0 = no bend
            let semitones = Int((Double(last) / Double(semitoneStep)).rounded())
            if semitones == 0 { continue }

            // Drift check: ±15% of an integer semitone.
            let expected = Double(semitones * semitoneStep)
            let drift = abs(Double(last) - expected) / Double(semitoneStep)
            if drift > 0.15 { continue }

            // Match the next noteOn on the same channel after this span.
            let target = span.pitch + semitones
            let nextOn = measure.events.first { ev in
                ev.tick >= span.offTick && {
                    if case let .noteOn(c, p, v) = ev.event, c == span.channel,
                       v > 0, p == target { return true }
                    return false
                }()
            }
            guard nextOn != nil else { continue }

            attachments.append(GlissandoAttachment(
                measureIndex: measure.measureIndex,
                sourceOnTick: span.onTick,
                pitch: span.pitch,
                glissando: Glissando(style: .portamento, visualType: .straight),
            ))
        }
        return attachments
    }

    /// Allow up to 5% direction-reversal samples (rounding noise);
    /// otherwise the sequence must be globally increasing or
    /// globally decreasing.
    private static func isMonotonic(_ values: [Int]) -> Bool {
        guard values.count >= 2 else { return false }
        var increasing = 0
        var decreasing = 0
        for i in 1 ..< values.count {
            if values[i] > values[i - 1] { increasing += 1 }
            if values[i] < values[i - 1] { decreasing += 1 }
        }
        let total = values.count - 1
        let bias = max(increasing, decreasing)
        return Double(total - bias) / Double(total) <= 0.05
    }
}
