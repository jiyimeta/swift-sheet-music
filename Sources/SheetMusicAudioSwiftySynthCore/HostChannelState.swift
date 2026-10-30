/// What a host set on each of a synth's sixteen channels — bank and program, controllers, the RPN parameters — kept so
/// it can be sent again after the synth forgets it.
///
/// SwiftySynth's `MidiFileSequencer` resets its synthesizer on `play`, `seek` and `stop`: every channel goes back to
/// bank 0, program 0, volume 100 and concert pitch, and the seek's chase restores only what the SMF itself says. A
/// FluidSynth player never did that, and Android's Kotlin engine was written against FluidSynth: it programs each
/// mixer strip, sets its CC 7, opens CC 2 and retunes once, and expects all of it to hold for the life of the synth.
/// The playback renderer strips the SMF's tick-0 programs and CC 7 on mixer channels for exactly that reason
/// (`MidiSynthPostProcess`), so after a reset nothing but this record knows them.
///
/// Only what the host sent is recorded, never what the SMF played; the SMF's own controllers come back through the
/// chase, and replaying a later SMF value after a backward seek would be wrong.
///
/// Fixed storage, allocated once: recording and replaying allocate nothing.
public struct HostChannelState {
    private static let channelCount = 16
    private static let controllerCount = 128
    /// The RPNs SwiftySynth implements, all with MSB 0: pitch-bend range, fine tune, coarse tune.
    private static let rpnCount = 3
    private static let unset: Int16 = -1

    private var banks: [Int16]
    private var programs: [Int16]
    /// `channel * controllerCount + controller`.
    private var controllers: [Int16]
    /// The RPN each channel last selected with CC 101 / CC 100, as `msb << 7 | lsb`; 0x3FFF is the null RPN.
    private var selectedRPN: [Int16]
    /// `channel * rpnCount + lsb`, for RPN MSB 0.
    private var rpnCoarse: [Int16]
    private var rpnFine: [Int16]

    public init() {
        banks = Array(repeating: Self.unset, count: Self.channelCount)
        programs = Array(repeating: Self.unset, count: Self.channelCount)
        controllers = Array(repeating: Self.unset, count: Self.channelCount * Self.controllerCount)
        selectedRPN = Array(repeating: 0x3FFF, count: Self.channelCount)
        rpnCoarse = Array(repeating: Self.unset, count: Self.channelCount * Self.rpnCount)
        rpnFine = Array(repeating: Self.unset, count: Self.channelCount * Self.rpnCount)
    }

    /// Records a program select: `bank` is the effective bank the host means (128 and up for a drum kit), `program`
    /// 0…127.
    public mutating func recordProgram(channel: Int, bank: Int, program: Int) {
        guard (0 ..< Self.channelCount).contains(channel) else { return }
        banks[channel] = Int16(clamping: max(0, bank))
        programs[channel] = Int16(clamping: min(max(0, program), 127))
    }

    /// Records one control change. Channel-mode messages (120–127) are actions, not state, and are not kept; the RPN
    /// and NRPN selectors and data entry are tracked as the parameter they address.
    public mutating func recordControlChange(channel: Int, controller: Int, value: Int) {
        guard (0 ..< Self.channelCount).contains(channel), (0 ..< 120).contains(controller) else { return }
        let value = Int16(min(max(0, value), 127))
        switch controller {
        case 0:
            // Bank select on its own: keep the program the host set with it, or the GM default.
            banks[channel] = channel == Self.percussionChannel ? value + 128 : value
            if programs[channel] == Self.unset { programs[channel] = 0 }
        case 101:
            selectedRPN[channel] = (value << 7) | (selectedRPN[channel] & 0x7F)
        case 100:
            selectedRPN[channel] = (selectedRPN[channel] & ~0x7F) | value
        case 98, 99:
            // An NRPN select deselects the RPN; SwiftySynth implements no NRPN.
            selectedRPN[channel] = 0x3FFF
        case 6, 38:
            let rpn = Int(selectedRPN[channel])
            guard rpn >> 7 == 0, (rpn & 0x7F) < Self.rpnCount else { return }
            let slot = channel * Self.rpnCount + (rpn & 0x7F)
            if controller == 6 {
                rpnCoarse[slot] = value
            } else {
                rpnFine[slot] = value
            }
        case 96, 97:
            // Data increment / decrement: SwiftySynth ignores them.
            return
        default:
            controllers[channel * Self.controllerCount + controller] = value
        }
    }

    /// The value the host last set for `controller` on `channel`, else the value a reset channel holds.
    public func controllerValue(channel: Int, controller: Int) -> Int {
        guard (0 ..< Self.channelCount).contains(channel), (0 ..< Self.controllerCount).contains(controller) else {
            return -1
        }
        let value = controllers[channel * Self.controllerCount + controller]
        if value != Self.unset { return Int(value) }
        switch controller {
        case 7: return 100
        case 10: return 64
        case 11: return 127
        default: return 0
        }
    }

    /// Sends everything recorded, channel by channel, as MIDI channel messages: bank select (CC 0) then program
    /// change, the plain controllers in controller order, then each recorded RPN as select → data entry → null RPN.
    ///
    /// SwiftySynth reads only CC 0 for the bank and adds 128 to it on the percussion channel, so a drum bank (128 and
    /// up) there is sent as `bank − 128`. Elsewhere a bank is clamped to a 7-bit value; a drum kit on a melodic channel
    /// cannot be expressed, and the playback renderer never asks for one (`LiveChannelPlan` puts every drumset on
    /// channel 9).
    public func replay(_ send: (_ channel: Int, _ command: Int, _ data1: Int, _ data2: Int) -> Void) {
        for channel in 0 ..< Self.channelCount {
            if programs[channel] != Self.unset {
                send(channel, 0xB0, 0, Self.bankSelect(channel: channel, bank: Int(banks[channel])))
                send(channel, 0xC0, Int(programs[channel]), 0)
            }
            let base = channel * Self.controllerCount
            for controller in 0 ..< Self.controllerCount {
                let value = controllers[base + controller]
                if value != Self.unset {
                    send(channel, 0xB0, controller, Int(value))
                }
            }
            var selected = false
            for lsb in 0 ..< Self.rpnCount {
                let slot = channel * Self.rpnCount + lsb
                guard rpnCoarse[slot] != Self.unset || rpnFine[slot] != Self.unset else { continue }
                send(channel, 0xB0, 101, 0)
                send(channel, 0xB0, 100, lsb)
                if rpnCoarse[slot] != Self.unset { send(channel, 0xB0, 6, Int(rpnCoarse[slot])) }
                if rpnFine[slot] != Self.unset { send(channel, 0xB0, 38, Int(rpnFine[slot])) }
                selected = true
            }
            if selected {
                send(channel, 0xB0, 101, 127)
                send(channel, 0xB0, 100, 127)
            }
        }
    }

    /// The CC 0 value that selects the effective `bank` on `channel` (see `replay`).
    public static func bankSelect(channel: Int, bank: Int) -> Int {
        let value = channel == percussionChannel && bank >= 128 ? bank - 128 : bank
        return min(max(0, value), 127)
    }

    /// The bank SwiftySynth resolves a preset in once `channel` received bank select `bankSelect`: 128 more on the
    /// percussion channel — what `SoundFont.prefetchSamples(bank:patch:)` expects.
    public static func effectiveBank(channel: Int, bankSelect: Int) -> Int {
        channel == percussionChannel ? bankSelect + 128 : bankSelect
    }

    /// GM's percussion channel, 0-based — SwiftySynth's `Synthesizer.percussionChannel`.
    private static let percussionChannel = 9
}
