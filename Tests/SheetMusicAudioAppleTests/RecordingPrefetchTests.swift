@testable import SheetMusicAudioApple
import SheetMusicAudioCore
import Testing

/// What the engine reads in ahead of the render thread: which file seconds a track plays next
/// (`PlaybackEngine.recordingPrefetchRanges`), and which bytes of the mapping hold them
/// (`MappedRecording.prefetchBytes`). Whether the pages then stay resident is the kernel's; it is checked on a device.
struct RecordingPrefetchTests {
    private static let wholeRecording = RecordingSchedule(segments: [
        RecordingSegment(sourceStart: 0, sourceEnd: 10, outputStart: 0),
    ])

    private static func ranges(
        at transport: Double, rate: Double = 1, warp: PlaybackTimeWarp? = nil,
        schedule: RecordingSchedule = wholeRecording, offset: Double = 0,
    ) -> [Range<Double>] {
        PlaybackEngine.recordingPrefetchRanges(
            transportSeconds: transport, rate: rate, table: TransportSpeedTable(warp: warp), schedule: schedule,
            offset: offset,
        )
    }

    // MARK: File seconds

    @Test func `two seconds ahead of the transport, and half a second behind`() {
        #expect(Self.ranges(at: 3) == [2.5 ..< 5])
        // Near the top the stretch behind is clipped at the file's start.
        #expect(Self.ranges(at: 0.2) == [0 ..< 2.2])
    }

    @Test func `two seconds of wall-clock time at the rate, and never fewer warped seconds`() {
        #expect(Self.ranges(at: 3, rate: 2) == [2.5 ..< 7])
        #expect(Self.ranges(at: 3, rate: 0.5) == [2.5 ..< 5])
    }

    @Test func `the transport second is warped before the schedule reads it`() throws {
        // Transport 0–2 s lasts 2.5 s: transport 1 s is warped 1.25 s.
        let warp = try PlaybackTimeWarp(spans: [.init(start: 0, end: 2, duration: 2.5)])
        #expect(Self.ranges(at: 1, warp: warp) == [0.75 ..< 3.25])
    }

    @Test func `a track's offset moves the file seconds it reads`() {
        #expect(Self.ranges(at: 3, offset: 1.5) == [1 ..< 3.5])
    }

    @Test func `a cut to another segment inside the window reads that segment's start too`() {
        let cut = RecordingSchedule(segments: [
            RecordingSegment(sourceStart: 0, sourceEnd: 4, outputStart: 0),
            RecordingSegment(sourceStart: 10, sourceEnd: 20, outputStart: 4.5),
        ])
        #expect(Self.ranges(at: 3, schedule: cut) == [2.5 ..< 4, 9.5 ..< 10.5])
        #expect(Self.ranges(at: 3, schedule: RecordingSchedule(segments: [])).isEmpty)
    }

    // MARK: Bytes

    /// 10 s at 48 kHz: frames of 4 bytes after the 16-byte header, 1 920 016 bytes, 118 pages of 16 KiB.
    private static func bytes(_ seconds: Range<Double>, pageSize: Int = 16384) -> Range<Int>? {
        MappedRecording.prefetchBytes(seconds: seconds, sampleRate: 48000, frameCount: 480_000, pageSize: pageSize)
    }

    @Test func `the bytes are the frames' pages, with the frame after the last`() {
        // Frames 48 000 ..< 96 001 are bytes 192 016 ..< 384 020: pages 11 ..< 24.
        #expect(Self.bytes(1 ..< 2) == 11 * 16384 ..< 24 * 16384)
        // 48 frames plus the one after at 4 KiB pages: bytes 192 016 ..< 192 212, pages 46 ..< 47.
        #expect(Self.bytes(1 ..< 1.001, pageSize: 4096) == 46 * 4096 ..< 47 * 4096)
        // At 1024 Hz, frames 0 ..< 1020 end exactly on the first 4 KiB page; the frame after them is on the second.
        let edge = MappedRecording.prefetchBytes(
            seconds: 0 ..< 1020.0 / 1024, sampleRate: 1024, frameCount: 10240, pageSize: 4096,
        )
        #expect(edge == 0 ..< 2 * 4096)
    }

    @Test func `the bytes are clipped to the file, and nil past its end`() {
        #expect(Self.bytes(-1 ..< 0.1) == 0 ..< 2 * 16384)
        // From frame 475 200 (byte 1 900 816, page 116) to the last page of the mapping.
        #expect(Self.bytes(9.9 ..< 12) == 116 * 16384 ..< 118 * 16384)
        #expect(Self.bytes(20 ..< 22) == nil)
        #expect(Self.bytes(1 ..< .infinity) == nil)
    }
}
