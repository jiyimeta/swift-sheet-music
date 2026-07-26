#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusic
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicLayoutApple
    import SheetMusicMSCX

    /// Corpus collision detector. For every score in a directory it runs
    /// `LayoutEngine.layout` and reports each pair of overlapping shapes
    /// among the AUTOPLACED element kinds.
    ///
    ///   SM_COLLIDE_DIR — directory to scan (required to activate)
    ///   SM_COLLIDE_LIMIT — max files to process (default: all)
    ///
    /// No score path is hardcoded and no result is committed — the
    /// corpus is the author's private library.
    @available(macOS 15.0, *)
    @MainActor
    enum CollisionReport {
        static var isRequested: Bool {
            ProcessInfo.processInfo.environment["SM_COLLIDE_DIR"] != nil
        }

        private struct Collision {
            let file: String
            let system: Int
            let staff: Int
            let a: String
            let b: String
            let overlap: CGFloat
        }

        static func run() throws {
            let env = ProcessInfo.processInfo.environment
            guard let dir = env["SM_COLLIDE_DIR"] else { return }
            _ = SheetMusicLayoutApple.install
            let root = URL(
                fileURLWithPath:
                (dir as NSString).expandingTildeInPath,
            )
            var files = try FileManager.default
                .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { ["mscz", "mscx"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let limit = env["SM_COLLIDE_LIMIT"].flatMap({ Int($0) }) {
                files = Array(files.prefix(limit))
            }

            var all: [Collision] = []
            var failures = 0
            for url in files {
                do {
                    try all.append(contentsOf: collisions(in: url))
                } catch {
                    failures += 1
                    print("SKIP \(url.lastPathComponent): \(error)")
                }
            }
            report(all, fileCount: files.count, failures: failures)
        }

        private static func collisions(
            in url: URL,
        ) throws -> [Collision] {
            let data = try Data(contentsOf: url)
            let score = url.pathExtension.lowercased() == "mscx"
                ? try SheetMusic.loadScore(mscxData: data)
                : try SheetMusic.loadScore(msczData: data)
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(staffSize: 28, systemGap: 40),
                availableWidth: 1000,
            )
            var found: [Collision] = []
            for (sysIdx, system) in doc.systems.enumerated() {
                let metrics = StaffMetrics(staffSize: system.sp * 4)
                var shapes: [(LayoutShape, ShapeItemKind)] = []
                var id = 0
                for measure in system.measures {
                    let elements = measure.elements
                        + measure.markers + measure.jumps
                    for el in elements {
                        guard let kind = LayoutElementShape.kind(of: el),
                              AutoplaceRules.isAutoplaced(kind),
                              let shape = LayoutElementShape.shape(
                                  for: el, id: id,
                                  xOffset: measure.origin.x,
                                  metrics: metrics,
                              )
                        else { continue }
                        id += 1
                        shapes.append((shape, kind))
                    }
                }
                found.append(contentsOf: pairwise(
                    shapes, file: url.lastPathComponent,
                    system: sysIdx, metrics: metrics,
                ))
            }
            return found
        }

        private static func pairwise(
            _ shapes: [(LayoutShape, ShapeItemKind)],
            file: String, system: Int, metrics: StaffMetrics,
        ) -> [Collision] {
            var found: [Collision] = []
            for i in shapes.indices {
                for j in shapes.indices where j > i {
                    let (sa, ka) = shapes[i]
                    let (sb, kb) = shapes[j]
                    guard let ia = sa.rects.first?.item,
                          let ib = sb.rects.first?.item,
                          !AutoplaceRules.shouldIgnoreEachOther(ia, ib)
                    else { continue }
                    guard let d = overlapDepth(sa, sb) else { continue }
                    found.append(Collision(
                        file: file, system: system, staff: 0,
                        a: "\(ka)", b: "\(kb)", overlap: d,
                    ))
                }
            }
            return found
        }

        /// True 2D overlap between two shapes, in points, or `nil` when
        /// they do not intersect. `minVerticalDistance` is deliberately
        /// NOT used here: it answers "how far must I push this away,"
        /// is directional, and counts merely-touching rects as fully
        /// overlapping. Collision detection needs shared area.
        private static func overlapDepth(
            _ a: LayoutShape, _ b: LayoutShape,
        ) -> CGFloat? {
            // Sub-point slivers are rounding, not visible overlap.
            let epsilon: CGFloat = 0.5
            var deepest: CGFloat?
            for ra in a.rects {
                for rb in b.rects {
                    let overlapX = min(ra.rect.maxX, rb.rect.maxX)
                        - max(ra.rect.minX, rb.rect.minX)
                    let overlapY = min(ra.rect.maxY, rb.rect.maxY)
                        - max(ra.rect.minY, rb.rect.minY)
                    guard overlapX > epsilon, overlapY > epsilon
                    else { continue }
                    deepest = max(deepest ?? overlapY, overlapY)
                }
            }
            return deepest
        }

        private static func report(
            _ all: [Collision], fileCount: Int, failures: Int,
        ) {
            print("scores: \(fileCount)  parse failures: \(failures)")
            print("collisions: \(all.count)")
            var byPair: [String: Int] = [:]
            for c in all {
                let key = [c.a, c.b].sorted().joined(separator: " x ")
                byPair[key, default: 0] += 1
            }
            for (pair, count) in byPair.sorted(by: { $0.value > $1.value }) {
                print("  \(count)\t\(pair)")
            }
            for c in all.prefix(50) {
                print(
                    "\(c.file):\(c.system):\(c.staff) — "
                        + "\(c.a) x \(c.b) (\(String(format: "%.1f", c.overlap)) pt)",
                )
            }
        }
    }
#endif
