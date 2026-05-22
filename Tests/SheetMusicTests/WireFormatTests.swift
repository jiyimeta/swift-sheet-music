#if !os(Android)
    import Foundation
    import SheetMusicWireFormat
    import Testing

    @WireFormat
    private struct TrivialPair: Equatable {
        var a: UInt8
        var b: Int32
    }

    @WireFormat
    private struct NestedPayload {
        var version: UInt16
        var header: TrivialPair
        var items: [TrivialPair]
        var label: String
    }

    @WireFormatChoice
    private enum TestChoice: Equatable {
        case none
        case single(Int32)
        case pair(Int32, String)
        case labelled(measureIndex: Int32, tickInMeasure: Int32)
        case nested(TrivialPair)
    }

    struct WireFormatPrimitiveTests {
        @Test func uint8RoundTrips() throws {
            for value: UInt8 in [0, 1, 127, 128, 255] {
                let bytes = value.encodeToData()
                #expect(bytes.count == 1)
                #expect(try UInt8(decoding: bytes) == value)
            }
        }

        @Test func int32LittleEndian() throws {
            let value: Int32 = 0x0403_0201
            let bytes = Array(value.encodeToData())
            #expect(bytes == [0x01, 0x02, 0x03, 0x04])
            #expect(try Int32(decoding: Data(bytes)) == value)
        }

        @Test func int64NegativeRoundTrips() throws {
            let value: Int64 = -1
            let bytes = value.encodeToData()
            #expect(bytes.count == 8)
            #expect(try Int64(decoding: bytes) == value)
        }

        @Test func stringRoundTripsAscii() throws {
            let value = "Acoustic Grand Piano"
            let bytes = value.encodeToData()
            // i32 prefix (4) + 20 bytes UTF-8
            #expect(bytes.count == 4 + 20)
            #expect(try String(decoding: bytes) == value)
        }

        @Test func stringRoundTripsMultibyte() throws {
            let value = "音楽 🎵"
            let bytes = value.encodeToData()
            #expect(try String(decoding: bytes) == value)
        }

        @Test func emptyArrayRoundTrips() throws {
            let value: [Int32] = []
            let bytes = value.encodeToData()
            #expect(bytes.count == 4) // length prefix only
            #expect(try [Int32](decoding: bytes) == value)
        }

        @Test func arrayOfIntsRoundTrips() throws {
            let value: [Int32] = [1, -1, 1024, .max, .min]
            let bytes = value.encodeToData()
            #expect(try [Int32](decoding: bytes) == value)
        }

        @Test func truncatedReadThrows() {
            let bytes = Data([0x01, 0x02]) // 2 bytes, ask for Int32 (4)
            #expect(throws: WireFormatError.self) {
                _ = try Int32(decoding: bytes)
            }
        }

        @Test func negativeStringLengthRejected() {
            // Int32 = -1, then no payload — should throw invalidCount.
            let bytes = Data([0xFF, 0xFF, 0xFF, 0xFF])
            #expect(throws: WireFormatError.self) {
                _ = try String(decoding: bytes)
            }
        }
    }

    struct WireFormatMacroTests {
        @Test func trivialStructRoundTrips() throws {
            let value = TrivialPair(a: 42, b: -7)
            let bytes = value.encodeToData()
            #expect(bytes.count == 1 + 4) // u8 + i32
            let decoded = try TrivialPair(decoding: bytes)
            #expect(decoded.a == 42)
            #expect(decoded.b == -7)
        }

        @Test func nestedStructWithArrayAndStringRoundTrips() throws {
            let value = NestedPayload(
                version: 7,
                header: TrivialPair(a: 1, b: 2),
                items: [
                    TrivialPair(a: 3, b: 4),
                    TrivialPair(a: 5, b: 6),
                ],
                label: "hello",
            )
            let bytes = value.encodeToData()
            let decoded = try NestedPayload(decoding: bytes)
            #expect(decoded.version == 7)
            #expect(decoded.header.a == 1 && decoded.header.b == 2)
            #expect(decoded.items.count == 2)
            #expect(decoded.items[0].a == 3 && decoded.items[0].b == 4)
            #expect(decoded.items[1].a == 5 && decoded.items[1].b == 6)
            #expect(decoded.label == "hello")
        }

        @Test func choiceNoPayloadRoundTrips() throws {
            let value = TestChoice.none
            let bytes = value.encodeToData()
            #expect(bytes.count == 1) // discriminator only
            #expect(try TestChoice(decoding: bytes) == value)
        }

        @Test func choiceSinglePayloadRoundTrips() throws {
            let value = TestChoice.single(42)
            let bytes = value.encodeToData()
            #expect(bytes.count == 1 + 4) // u8 + Int32
            #expect(try TestChoice(decoding: bytes) == value)
        }

        @Test func choicePairPayloadRoundTrips() throws {
            let value = TestChoice.pair(7, "hello")
            let bytes = value.encodeToData()
            // u8 + Int32 + (Int32 prefix + 5 utf-8) = 1 + 4 + 4 + 5
            #expect(bytes.count == 14)
            #expect(try TestChoice(decoding: bytes) == value)
        }

        @Test func choiceLabelledPayloadRoundTrips() throws {
            let value = TestChoice.labelled(measureIndex: 2, tickInMeasure: 480)
            let bytes = value.encodeToData()
            #expect(try TestChoice(decoding: bytes) == value)
        }

        @Test func choiceNestedStructRoundTrips() throws {
            let value = TestChoice.nested(TrivialPair(a: 9, b: -1))
            let bytes = value.encodeToData()
            #expect(try TestChoice(decoding: bytes) == value)
        }

        @Test func choiceDiscriminatorOutOfRangeThrows() {
            // Discriminator = 99 → invalid.
            let bytes = Data([0x63])
            #expect(throws: WireFormatError.self) {
                _ = try TestChoice(decoding: bytes)
            }
        }

        @Test func nestedStructByteLayoutIsDeterministic() {
            // u16(7) + u8(1) i32(2) + i32(2) + (u8(3) i32(4))(u8(5) i32(6)) + i32(5) "hello"
            //   = 2 + 5 + 4 + 10 + 4 + 5 = 30 bytes
            let value = NestedPayload(
                version: 7,
                header: TrivialPair(a: 1, b: 2),
                items: [
                    TrivialPair(a: 3, b: 4),
                    TrivialPair(a: 5, b: 6),
                ],
                label: "hello",
            )
            #expect(value.encodeToData().count == 30)
        }
    }
#endif
