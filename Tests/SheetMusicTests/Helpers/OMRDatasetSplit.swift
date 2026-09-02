#if !os(Android)
    import CryptoKit
    import Foundation

    /// Which of `Training/model/prep.py`'s three splits a page belongs
    /// to — the Swift side of `prep.split_of`, deliberately
    /// re-implemented rather than shared, exactly as `OMRTiling.origins`
    /// and `dataset.tile_origins` are: it is a hash over two strings and
    /// an integer, with no image data in it, and
    /// `OMRDatasetSplitTests.theSplitMatchesThePythonTable` pins the two
    /// to the same table.
    ///
    /// It exists because the eval harnesses know nothing about the
    /// split: `OMRDetectorEvalSweep` sweeps whatever directory it is
    /// handed, while training filters by `split_of`. Measured over the
    /// shipped eval sets, **55 of 69 pages (80%) hash into `train`** —
    /// so an unpartitioned seam recall is mostly a training-set recall.
    /// Reporting the same run partitioned by split is what separates
    /// "the detector generalizes" from "the detector memorized".
    enum OMRDatasetSplit: String {
        case train
        case val
        case test

        /// `sha256("{seed}:{sourceId}:{pageIndex}")`, first four bytes
        /// big-endian, mod 100: < 80 train, < 90 val, else test.
        /// Mirrors `prep.split_of` byte for byte — in particular the
        /// digest is over that exact string, and the bucket comes from
        /// the FIRST four bytes, not the last.
        static func of(sourceId: String, pageIndex: Int, seed: Int) -> OMRDatasetSplit {
            let digest = SHA256.hash(data: Data("\(seed):\(sourceId):\(pageIndex)".utf8))
            let first = digest.prefix(4)
            let bucket = first.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 100
            if bucket < 80 { return .train }
            return bucket < 90 ? .val : .test
        }

        /// The source a render was engraved from.
        ///
        /// A clean render records it (`render.json`'s
        /// `provenance.source_id`) and that is always preferred. A FROZEN
        /// (degraded) render does not — `freeze` writes a `frozen.json`
        /// carrying only `render_id` — so for those it is recovered from
        /// the render id, whose shape is
        /// `{source_id}_{engine}_{face}_v{n}`. `source_id` itself
        /// contains underscores (`cov_clef_changes`, `tex_0076`) while
        /// engine / face / version never do, so dropping the last three
        /// underscore-separated components is the recovery, and
        /// `theRecoveredSourceIdAgreesWithEveryRecordedOne` checks that
        /// rule against every clean render in the dataset rather than
        /// against a handful of hand-picked names.
        static func sourceId(renderDirectory dir: String) -> String? {
            let recorded = recordedSourceId(renderDirectory: dir)
            if let recorded { return recorded }
            return sourceId(fromRenderID: (dir as NSString).lastPathComponent)
        }

        /// The generation seed the render was produced under, which is
        /// also the seed the split is keyed on — recorded by both
        /// `render.json` and `frozen.json`, so unlike `source_id` it
        /// needs no fallback. `nil` when neither file carries it, which
        /// a caller must treat as "cannot attribute this render to a
        /// split", never as a default seed: a wrong seed silently
        /// reshuffles every page into the wrong bucket.
        static func seed(renderDirectory dir: String) -> Int? {
            for name in ["render.json", "frozen.json"] {
                guard let data = FileManager.default.contents(atPath: "\(dir)/\(name)"),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let seed = root["seed"] as? Int
                else { continue }
                return seed
            }
            return nil
        }

        static func recordedSourceId(renderDirectory dir: String) -> String? {
            guard let data = FileManager.default.contents(atPath: "\(dir)/render.json"),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let provenance = root["provenance"] as? [String: Any],
                  let sourceId = provenance["source_id"] as? String
            else { return nil }
            return sourceId
        }

        static func sourceId(fromRenderID renderID: String) -> String? {
            let parts = renderID.split(separator: "_", omittingEmptySubsequences: false)
            guard parts.count > 3 else { return nil }
            return parts.dropLast(3).joined(separator: "_")
        }
    }
#endif
