#if os(macOS)
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, *)
extension LayoutEngine {
    /// Place elements of a measure in local measure coordinates.
    /// Returns the placed elements + the updated clef context.
    static func placeMeasureElements(
        measure: Measure,
        width: CGFloat,
        metrics: StaffMetrics,
        activeClef: NotatedClef,
        division: Int
    ) -> (elements: [LayoutElement], clef: NotatedClef) {
        let staffMidY = metrics.staffHeight / 2 + metrics.sp * 2
        var out: [LayoutElement] = []
        var x: CGFloat = metrics.sp * 2
        var currentClef = activeClef
        // Detect a time signature declared within this measure (any voice).
        var measureTimeSig: TimeSignature?
        for voice in measure.voices {
            for el in voice.elements {
                if case .timeSignature(let ts) = el {
                    measureTimeSig = ts
                    break
                }
            }
            if measureTimeSig != nil { break }
        }
        for voice in measure.voices {
            var vx = x
            // Maps a voice-element index → index into `out` for the
            // emitted LayoutElement.chord. Used for post-hoc beam marking.
            var voiceChordOutIndex: [Int: Int] = [:]
            for (voiceIdx, el) in voice.elements.enumerated() {
                switch el {
                case .clef(let clef):
                    currentClef = NotatedClef(rawType: clef.concertClefType)
                    out.append(.clef(
                        rawType: clef.concertClefType,
                        origin: CGPoint(x: vx, y: staffMidY)))
                    vx += metrics.sp * 3
                case .keySignature(let key):
                    out.append(.keySignature(
                        sharps: max(0, key.concertKey),
                        flats: max(0, -key.concertKey),
                        origin: CGPoint(x: vx, y: staffMidY)))
                    vx += metrics.sp * CGFloat(abs(key.concertKey)) + metrics.sp
                case .timeSignature(let ts):
                    out.append(.timeSignature(
                        numerator: ts.numerator,
                        denominator: ts.denominator,
                        origin: CGPoint(x: vx, y: staffMidY)))
                    vx += metrics.sp * 3
                case .barLine(let b):
                    out.append(.barLine(
                        subtype: b.subtype,
                        origin: CGPoint(x: vx, y: staffMidY)))
                    vx += metrics.sp
                case .rest(let r):
                    out.append(.rest(
                        duration: r.duration,
                        origin: CGPoint(x: vx, y: staffMidY)))
                    vx += metrics.sp * 3
                case .chord(let chord):
                    let chordNotes = chord.notes.map { note -> LayoutChordNote in
                        let step = PitchStaffPosition.step(
                            midiPitch: note.pitch, tpc: note.tpc,
                            clef: currentClef
                        ).step
                        let y = staffMidY - CGFloat(step) * metrics.sp / 2
                        return LayoutChordNote(
                            step: step,
                            accidental: note.accidental,
                            origin: CGPoint(x: vx, y: y),
                            tieForward: note.tieForward,
                            tieBack: note.tieBack,
                            hasGlissando: note.glissando != nil
                        )
                    }
                    let stem = StemDirectionRule.direction(
                        for: chordNotes.map(\.step))
                    voiceChordOutIndex[voiceIdx] = out.count
                    out.append(.chord(
                        notes: chordNotes,
                        duration: chord.duration,
                        stem: stem,
                        stemOrigin: CGPoint(x: vx, y: staffMidY),
                        hasArpeggio: chord.arpeggio != nil,
                        arpeggioRawType: chord.arpeggio.flatMap(arpeggioSubtype),
                        isBeamed: false))
                    if let arp = chord.arpeggio {
                        let ys = chordNotes.map(\.origin.y)
                        let top = ys.min() ?? staffMidY
                        let bot = ys.max() ?? staffMidY
                        out.append(.arpeggioWiggle(
                            top: CGPoint(x: vx, y: top),
                            bottom: CGPoint(x: vx, y: bot),
                            subtype: arpeggioSubtype(arp)
                        ))
                    }
                    vx += metrics.sp * 3
                case .dynamic(let d):
                    out.append(.textMark(
                        kind: .dynamic,
                        text: d.subtype,
                        origin: CGPoint(
                            x: vx,
                            y: staffMidY + metrics.sp * 4)))
                    vx += metrics.sp * 2
                case .tempo(let t):
                    let bpm = Int((t.beatsPerSecond * 60.0).rounded())
                    // "♩" is Unicode U+2669, rendered in the system text font,
                    // not a SMuFL/Bravura glyph — do not migrate to a SMuFL
                    // codepoint without also switching the renderer's font.
                    out.append(.textMark(
                        kind: .tempo,
                        text: "♩ = \(bpm)",
                        origin: CGPoint(
                            x: vx,
                            y: staffMidY - metrics.sp * 4)))
                    vx += metrics.sp * 2
                case .fermata(let f):
                    // Fermata attaches to the preceding chord/rest (which
                    // already advanced vx), so emit at vx - sp and do NOT
                    // advance vx further.
                    out.append(.fermata(
                        subtype: f.subtype,
                        origin: CGPoint(
                            x: vx - metrics.sp,
                            y: staffMidY - metrics.sp * 3)))
                case .measureRepeat:
                    out.append(.measureRepeat(
                        count: 1,
                        origin: CGPoint(x: width / 2, y: staffMidY)))
                case .spanner:
                    // Spanners are resolved at system level in the
                    // spanner-attach pass.
                    break
                }
            }
            // Glissando emission pass: for each chord in this voice with a
            // note carrying a glissando, pair it with the next chord in the
            // same voice and emit a glissandoLine between their stemOrigins.
            let chordVoiceIndices = voiceChordOutIndex.keys.sorted()
            for (pairIdx, voiceIdx) in chordVoiceIndices.enumerated() {
                guard case .chord(let chord) = voice.elements[voiceIdx] else {
                    continue
                }
                guard let gliss = chord.notes
                    .first(where: { $0.glissando != nil })?
                    .glissando else { continue }
                let nextPairIdx = pairIdx + 1
                guard nextPairIdx < chordVoiceIndices.count else { continue }
                let nextVoiceIdx = chordVoiceIndices[nextPairIdx]
                guard let fromOutIdx = voiceChordOutIndex[voiceIdx],
                      let toOutIdx = voiceChordOutIndex[nextVoiceIdx] else {
                    continue
                }
                guard case .chord(_, _, _, let fromStem, _, _, _) =
                        out[fromOutIdx],
                      case .chord(_, _, _, let toStem, _, _, _) =
                        out[toOutIdx] else {
                    continue
                }
                out.append(.glissandoLine(
                    fromOrigin: fromStem,
                    toOrigin: toStem,
                    wavy: gliss.visualType == .wavy,
                    text: gliss.text
                ))
            }
            // Beaming pass for this voice.
            let groups = beamGroups(
                voice: voice,
                timeSignature: measureTimeSig,
                division: division)
            for group in groups {
                var firstStemOrigin: CGPoint?
                var lastStemOrigin: CGPoint?
                for memberIdx in group.memberIndices {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          case .chord(let n, let d, let s, let so,
                                      let arp, let art, _) = out[outIdx]
                    else { continue }
                    out[outIdx] = .chord(
                        notes: n,
                        duration: d,
                        stem: s,
                        stemOrigin: so,
                        hasArpeggio: arp,
                        arpeggioRawType: art,
                        isBeamed: true)
                    if firstStemOrigin == nil { firstStemOrigin = so }
                    lastStemOrigin = so
                }
                if let f = firstStemOrigin, let l = lastStemOrigin {
                    // Raise beam above the stem anchor so it sits near the
                    // flag position. v1: fixed offset (refined in later
                    // stages alongside stem-direction awareness).
                    let beamY = f.y - metrics.defaultStemLength
                    out.append(.beam(
                        fromOrigin: CGPoint(x: f.x, y: beamY),
                        toOrigin: CGPoint(x: l.x, y: beamY),
                        levels: group.level))
                }
            }
            x = max(x, vx)
        }
        // Trailing bar line if the voice didn't already emit one.
        let hasExplicitBar = out.contains {
            if case .barLine = $0 { true } else { false }
        }
        if !hasExplicitBar {
            out.append(.barLine(
                subtype: nil,
                origin: CGPoint(
                    x: width - metrics.sp / 2,
                    y: staffMidY)))
        }
        return (out, currentClef)
    }

    /// Extract a render-ready subtype string from the Core `Arpeggio` value.
    /// `Arpeggio.subtype` is MuseScore's mscx integer code
    /// (0=NORMAL, 1=UP, 2=DOWN, 3=UP_STRAIGHT, 4=DOWN_STRAIGHT, 5=BRACKET).
    /// `ArpeggioRenderer` consumes "up" / "down" / nil — map accordingly.
    static func arpeggioSubtype(_ arp: Arpeggio) -> String? {
        switch arp.subtype {
        case 1, 3: return "up"
        case 2, 4: return "down"
        default: return nil
        }
    }
}
#endif
