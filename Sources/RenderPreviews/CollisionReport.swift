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
    ///   SM_COLLIDE_LIST — max individual collisions to list (default 50)
    ///   SM_COLLIDE_SPANNERS — also pair `system.spanners` against the
    ///     per-measure elements (off by default so the historical
    ///     annotation-only count stays comparable across runs)
    ///   SM_COLLIDE_BASE — also pair every autoplaced item against the
    ///     NON-autoplaced (base-skyline) shapes: chords, beams, rests,
    ///     articulations, fermatas, clefs, bar lines … (off by default,
    ///     same comparability reason)
    ///
    /// No score path is hardcoded and no result is committed — the
    /// corpus is the author's private library.
    ///
    /// **Reach.** The count is a lower bound, not a proof of absence.
    /// Two whole classes of pair are excluded from the default walk:
    ///
    /// - **Base-skyline kinds** (chords, articulations, fermatas,
    ///   breaths, clefs …) are filtered out by `isAutoplaced`. That
    ///   makes the default count blind to "an annotation sits on top of
    ///   a notehead" — the class this detector could not see at all
    ///   before `SM_COLLIDE_BASE`. Note that even with the flag on,
    ///   base × base is deliberately NOT walked: those shapes are placed
    ///   by the engraving rules rather than by autoplace, and a vertical
    ///   error in one of them moves every annotation that clears it
    ///   CONSISTENTLY, so it still reports zero.
    ///   `LayoutElementShapeTests` pins those bands positionally for
    ///   that reason.
    /// - **Spanner segments** are off by default: the walk covers
    ///   `measure.elements + markers + jumps`, while hairpins, pedals,
    ///   voltas, ottavas and text lines are synthesized into
    ///   `LayoutSystem.spanners` by `LayoutEngine+Spanners`. Set
    ///   `SM_COLLIDE_SPANNERS=1` to fold them in — they are reported
    ///   under the same pair histogram, so the total is no longer
    ///   comparable with a run that leaves the flag off.
    ///
    /// `SM_COLLIDE_SPANNERS=1 SM_COLLIDE_BASE=1` together are what make
    /// "a below-staff hairpin overlaps a low ledger-line note" a
    /// reportable pair.
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

        /// Whether `system.spanners` participates. Off by default.
        private static var includesSpanners: Bool {
            ProcessInfo.processInfo.environment["SM_COLLIDE_SPANNERS"] != nil
        }

        /// Whether NON-autoplaced shapes participate as the second side
        /// of a pair. Off by default.
        private static var includesBaseShapes: Bool {
            ProcessInfo.processInfo.environment["SM_COLLIDE_BASE"] != nil
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
                // Autoplaced items pair against each other AND (under
                // `SM_COLLIDE_BASE`) against the base shapes. Base
                // shapes never pair with each other — see the type doc.
                var shapes: [(LayoutShape, ShapeItemKind)] = []
                var baseShapes: [(LayoutShape, ShapeItemKind)] = []
                var id = 0
                func collect(
                    _ el: LayoutElement, xOffset: CGFloat,
                ) {
                    guard let kind = LayoutElementShape.kind(of: el)
                    else { return }
                    let autoplaced = AutoplaceRules.isAutoplaced(kind)
                    guard autoplaced || includesBaseShapes else { return }
                    guard let shape = LayoutElementShape.shape(
                        for: el, id: id, xOffset: xOffset,
                        metrics: metrics,
                    ) else { return }
                    id += 1
                    if autoplaced {
                        shapes.append((shape, kind))
                    } else {
                        baseShapes.append((shape, kind))
                    }
                }
                for measure in system.measures {
                    let elements = measure.elements
                        + measure.markers + measure.jumps
                    for el in elements {
                        collect(el, xOffset: measure.origin.x)
                    }
                }
                if includesSpanners {
                    // Spanner origins are already system-local, so no
                    // per-measure `xOffset` applies here.
                    for el in system.spanners {
                        collect(el, xOffset: 0)
                    }
                }
                found.append(contentsOf: pairwise(
                    shapes, file: url.lastPathComponent, system: sysIdx,
                ))
                found.append(contentsOf: crossPairs(
                    shapes, baseShapes,
                    file: url.lastPathComponent, system: sysIdx,
                ))
            }
            return found
        }

        private static func pairwise(
            _ shapes: [(LayoutShape, ShapeItemKind)],
            file: String, system: Int,
        ) -> [Collision] {
            var found: [Collision] = []
            for i in shapes.indices {
                for j in shapes.indices where j > i {
                    if let c = collision(
                        shapes[i], shapes[j], file: file, system: system,
                    ) {
                        found.append(c)
                    }
                }
            }
            return found
        }

        /// Every `a × b` across the two lists. Used for
        /// autoplaced × base, where no `j > i` de-duplication applies
        /// because the lists are disjoint.
        private static func crossPairs(
            _ a: [(LayoutShape, ShapeItemKind)],
            _ b: [(LayoutShape, ShapeItemKind)],
            file: String, system: Int,
        ) -> [Collision] {
            guard !a.isEmpty, !b.isEmpty else { return [] }
            var found: [Collision] = []
            for lhs in a {
                for rhs in b {
                    if let c = collision(
                        lhs, rhs, file: file, system: system,
                    ) {
                        found.append(c)
                    }
                }
            }
            return found
        }

        private static func collision(
            _ lhs: (LayoutShape, ShapeItemKind),
            _ rhs: (LayoutShape, ShapeItemKind),
            file: String, system: Int,
        ) -> Collision? {
            let (sa, ka) = lhs
            let (sb, kb) = rhs
            guard let ia = sa.rects.first?.item,
                  let ib = sb.rects.first?.item,
                  !ignoreForReporting(ia, ib),
                  let d = overlapDepth(sa, sb)
            else { return nil }
            return Collision(
                file: file, system: system, staff: 0,
                a: "\(ka)", b: "\(kb)", overlap: d,
            )
        }

        /// Reporting policy, which is deliberately NOT the autoplace
        /// policy. `AutoplaceRules.shouldIgnoreEachOther` exempts
        /// `dynamics × hairpin` because the pass must not push them
        /// apart VERTICALLY — MuseScore snaps them into one chain and
        /// resolves the clash horizontally instead. That exemption says
        /// nothing about whether ink ends up on top of ink, so for
        /// detection the pair stays in.
        private static func ignoreForReporting(
            _ a: ShapeItem, _ b: ShapeItem,
        ) -> Bool {
            if Set([a.kind, b.kind]) == Set([ShapeItemKind.dynamics, .hairpin]) {
                return a.id == b.id
            }
            return AutoplaceRules.shouldIgnoreEachOther(a, b)
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
            let listLimit = ProcessInfo.processInfo
                .environment["SM_COLLIDE_LIST"].flatMap { Int($0) } ?? 50
            for c in all.prefix(listLimit) {
                print(
                    "\(c.file):\(c.system):\(c.staff) — "
                        + "\(c.a) x \(c.b) (\(String(format: "%.1f", c.overlap)) pt)",
                )
            }
        }
    }
#endif
