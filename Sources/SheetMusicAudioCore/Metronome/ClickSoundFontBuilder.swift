import SheetMusicFoundation

/// Builds a minimal SoundFont 2 (.sf2) in memory that maps two click
/// samples to GM-percussion notes 76 (strong) and 77 (weak) in a
/// bank-128 preset.
///
/// AUMIDISynth (Apple) and FluidSynth (Android) both auto-select bank 128
/// on MIDI channel 9, and the metronome track already emits notes 76/77
/// on channel 9, so these samples are driven by the unchanged track.
///
/// The SF2 2.x layout produced here:
/// `RIFF 'sfbk'` → `LIST 'INFO'` (ifil/isng/INAM) + `LIST 'sdta'` (smpl)
/// + `LIST 'pdta'` (phdr/pbag/pmod/pgen/inst/ibag/imod/igen/shdr, each
/// section terminated by the spec's sentinel record).
public enum ClickSoundFontBuilder {
    /// Zero sample-points of guard the SF2 spec mandates after each
    /// sample's data.
    private static let guardSamples = 46

    public static func build(
        strong: [Int16], strongRate: UInt32,
        weak: [Int16], weakRate: UInt32,
    ) -> Data {
        // sdta layout (sample points): [strong][46 zeros][weak][46 zeros].
        let strongStart = 0
        let strongEnd = strong.count
        let weakStart = strongEnd + guardSamples
        let weakEnd = weakStart + weak.count

        var smpl = LittleEndianWriter()
        for s in strong {
            smpl.appendInt16(s)
        }
        for _ in 0 ..< guardSamples {
            smpl.appendInt16(0)
        }
        for s in weak {
            smpl.appendInt16(s)
        }
        for _ in 0 ..< guardSamples {
            smpl.appendInt16(0)
        }

        var info = LittleEndianWriter()
        info.append(subchunk("ifil", versionTag(major: 2, minor: 1)))
        info.append(subchunk("isng", zstr("EMU8000")))
        info.append(subchunk("INAM", zstr("SheetMusic Metronome")))

        var sdta = LittleEndianWriter()
        sdta.append(subchunk("smpl", smpl.data))

        var pdta = LittleEndianWriter()
        pdta.append(subchunk("phdr", buildPHDR()))
        pdta.append(subchunk("pbag", buildPBAG()))
        pdta.append(subchunk("pmod", terminalMOD()))
        pdta.append(subchunk("pgen", buildPGEN()))
        pdta.append(subchunk("inst", buildINST()))
        pdta.append(subchunk("ibag", buildIBAG()))
        pdta.append(subchunk("imod", terminalMOD()))
        pdta.append(subchunk("igen", buildIGEN()))
        pdta.append(subchunk("shdr", buildSHDR(
            strongStart: strongStart, strongEnd: strongEnd, strongRate: strongRate,
            weakStart: weakStart, weakEnd: weakEnd, weakRate: weakRate,
        )))

        var body = LittleEndianWriter()
        body.appendTag("sfbk")
        body.append(listChunk("INFO", info.data))
        body.append(listChunk("sdta", sdta.data))
        body.append(listChunk("pdta", pdta.data))

        var riff = LittleEndianWriter()
        riff.appendTag("RIFF")
        riff.appendUInt32(UInt32(body.data.count))
        riff.append(body.data)
        return riff.data
    }

    // MARK: - Chunk helpers

    /// 4-byte id + u32 size + payload, padded to even length.
    private static func subchunk(_ id: String, _ payload: Data) -> Data {
        var w = LittleEndianWriter()
        w.appendTag(id)
        w.appendUInt32(UInt32(payload.count))
        w.append(payload)
        if payload.count & 1 == 1 { w.appendUInt8(0) }
        return w.data
    }

    /// A LIST chunk: "LIST" size form-type + payload.
    private static func listChunk(_ type: String, _ payload: Data) -> Data {
        var inner = LittleEndianWriter()
        inner.appendTag(type)
        inner.append(payload)
        return subchunk("LIST", inner.data)
    }

    private static func versionTag(major: UInt16, minor: UInt16) -> Data {
        var w = LittleEndianWriter()
        w.appendUInt16(major)
        w.appendUInt16(minor)
        return w.data
    }

    /// Null-terminated, even-length ASCII string.
    private static func zstr(_ s: String) -> Data {
        var bytes = Array(s.utf8)
        bytes.append(0)
        if bytes.count & 1 == 1 { bytes.append(0) }
        return Data(bytes)
    }

    // MARK: - pdta sections (each ends with a sentinel record)

    /// 38-byte preset headers: our preset + terminal "EOP".
    private static func buildPHDR() -> Data {
        var w = LittleEndianWriter()
        w.appendFixedString("Click", length: 20)
        w.appendUInt16(0) // wPreset
        w.appendUInt16(128) // wBank (GM percussion)
        w.appendUInt16(0) // wPresetBagNdx → first pbag
        w.appendUInt32(0) // dwLibrary
        w.appendUInt32(0) // dwGenre
        w.appendUInt32(0) // dwMorphology
        // Terminal record.
        w.appendFixedString("EOP", length: 20)
        w.appendUInt16(0)
        w.appendUInt16(0)
        w.appendUInt16(1) // one past the last real pbag
        w.appendUInt32(0)
        w.appendUInt32(0)
        w.appendUInt32(0)
        return w.data
    }

    /// 4-byte preset bags: one zone + terminal.
    private static func buildPBAG() -> Data {
        var w = LittleEndianWriter()
        w.appendUInt16(0) // wGenNdx → first pgen
        w.appendUInt16(0) // wModNdx
        w.appendUInt16(1) // terminal: one past the last real pgen
        w.appendUInt16(0)
        return w.data
    }

    /// 4-byte preset generators: one "instrument" generator + terminal.
    private static func buildPGEN() -> Data {
        var w = LittleEndianWriter()
        w.appendUInt16(41) // sfGenOper = instrument
        w.appendUInt16(0) // instrument index 0
        w.appendUInt16(0) // terminal
        w.appendUInt16(0)
        return w.data
    }

    /// 10-byte modulator: a single all-zero terminal record (no modulators).
    private static func terminalMOD() -> Data {
        Data(repeating: 0, count: 10)
    }

    /// 22-byte instrument headers: our instrument + terminal "EOI".
    private static func buildINST() -> Data {
        var w = LittleEndianWriter()
        w.appendFixedString("Click", length: 20)
        w.appendUInt16(0) // wInstBagNdx → first ibag
        w.appendFixedString("EOI", length: 20)
        w.appendUInt16(2) // one past the last real ibag
        return w.data
    }

    /// 4-byte instrument bags: zone 0 (igen 0), zone 1 (igen 4), terminal (igen 8).
    private static func buildIBAG() -> Data {
        var w = LittleEndianWriter()
        w.appendUInt16(0); w.appendUInt16(0)
        w.appendUInt16(4); w.appendUInt16(0)
        w.appendUInt16(8); w.appendUInt16(0)
        return w.data
    }

    /// 4-byte instrument generators for both zones + terminal. The last
    /// generator in each zone must be `sampleID` (53).
    private static func buildIGEN() -> Data {
        var w = LittleEndianWriter()
        func keyRangeAmount(_ lo: UInt16, _ hi: UInt16) -> UInt16 {
            lo | (hi << 8)
        }
        // Zone 0: strong → key 76, sample 0.
        w.appendUInt16(43); w.appendUInt16(keyRangeAmount(76, 76)) // keyRange
        w.appendUInt16(58); w.appendUInt16(76) // overridingRootKey
        w.appendUInt16(54); w.appendUInt16(0) // sampleModes = no loop
        w.appendUInt16(53); w.appendUInt16(0) // sampleID 0 (last)
        // Zone 1: weak → key 77, sample 1.
        w.appendUInt16(43); w.appendUInt16(keyRangeAmount(77, 77))
        w.appendUInt16(58); w.appendUInt16(77)
        w.appendUInt16(54); w.appendUInt16(0)
        w.appendUInt16(53); w.appendUInt16(1)
        // Terminal.
        w.appendUInt16(0); w.appendUInt16(0)
        return w.data
    }

    /// 46-byte sample headers: strong, weak, terminal "EOS".
    private static func buildSHDR(
        strongStart: Int, strongEnd: Int, strongRate: UInt32,
        weakStart: Int, weakEnd: Int, weakRate: UInt32,
    ) -> Data {
        var w = LittleEndianWriter()
        func sample(_ name: String, start: Int, end: Int, rate: UInt32, key: UInt8) {
            w.appendFixedString(name, length: 20)
            w.appendUInt32(UInt32(start)) // dwStart
            w.appendUInt32(UInt32(end)) // dwEnd
            w.appendUInt32(UInt32(start)) // dwStartloop (ignored, no loop)
            w.appendUInt32(UInt32(end)) // dwEndloop
            w.appendUInt32(rate) // dwSampleRate
            w.appendUInt8(key) // byOriginalPitch
            w.appendUInt8(0) // chPitchCorrection
            w.appendUInt16(0) // wSampleLink
            w.appendUInt16(1) // sfSampleType = monoSample
        }
        sample("Click_Strong", start: strongStart, end: strongEnd, rate: strongRate, key: 76)
        sample("Click_Weak", start: weakStart, end: weakEnd, rate: weakRate, key: 77)
        // Terminal "EOS" record (all-zero numeric fields).
        w.appendFixedString("EOS", length: 20)
        w.appendUInt32(0); w.appendUInt32(0); w.appendUInt32(0)
        w.appendUInt32(0); w.appendUInt32(0)
        w.appendUInt8(0); w.appendUInt8(0); w.appendUInt16(0); w.appendUInt16(0)
        return w.data
    }
}
