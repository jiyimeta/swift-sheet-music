import SheetMusicFoundation

/// Concert-pitch key signature. C++: `mu::engraving::KeySig`.
public struct KeySignature: Sendable, Equatable {
    /// Sharp/flat count: -7 (Cb) … +7 (C#). 0 = C major / a minor.
    public var concertKey: Int

    /// MuseScore `<showCourtesySig>` — whether the end-of-system courtesy for this signature is drawn.
    /// Layout reads it, nothing else does.
    public var showCourtesy: Bool

    /// Base element properties shared with every engravable element.
    /// Carries `<visible>` and `<color>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(concertKey: Int, visible: Bool = true, showCourtesy: Bool = true) {
        self.concertKey = concertKey
        self.showCourtesy = showCourtesy
        elementProperties = ElementProperties(visible: visible)
    }
}

extension KeySignature {
    /// 7-tone pitch class set (0…11) of the diatonic scale implied
    /// by this signature. Major / minor / modal share the same
    /// signature so a single mapping suffices.
    ///
    /// Starts from the C-major PC set `{0, 2, 4, 5, 7, 9, 11}` and
    /// applies one alteration per accidental, following the circle of
    /// fifths: sharps F → C → G → D → A → E → B (each PC raised by 1);
    /// flats B → E → A → D → G → C → F (each PC lowered by 1).
    public var diatonicPitchClasses: Set<Int> {
        let sharpOrder = [5, 0, 7, 2, 9, 4, 11]
        let flatOrder: [Int] = sharpOrder.reversed()
        var set: Set = [0, 2, 4, 5, 7, 9, 11]
        if concertKey >= 0 {
            for i in 0 ..< concertKey {
                let pc = sharpOrder[i]
                set.remove(pc)
                set.insert((pc + 1) % 12)
            }
        } else {
            for i in 0 ..< -concertKey {
                let pc = flatOrder[i]
                set.remove(pc)
                set.insert((pc + 11) % 12)
            }
        }
        return set
    }
}
