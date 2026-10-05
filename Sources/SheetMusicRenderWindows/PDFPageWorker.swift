import CDirect2D
import Foundation

/// Draws a PDF's pages on a thread of its own, on a device of its own (`cd2d_pdf_renderer`), into CPU pixels the
/// surface uploads — so a page that costs 300 ms to draw never holds the UI thread (folino's QA machine measured
/// 137–316 ms a page when the surface drew them in its own frames).
///
/// The surface says each frame what it wants, nearest the view first (`want`), replacing what it wanted before: a job
/// nobody wants any more is dropped before it starts, one already started finishes. It collects what is done with
/// `takeFinished`. Everything here is behind one lock; the thread sleeps while nothing is wanted.
final class PDFPageWorker: @unchecked Sendable {
    /// Part of a page at a scale: what the surface caches as one band.
    struct Job: Hashable {
        let key: TileKey
        let rect: PixelRect
        let pxPerMM: Double
    }

    enum Outcome {
        /// BGRA premultiplied, `rect.width` x `rect.height`, top-down.
        case drawn([UInt8])
        case failed(hresult: Int32)
    }

    struct Finished {
        let job: Job
        let outcome: Outcome
        let milliseconds: Double
    }

    private let pdf: ScorePDF
    private let condition = NSCondition()
    private var wanted: [Job] = []
    private var running: Job?
    private var finished: [Finished] = []
    private var isStopped = false

    /// Starts the thread, which keeps the worker alive until `stop`.
    init(pdf: ScorePDF) {
        self.pdf = pdf
        let thread = Thread { self.run() }
        thread.name = "PDF pages"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// What the surface wants drawn now, first first. Jobs already running or done are not asked for again.
    func want(_ jobs: [Job]) {
        condition.lock()
        defer { condition.unlock() }
        guard !isStopped else { return }
        let settled = Set(finished.map(\.job)).union(running.map { [$0] } ?? [])
        wanted = jobs.filter { !settled.contains($0) }
        condition.signal()
    }

    /// What has been drawn since the last call, in the order it was drawn.
    func takeFinished() -> [Finished] {
        condition.lock()
        defer { condition.unlock() }
        let done = finished
        finished = []
        return done
    }

    /// Whether anything is wanted, being drawn, or drawn and not yet taken.
    var isBusy: Bool {
        condition.lock()
        defer { condition.unlock() }
        return running != nil || !wanted.isEmpty || !finished.isEmpty
    }

    /// Ends the thread once the job it is drawing, if any, is done. The worker draws nothing after this.
    func stop() {
        condition.lock()
        isStopped = true
        wanted = []
        condition.signal()
        condition.unlock()
    }

    private func run() {
        var renderer: OpaquePointer?
        defer { if let renderer { cd2d_pdf_renderer_destroy(renderer) } }
        while let job = next() {
            let clock = ContinuousClock()
            let start = clock.now
            var outcome = draw(job, renderer: &renderer)
            // A lost device takes the renderer with it: make another and try once more.
            if case .failed(CD2D_E_RECREATE) = outcome {
                if let lost = renderer { cd2d_pdf_renderer_destroy(lost) }
                renderer = nil
                outcome = draw(job, renderer: &renderer)
            }
            let elapsed = clock.now - start
            let milliseconds = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            condition.lock()
            running = nil
            if !isStopped { finished.append(Finished(job: job, outcome: outcome, milliseconds: milliseconds)) }
            condition.unlock()
        }
    }

    /// The first job wanted, marked running; nil once stopped.
    private func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while wanted.isEmpty, !isStopped {
            condition.wait()
        }
        guard !isStopped else { return nil }
        let job = wanted.removeFirst()
        running = job
        return job
    }

    private func draw(_ job: Job, renderer: inout OpaquePointer?) -> Outcome {
        if renderer == nil {
            var created: OpaquePointer?
            let hresult = cd2d_pdf_renderer_create(&created)
            guard hresult == 0, let created else { return .failed(hresult: hresult == 0 ? -1 : hresult) }
            renderer = created
        }
        guard let renderer else { return .failed(hresult: -1) }
        var pixels = [UInt8](repeating: 0, count: job.rect.width * job.rect.height * 4)
        let scale = Float(job.pxPerMM * ScorePDF.mmPerDIP)
        let hresult = pixels.withUnsafeMutableBufferPointer { buffer in
            cd2d_pdf_renderer_draw(
                renderer, pdf.handle, UInt32(job.key.page), scale, Float(job.rect.x), Float(job.rect.y),
                buffer.baseAddress, UInt32(job.rect.width), UInt32(job.rect.height),
            )
        }
        return hresult == 0 ? .drawn(pixels) : .failed(hresult: hresult)
    }
}
