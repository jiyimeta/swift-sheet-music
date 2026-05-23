// Fixture: @WireFormat declared inside a namespace-style outer enum.
enum CursorFrameCodec {
    @WireFormat
    struct DecodedFrame {
        var x: Double
        var y: Double
    }
}
