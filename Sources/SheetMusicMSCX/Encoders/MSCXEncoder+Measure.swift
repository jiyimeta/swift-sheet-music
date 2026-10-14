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
    ///
    /// The fixed `eid: .invalid` means this convenience writes no column identity — a real
    /// `<Measure><eid>` only ever comes from the score's first staff, and the production path for
    /// that is `Staff.encodeTopLevel`, not this overload. Tests use this one.
    func encode(options: MSCXEncoderOptions = .init()) throws -> XMLTreeNode {
        try encode(eid: .invalid, carryInVoiceTieCarries: [], options: options).node
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
        eid: EID,
        carryInVoiceTieCarries: [Voice.VoiceTieCarry],
        isFirstMeasureOfStaff: Bool = false,
        options: MSCXEncoderOptions = .init(),
        staffGroup: String = "pitched",
        voice0SystemElements: [(eid: EID, element: PositionedSystemElement)] = [],
        effectiveDuration: Fraction = Fraction(numerator: 4, denominator: 4),
        nextMeasureFirstChordNotes: [ChordNotes?] = [],
    ) throws -> (node: XMLTreeNode, carryOutVoiceTieCarries: [Voice.VoiceTieCarry]) {
        var children: [XMLTreeNode] = []
        // `<eid>` is the first child MuseScore itself writes — only
        // written at all for the score's first staff (see
        // `Score.appendStaffBodies`, which is the only caller that
        // ever supplies a valid `eid` here).
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        for marker in markers {
            children.append(marker.encode(options: options))
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
            let injection: [(eid: EID, element: PositionedSystemElement)] =
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
            children.append(jump.encode(options: options))
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
        appendPreservedMarkup(
            preservedMarkup,
            to: &children,
            options: options,
        )
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
}

extension Marker {
    /// Build a `<Marker>` in MuseScore's own order — text, label, the type last (`TWrite::write(Marker)`,
    /// `rw/write/twrite.cpp:2274-2282`). The order is load-bearing: MuseScore applies `<markerType>` as it reads it,
    /// and `Marker::setMarkerType` fills an empty text and a still-default label from the type's table
    /// (`dom/marker.cpp:86-106`), so a type read first had both wiped by the `<text>` and `<label>` after it (F3.5).
    /// `<label>` is the effective label, as MuseScore always writes one; `<markerType>` is MuseScore's name
    /// (`Kind.mscxName`), written for Fine too — MuseScore omits its default, but this library's 3.02 exports are read
    /// by it.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let text = encodedText(options: options) {
            children.append(text)
        }
        children.append(XMLTreeNode(name: "label", text: effectiveLabel))
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children.append(XMLTreeNode(name: "markerType", text: kind.mscxName))
        return XMLTreeNode(name: "Marker", children: children)
    }

    /// `<text>`, or nothing for a marker that has none, which MuseScore then gives its type's default text. The kinds
    /// MuseScore has no type for (`.daCapo`, `.dalSegno`) go out as `user`, which has no default, so their words are
    /// written in full.
    private func encodedText(options: MSCXEncoderOptions) -> XMLTreeNode? {
        let writesMarkup = options.emitPreservedMarkup && preservedTextMarkup?.derivedText == text
        if !text.isEmpty || writesMarkup {
            return encodeText(text, preservedTextMarkup: preservedTextMarkup, options: options)
        }
        let words = kind.defaultXMLText
        if kind == .toCodaSym, options.targetVersion == .v3 {
            // MuseScore 3 types a marker by its label alone, and these three share "coda" with To Coda, so without
            // its own text each would open there as "To Coda".
            let markup = PreservedTextMarkup(
                content: [.characters("To "), .element(.init(name: "sym", content: [.characters("coda")]))],
                derivedText: "To ",
            )
            return encodeText("To ", preservedTextMarkup: markup, options: options)
        }
        let sharesToCodaLabel = kind == .daCoda || kind == .daDoubleCoda
        if sharesToCodaLabel, options.targetVersion == .v3 {
            return XMLTreeNode(name: "text", text: words)
        }
        guard kind.mscxName == Kind.user.mscxName, !words.isEmpty else { return nil }
        return XMLTreeNode(name: "text", text: words)
    }
}

extension Jump {
    /// Build a `<Jump>` element matching the decoder in
    /// `MSCXDecoder+Measure.swift`. `<playRepeats>` is emitted only
    /// when true (the non-default), keeping existing fixtures
    /// byte-stable.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "jumpTo", text: jumpTo),
            XMLTreeNode(name: "playUntil", text: playUntil),
            XMLTreeNode(name: "continueAt", text: continueAt),
        ]
        if playRepeats {
            children.append(XMLTreeNode(name: "playRepeats", text: "1"))
        }
        children.append(encodeText(
            text,
            preservedTextMarkup: preservedTextMarkup,
            options: options,
        ))
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "Jump", children: children)
    }
}
