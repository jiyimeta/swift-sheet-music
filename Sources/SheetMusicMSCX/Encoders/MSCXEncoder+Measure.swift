import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Measure {
    /// Build the `<Measure>` element.
    ///
    /// Element ordering matches MuseScore Studio's writer convention:
    /// markers and `<startRepeat/>` come at the head of the measure;
    /// the voices follow; `<endRepeat>` / `<measureRepeatCount>` /
    /// `<Jump>` / `<LayoutBreak>` come at the tail. The decoder is
    /// permissive about ordering so semantic round-trip would work
    /// in any order, but matching MuseScore's order keeps diffs
    /// against fixtures readable.
    func encode(options: MSCXEncoderOptions = .init()) throws -> XMLTreeNode {
        try encode(carryInVoiceTieCarries: [], options: options).node
    }

    /// `carryInVoiceTieCarries[i]` is the previous measure's voice
    /// `i` carry-out (last chord duration + voice total). Voice `i`
    /// of this measure picks it up so a chord at the head of the
    /// measure with `tieBack` can encode the back offset across the
    /// bar line. The returned array is `carryOutVoiceTieCarries[i]`
    /// for the next measure. `isFirstMeasureOfStaff` flags voice 0
    /// of this measure as the staff-head voice so the encoder can
    /// drop an implicit C-major KeySig (matching MuseScore Studio's
    /// writer convention).
    /// `effectiveDuration` is the measure's effective duration
    /// (TimeSignature × actualLength), forwarded to each voice so
    /// `.measure` rests can be resolved against it. The 4/4 default
    /// is a source-compatibility shim — non-`.measure` voices ignore
    /// the value entirely; callers writing `.measure` rests must
    /// pass the real per-measure value (built from
    /// `[Measure].effectiveMeasureDurations()`).
    func encode( // swiftlint:disable:this function_body_length
        carryInVoiceTieCarries: [Voice.VoiceTieCarry],
        isFirstMeasureOfStaff: Bool = false,
        options: MSCXEncoderOptions = .init(),
        staffGroup: String = "pitched",
        voice0SystemElements: [PositionedSystemElement] = [],
        effectiveDuration: Fraction = Fraction(numerator: 4, denominator: 4),
        nextMeasureFirstChordNotes: [ChordNotes?] = [],
    ) throws -> (node: XMLTreeNode, carryOutVoiceTieCarries: [Voice.VoiceTieCarry]) {
        var children: [XMLTreeNode] = []
        for marker in markers {
            children.append(marker.encode())
        }
        if startRepeat {
            children.append(XMLTreeNode(name: "startRepeat"))
        }
        if irregular {
            children.append(XMLTreeNode(name: "irregular", text: "1"))
        }
        var carryOut: [Voice.VoiceTieCarry] = Array(
            repeating: Voice.VoiceTieCarry(), count: voices.count,
        )
        for (index, voice) in voices.enumerated() {
            let carryIn = index < carryInVoiceTieCarries.count
                ? carryInVoiceTieCarries[index]
                : Voice.VoiceTieCarry()
            let injection: [PositionedSystemElement] =
                index == 0 ? voice0SystemElements : []
            let result = try voice.encode(
                carryIn: carryIn,
                isStaffHead: isFirstMeasureOfStaff && index == 0,
                options: options,
                staffGroup: staffGroup,
                voiceIndex: index,
                systemElements: injection,
                effectiveDuration: effectiveDuration,
                nextMeasureFirstChordNotes: index < nextMeasureFirstChordNotes.count
                    ? nextMeasureFirstChordNotes[index]
                    : nil,
            )
            children.append(result.node)
            carryOut[index] = result.carryOut
        }
        if let endRepeatCount {
            children.append(XMLTreeNode(
                name: "endRepeat", text: String(endRepeatCount),
            ))
        }
        if let measureRepeatCount {
            children.append(XMLTreeNode(
                name: "measureRepeatCount", text: String(measureRepeatCount),
            ))
        }
        for jump in jumps {
            children.append(jump.encode())
        }
        if lineBreak {
            children.append(XMLTreeNode(
                name: "LayoutBreak",
                children: [XMLTreeNode(name: "subtype", text: "line")],
            ))
        }
        if pageBreak {
            children.append(XMLTreeNode(
                name: "LayoutBreak",
                children: [XMLTreeNode(name: "subtype", text: "page")],
            ))
        }
        if sectionBreak {
            children.append(XMLTreeNode(
                name: "LayoutBreak",
                children: [XMLTreeNode(name: "subtype", text: "section")],
            ))
        }
        var attributes: [String: String] = [:]
        if let actualLength {
            attributes["len"] =
                "\(actualLength.numerator)/\(actualLength.denominator)"
        }
        return (
            XMLTreeNode(
                name: "Measure", attributes: attributes, children: children,
            ),
            carryOut,
        )
    }

    /// Public stable signature: encode using a per-voice
    /// `lastChordDuration` array rather than the encoder-internal
    /// `VoiceTieCarry`. Kept for source-compatibility while the
    /// rest of the codebase still calls the older shape; new
    /// callers should pass `[Voice.VoiceTieCarry]` directly.
    func encode(
        carryInLastChordDurations: [Fraction?],
        options: MSCXEncoderOptions = .init(),
    ) throws -> (node: XMLTreeNode, carryOutLastChordDurations: [Fraction?]) {
        let carries = carryInLastChordDurations.map {
            Voice.VoiceTieCarry(prevChordDuration: $0, prevVoiceTotal: nil)
        }
        let result = try encode(carryInVoiceTieCarries: carries, options: options)
        return (result.node, result.carryOutVoiceTieCarries.map(\.prevChordDuration))
    }
}

extension Marker {
    /// Build a `<Marker>` element matching the decoder in
    /// `MSCXDecoder+Measure.swift`.
    func encode() -> XMLTreeNode {
        XMLTreeNode(
            name: "Marker",
            children: [
                XMLTreeNode(name: "markerType", text: kind.rawValue),
                XMLTreeNode(name: "label", text: label),
                XMLTreeNode(name: "text", text: text),
            ],
        )
    }
}

extension Jump {
    /// Build a `<Jump>` element matching the decoder in
    /// `MSCXDecoder+Measure.swift`. `<playRepeats>` is emitted only
    /// when true (the non-default), keeping existing fixtures
    /// byte-stable.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "jumpTo", text: jumpTo),
            XMLTreeNode(name: "playUntil", text: playUntil),
            XMLTreeNode(name: "continueAt", text: continueAt),
        ]
        if playRepeats {
            children.append(XMLTreeNode(name: "playRepeats", text: "1"))
        }
        children.append(XMLTreeNode(name: "text", text: text))
        return XMLTreeNode(name: "Jump", children: children)
    }
}
