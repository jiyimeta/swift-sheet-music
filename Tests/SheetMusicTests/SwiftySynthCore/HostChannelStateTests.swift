#if canImport(SheetMusicAudioSwiftySynthCore)
    import SheetMusicAudioCore
    import SheetMusicAudioSwiftySynthCore
    import Testing

    /// The host's channel state, recorded once and sent again after every sequencer reset.
    struct HostChannelStateTests {
        private struct Message: Equatable, CustomStringConvertible {
            let channel: Int, command: Int, data1: Int, data2: Int
            var description: String {
                "\(channel):\(String(command, radix: 16)) \(data1) \(data2)"
            }
        }

        private func replayed(_ state: HostChannelState) -> [Message] {
            var messages: [Message] = []
            state.replay { messages.append(Message(channel: $0, command: $1, data1: $2, data2: $3)) }
            return messages
        }

        @Test func `nothing recorded replays nothing`() {
            #expect(replayed(HostChannelState()).isEmpty)
        }

        @Test func `a program replays as bank select then program change`() {
            var state = HostChannelState()
            state.recordProgram(channel: 2, bank: 17, program: 21)
            #expect(replayed(state) == [
                Message(channel: 2, command: 0xB0, data1: 0, data2: 17),
                Message(channel: 2, command: 0xC0, data1: 21, data2: 0),
            ])
        }

        /// SwiftySynth adds 128 to the bank select on the percussion channel, so the drum bank goes out as 0.
        @Test func `a drum kit on the percussion channel selects bank zero there`() {
            var state = HostChannelState()
            state.recordProgram(channel: 9, bank: 128, program: 25)
            #expect(replayed(state) == [
                Message(channel: 9, command: 0xB0, data1: 0, data2: 0),
                Message(channel: 9, command: 0xC0, data1: 25, data2: 0),
            ])
        }

        @Test func `the last value of a controller wins and channel-mode messages are not kept`() {
            var state = HostChannelState()
            state.recordControlChange(channel: 0, controller: 7, value: 90)
            state.recordControlChange(channel: 0, controller: 2, value: 127)
            state.recordControlChange(channel: 0, controller: 7, value: 0)
            state.recordControlChange(channel: 0, controller: 123, value: 0)
            state.recordControlChange(channel: 0, controller: 120, value: 0)
            #expect(replayed(state) == [
                Message(channel: 0, command: 0xB0, data1: 2, data2: 127),
                Message(channel: 0, command: 0xB0, data1: 7, data2: 0),
            ])
        }

        /// What the engine sends to retune a strip, replayed as one select-data-deselect run per parameter.
        @Test func `tuning RPNs replay to the same fine and coarse tune`() {
            var state = HostChannelState()
            let changes = MasterTuning.rpnControlChanges(cents: 150)
            for change in changes {
                state.recordControlChange(channel: 3, controller: Int(change.controller), value: Int(change.value))
            }
            // The engine sends coarse (RPN 0:2) first, then fine (RPN 0:1); each data pair follows its select.
            let coarse = (Int(changes[2].value), Int(changes[3].value))
            let fine = (Int(changes[6].value), Int(changes[7].value))
            let messages = replayed(state)
            #expect(messages == [
                Message(channel: 3, command: 0xB0, data1: 101, data2: 0),
                Message(channel: 3, command: 0xB0, data1: 100, data2: 1),
                Message(channel: 3, command: 0xB0, data1: 6, data2: fine.0),
                Message(channel: 3, command: 0xB0, data1: 38, data2: fine.1),
                Message(channel: 3, command: 0xB0, data1: 101, data2: 0),
                Message(channel: 3, command: 0xB0, data1: 100, data2: 2),
                Message(channel: 3, command: 0xB0, data1: 6, data2: coarse.0),
                Message(channel: 3, command: 0xB0, data1: 38, data2: coarse.1),
                Message(channel: 3, command: 0xB0, data1: 101, data2: 127),
                Message(channel: 3, command: 0xB0, data1: 100, data2: 127),
            ], "\(messages)")
            #expect(fine.0 != 64 || fine.1 != 0, "150 cents has a fine part")
        }

        @Test func `a controller the host never set reads as a reset channel's`() {
            var state = HostChannelState()
            #expect(state.controllerValue(channel: 4, controller: 7) == 100)
            #expect(state.controllerValue(channel: 4, controller: 10) == 64)
            #expect(state.controllerValue(channel: 4, controller: 11) == 127)
            #expect(state.controllerValue(channel: 4, controller: 2) == 0)
            state.recordControlChange(channel: 4, controller: 7, value: 33)
            #expect(state.controllerValue(channel: 4, controller: 7) == 33)
            #expect(state.controllerValue(channel: 16, controller: 7) == -1)
        }
    }
#endif
