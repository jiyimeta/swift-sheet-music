#if !os(Android)
    import Foundation

    /// How a normalized page is cut into fixed-size tiles, and which tile
    /// owns a given pixel.
    ///
    /// This is the one piece of preprocessing that is implemented twice —
    /// here and in `Training/model/dataset.py` — and it is safe to be,
    /// because it is integer arithmetic over sizes with no image data in
    /// it. `test_tiling_matches_swift` in `Training/tests/test_dataset.py`
    /// pins the two against the same table.
    ///
    /// The last tile is flush with the far edge rather than short: the
    /// model is trained on one tile size, and a padded partial tile is an
    /// input distribution it never saw.
    enum OMRTiling {
        static func origins(extent: Int, tile: Int, overlap: Int) -> [Int] {
            guard extent > tile else { return [0] }
            let step = max(1, tile - overlap)
            var result: [Int] = []
            var origin = 0
            while origin + tile < extent {
                result.append(origin)
                origin += step
            }
            result.append(extent - tile)
            return result
        }

        /// The half-open interval of page pixels this tile OWNS. Cores
        /// partition the page: a detection is assigned to exactly one
        /// tile, which is what keeps the overlap from double-counting.
        static func coreRange(
            origin: Int, extent: Int, tile: Int, overlap: Int,
        ) -> Range<Int> {
            let all = origins(extent: extent, tile: tile, overlap: overlap)
            guard let index = all.firstIndex(of: origin) else { return 0 ..< 0 }
            let lower = index == 0 ? 0 : (all[index - 1] + tile + origin) / 2
            let upper = index == all.count - 1
                ? extent
                : (origin + tile + all[index + 1]) / 2
            return lower ..< upper
        }
    }
#endif
