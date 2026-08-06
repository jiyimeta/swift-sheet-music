"""Dataset orchestrator (spec §6.8). Deterministic: one dataset seed
drives every generator, every style variant, and every rasterization dpi
(spec §6.7).

TWO PHASES, because the label export lives in the Swift test target
(Tests/SheetMusicTests/OMRLabelExportTests.swift) and Python cannot call
it:

    1. python Training/generate/build_dataset.py generate --root R --seed S ...
    2. OMR_DATA_ROOT=R OMR_LABEL_EXPORT=1 swift test          <- Swift
    3. python Training/generate/build_dataset.py finalize --root R --seed S

Between phase 1 and phase 3 the dataset is "generated but unlabeled":
every render directory holds `source.mscx`/`source.mscz`, `score.pdf`,
`page_<n>.png` and `render.json`, and NO `page_<n>.labels.json`. That is
a legal, inspectable resting state -- `status` names it, and every Swift
harness treats a render directory without labels as a skip rather than
an error. Phase 3 is what turns labels into `manifest.json`; nothing
before it hashes anything.

THE RASTERIZE GATE. `export_pdf.export_pdf` judges success ONLY by
output-file completeness and reports it in `ExportOutcome.ok`;
`rasterize.rasterize_pdf` deliberately does NOT re-check completeness
(it is called once per grid dpi and re-reading the trailer each time
would be wasted work). This module is therefore the ONLY thing standing
between a torn PDF and the rasterizer, and `_export_and_rasterize` below
is where that gate lives: a failed export is quarantined and the
function returns BEFORE the rasterizer is reached, and before
`render.json` is written -- so a render that failed at any point is
invisible to every downstream consumer, all of which key off
`render.json`'s presence.

SOURCE ALLOWLIST (spec §11). `collect_sources` reads this package's own
generators plus whatever directories are passed to `--extra-sources` at
RUN TIME. There is no tracked default path, no copyrighted corpus, and
no machine-specific path anywhere in this file; the owner's own
originals are named on the command line and their real filesystem origin
is recorded in each render's `render.json` provenance block (dataset
output lives outside the repo, so recording it there is the point).
"""

import argparse
import json
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

# Path bootstrap so BOTH invocation forms work, without PYTHONPATH:
#   python Training/generate/build_dataset.py ...   (from the repo root,
#       which is where `swift test` must also run, so the runbook can
#       keep one working directory throughout)
#   python -m generate.build_dataset ...            (from Training/)
# Run as a script, sys.path[0] is Training/generate/, so the `generate`
# package itself would not be importable without this.
if __package__ in (None, ""):  # pragma: no cover - exercised via subprocess
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402  (must follow the bootstrap above)

from generate import (coco_export, degrade, export_pdf,  # noqa: E402
                      gen_coverage, gen_texture, manifest, rasterize,
                      style_matrix, vocabulary)

SCHEMA = 1
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = Path(__file__).resolve().parent / "profiles" / "scanner.toml"

#: Gate P3c-G2: export success must clear this fraction of driven sources.
EXPORT_SUCCESS_FLOOR = 0.99
#: Gate P3c-G3: per-class instance floor (manifest.build_manifest default).
CLASS_FLOOR = 1000
#: Gate P3c-G4: two faces whose normalized glyph geometry agrees to
#: within this relative tolerance are the SAME outlines -- i.e. one of
#: them silently fell back. See `faces_report`.
FACE_TOL = 0.01
#: Below this many shared classes, two fingerprints are not comparable.
MIN_SHARED_CLASSES = 3


class DatasetExists(RuntimeError):
    """`generate` refused to write into a root that already holds renders."""


class DuplicateSourceID(RuntimeError):
    """Two sources claimed one id; one would have silently replaced the other."""


# ---------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------

def _mscore_bin(engine: str) -> str:
    """Read the binary path off `export_pdf` at call time (not import
    time) so a caller can override the module attribute in place."""
    return {"ms4": export_pdf.MSCORE4_BIN, "ms3": export_pdf.MSCORE3_BIN}[engine]


def collect_sources(seed: int, texture_count: int,
                    extra_sources=()) -> list[dict]:
    """Every admissible source for this dataset, sorted by `source_id`.

    Each entry is `{"source_id", "kind", "origin", "payload"}` where
    `kind` is one of `coverage` / `texture` / `extra_mscx` /
    `extra_mscz`, `origin` is the generator module or the on-disk path
    the source came from (recorded verbatim into `render.json` as
    provenance), and `payload` is `.mscx` text or `.mscz` bytes.

    Duplicate ids raise instead of silently collapsing: two
    `--extra-sources` directories that each contain `song.mscx` both map
    to `ext_song`, and a dict-built source table would keep only
    whichever was read last -- dropping one of the owner's scores from
    the dataset with no message anywhere.
    """
    out: list[dict] = []
    for source_id, text in gen_coverage.coverage_sources(seed):
        out.append({"source_id": source_id, "kind": "coverage",
                    "origin": "generate.gen_coverage", "payload": text})
    for source_id, text in gen_texture.texture_sources(seed, texture_count):
        out.append({"source_id": source_id, "kind": "texture",
                    "origin": "generate.gen_texture", "payload": text})
    for directory in sorted(Path(d) for d in extra_sources):
        for path in sorted(directory.glob("*.mscx")):
            out.append({"source_id": f"ext_{path.stem}", "kind": "extra_mscx",
                        "origin": str(path), "payload": path.read_text()})
        for path in sorted(directory.glob("*.mscz")):
            out.append({"source_id": f"extz_{path.stem}", "kind": "extra_mscz",
                        "origin": str(path), "payload": path.read_bytes()})
    seen: dict[str, str] = {}
    for source in out:
        source_id = source["source_id"]
        if source_id in seen:
            raise DuplicateSourceID(
                f"{source_id}: {seen[source_id]} and {source['origin']}")
        seen[source_id] = source["origin"]
    return sorted(out, key=lambda s: s["source_id"])


# ---------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------

@contextmanager
def _face_override(overrides: dict[str, list[str]] | None):
    """Temporarily swap `style_matrix.FACES[engine]` for a probe run.

    This is how gate P3c-G4's open questions get answered without
    editing tracked code (see `parse_face_overrides` and the README
    runbook): the candidate face is added for one probe dataset, the
    gate reports whether it rendered as its own outlines or fell back,
    and only THEN does anyone edit `style_matrix.FACES` for real.
    `style_variants` reads the table at call time, so an override here
    reaches it with the sampling semantics unchanged; the table is
    always restored, including on exceptions.
    """
    if not overrides:
        yield
        return
    original = {engine: list(style_matrix.FACES[engine]) for engine in overrides}
    try:
        for engine, faces in overrides.items():
            style_matrix.FACES[engine] = list(faces)
        yield
    finally:
        for engine, faces in original.items():
            style_matrix.FACES[engine] = faces


def _variants_by_engine(seed: int, engines: list[str], per_face: int,
                        face_overrides=None) -> dict[str, list]:
    with _face_override(face_overrides):
        return {engine: style_matrix.style_variants(
            seed=seed, engine=engine, per_face=per_face)
            for engine in sorted(engines)}


def _render_id(source_id: str, engine: str, variant, index: int) -> str:
    return f"{source_id}_{engine}_{variant.face.replace(' ', '')}_v{index}"


def plan_renders(seed: int, engines: list[str], per_face: int,
                 texture_count: int, extra_source_ids=None,
                 face_overrides=None) -> list[dict]:
    """The full render plan, sorted by `render_id`: the cross product of
    (engine x style variant x source), with each render's rasterization
    dpi already drawn from `rasterize.DPI_GRID`.

    Fully predictive of what `generate_dataset` executes -- the dpi
    included -- so the plan can be reviewed, diffed, or counted without
    invoking MuseScore. Determinism comes from a single `default_rng(seed)`
    advanced in a fixed iteration order (engines sorted, variants in
    `style_variants` order, sources sorted by id), never from
    dict/set iteration.
    """
    source_ids = sorted(
        [s["source_id"] for s in collect_sources(seed, texture_count)]
        + list(extra_source_ids or []))
    variants = _variants_by_engine(seed, engines, per_face, face_overrides)
    rng = np.random.default_rng(seed)
    plan = []
    for engine in sorted(engines):
        for index, variant in enumerate(variants[engine]):
            for source_id in source_ids:
                plan.append({
                    "render_id": _render_id(source_id, engine, variant, index),
                    "source_id": source_id,
                    "engine": engine,
                    "face": style_matrix.face_id(variant),
                    "variant_index": index,
                    "dpi": int(rng.choice(rasterize.DPI_GRID)),
                    "spatium": variant.spatium,
                    "page_w_in": variant.page_w_in,
                    "page_h_in": variant.page_h_in,
                })
    return sorted(plan, key=lambda r: r["render_id"])


# ---------------------------------------------------------------------
# Phase 1 -- generate
# ---------------------------------------------------------------------

def _render_dirs(root: Path) -> list[Path]:
    """Same filter every downstream consumer applies (`manifest.
    _render_dirs`, Swift's `OMRHarnessDirectoryWalk.renderDirectories`):
    a directory counts only once it owns a `render.json`. Since
    `render.json` is written LAST, a half-finished render is invisible
    rather than half-consumed -- and `eval_frozen/<render_id>/`, which
    holds labels but never a `render.json`, is excluded for free."""
    if not root.is_dir():
        return []
    return sorted(p for p in root.iterdir()
                  if p.is_dir() and (p / "render.json").exists())


def _write_source(render_dir: Path, source: dict, variant) -> Path:
    """Style-rewrite one source into its render directory. `.mscz` goes
    through `apply_style_mscz` (unzip / edit inner `.mscx` / re-zip)
    because `mscore -S style.mss` is silently ignored for headless PDF
    export -- see `style_matrix`'s module docstring."""
    if source["kind"] == "extra_mscz":
        path = render_dir / "source.mscz"
        path.write_bytes(style_matrix.apply_style_mscz(source["payload"], variant))
    else:
        path = render_dir / "source.mscx"
        path.write_text(style_matrix.apply_style_mscx(source["payload"], variant))
    return path


def _export_and_rasterize(entry: dict, render_dir: Path, source_path: Path,
                          exporter, rasterizer) -> tuple[bool, dict | None]:
    """Export one source to PDF, and rasterize it ONLY if the export
    passed its completeness check.

    Returns `(exported, quarantine_record)`. This is THE GATE described
    in the module docstring: `outcome.ok` is the sole authority (never
    `exit_code`, never `timed_out`, never "the file exists" -- MuseScore
    can leave a torn PDF behind AND a successful export can exit
    non-zero or hang). The early return is what keeps `rasterizer` from
    ever seeing a PDF that did not pass.
    """
    pdf_path = render_dir / "score.pdf"
    outcome = exporter(_mscore_bin(entry["engine"]), source_path, pdf_path)
    if not outcome.ok:
        return False, {
            "render_id": entry["render_id"],
            "source_id": entry["source_id"],
            "engine": entry["engine"],
            "face": entry["face"],
            "reason": outcome.reason or "export reported ok=False",
            "exit_code": outcome.exit_code,
            "timed_out": outcome.timed_out,
            "retried": outcome.retried,
        }
    rasterizer(pdf_path, render_dir, entry["dpi"])
    return True, None


def generate_dataset(root: Path, seed: int, engines: list[str], per_face: int,
                     texture_count: int, extra_sources: list[Path],
                     exporter=None, rasterizer=None, face_overrides=None,
                     allow_existing: bool = False) -> dict:
    """Phase 1: write every render directory, export, rasterize, and
    record the failures in `quarantine.json`.

    `exporter` / `rasterizer` are the injected MuseScore and pdfium
    seams (defaults are the real ones), which is what lets the whole
    orchestration be tested without either installed.
    """
    exporter = exporter or export_pdf.export_pdf
    rasterizer = rasterizer or rasterize.rasterize_pdf
    root = Path(root)
    if not allow_existing and _render_dirs(root):
        raise DatasetExists(
            f"{root} already holds render directories. Generating over them "
            "would leave the previous run's *.labels.json in place for "
            "finalize to hash as if this run had produced them. Use a fresh "
            "root, or pass allow_existing/--allow-existing deliberately.")
    root.mkdir(parents=True, exist_ok=True)

    sources = {s["source_id"]: s
               for s in collect_sources(seed, texture_count, extra_sources)}
    extra_ids = [source_id for source_id, s in sources.items()
                 if s["kind"].startswith("extra_")]
    plan = plan_renders(seed, engines, per_face, texture_count,
                        extra_source_ids=extra_ids,
                        face_overrides=face_overrides)
    variants = _variants_by_engine(seed, engines, per_face, face_overrides)

    quarantined: list[dict] = []
    exported = 0
    for entry in plan:
        source = sources[entry["source_id"]]
        variant = variants[entry["engine"]][entry["variant_index"]]
        render_dir = root / entry["render_id"]
        render_dir.mkdir(parents=True, exist_ok=True)
        source_path = _write_source(render_dir, source, variant)
        ok, record = _export_and_rasterize(
            entry, render_dir, source_path, exporter, rasterizer)
        if not ok:
            quarantined.append(record)
            continue
        # LAST, deliberately: `render.json`'s presence is what promotes
        # this directory to a real render for every consumer.
        (render_dir / "render.json").write_text(json.dumps({
            "schema": SCHEMA,
            "render_id": entry["render_id"],
            "source": source_path.name,
            "pdf": "score.pdf",
            "engine": entry["engine"],
            "face": entry["face"],
            "dpi": entry["dpi"],
            "seed": seed,
            "style": {"spatium": entry["spatium"],
                      "page_w_in": entry["page_w_in"],
                      "page_h_in": entry["page_h_in"]},
            "provenance": {"source_id": source["source_id"],
                           "kind": source["kind"],
                           "origin": source["origin"]},
        }, indent=2, sort_keys=True) + "\n")
        exported += 1

    (root / "quarantine.json").write_text(
        json.dumps(quarantined, indent=2, sort_keys=True) + "\n")
    print(f"[generate][SUMMARY] driven={len(plan)} exported={exported} "
          f"quarantined={len(quarantined)} root={root}")
    print("[generate] next (phase 2, from the repo root):")
    print(f"  OMR_DATA_ROOT={root} OMR_LABEL_EXPORT=1 swift test")
    return {"root": str(root), "driven": len(plan), "exported": exported,
            "quarantined": quarantined}


# ---------------------------------------------------------------------
# Phase 3 -- finalize
# ---------------------------------------------------------------------

def _git_commit() -> str:
    """This repository's HEAD, resolved against the repo -- not against
    whatever directory the orchestrator happens to be invoked from
    (the dataset root is outside the repo and is not a git worktree)."""
    try:
        done = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return done.stdout.strip() or "unknown"


def _engines_used(root: Path) -> list[str]:
    used = set()
    for render_dir in _render_dirs(root):
        engine = json.loads((render_dir / "render.json").read_text()).get("engine")
        if engine:
            used.add(engine)
    return sorted(used)


def finalize_dataset(root: Path, seed: int, class_floor: int = CLASS_FLOOR,
                     version_probe=None) -> dict:
    """Phase 3: build and write `manifest.json`, and score the two gates
    the dataset itself can answer (P3c-G2 export success, P3c-G3
    per-class coverage floor). The verdicts are written INTO the
    manifest so the reproducibility record and the gate result are one
    artifact.

    Only the engines that actually appear in the dataset are version-
    probed: probing MuseScore 3 for an ms4-only dataset would record an
    empty string for an engine that was never involved.
    """
    version_probe = version_probe or export_pdf.mscore_version
    root = Path(root)
    quarantine_path = root / "quarantine.json"
    quarantined = (json.loads(quarantine_path.read_text())
                   if quarantine_path.exists() else [])
    engines = {engine: version_probe(_mscore_bin(engine))
               for engine in _engines_used(root)}

    doc = manifest.build_manifest(
        root, dataset_seed=seed, engines=engines,
        renderer=rasterize.renderer_version(), generator_commit=_git_commit(),
        quarantined=quarantined, class_floor=class_floor)

    below_floor = manifest.coverage_report(doc)
    exported = len(doc["renders"])
    driven = exported + len(quarantined)
    success_rate = exported / driven if driven else 0.0
    doc["gates"] = {
        "P3c-G2": {"driven": driven, "exported": exported,
                   "success_rate": success_rate,
                   "floor": EXPORT_SUCCESS_FLOOR,
                   "pass": bool(driven) and success_rate >= EXPORT_SUCCESS_FLOOR},
        "P3c-G3": {"class_floor": class_floor,
                   "classes": len(vocabulary.CLASS_NAMES),
                   "below_floor": len(below_floor),
                   "pass": not below_floor},
    }
    manifest.write_manifest(root, doc)

    print(f"[finalize][SUMMARY] pages={doc['page_count']} "
          f"renders={exported} quarantined={len(quarantined)}")
    for line in below_floor:
        print(f"[coverage-below-floor] {line}")
    gate2, gate3 = doc["gates"]["P3c-G2"], doc["gates"]["P3c-G3"]
    print(f"[gate][SUMMARY] P3c-G2 export_success={success_rate:.4f} "
          f"({exported}/{driven}) floor={EXPORT_SUCCESS_FLOOR} "
          f"pass={'Y' if gate2['pass'] else 'N'}")
    print(f"[gate][SUMMARY] P3c-G3 below_floor={len(below_floor)}/"
          f"{len(vocabulary.CLASS_NAMES)} floor={class_floor} "
          f"pass={'Y' if gate3['pass'] else 'N'}")
    return doc


# ---------------------------------------------------------------------
# Gate P3c-G4 -- was the face actually applied?
# ---------------------------------------------------------------------
#
# MuseScore resolves an unmatched <musicalSymbolFont> SILENTLY: the
# render is labeled with the face that was asked for and drawn with the
# fallback (Bravura), with no error in any log. Neither the class census
# nor the label file can name the font -- a noteheadBlack is a
# noteheadBlack in every face -- so the only face-bearing signal the
# labels DO carry is glyph GEOMETRY: advance widths and ink boxes are
# font metrics, and two different faces cannot share them.
#
# Hence: normalize each render's per-class geometry by its own spatium
# (so page size / staff scale drop out), and compare faces of the SAME
# engine. A face whose geometry is indistinguishable from another
# face's did not get applied -- one of the two fell back. Advance is
# used alongside the ink box precisely so the gate keeps working if the
# bbox recovery chain is broken (residual risk 1).
#
# Comparisons are PER SOURCE, never over a face's whole pooled output.
# One class's geometry legitimately varies WITHIN a face by content --
# a grace notehead is a smaller `noteheadBlack` than a normal one -- so
# a face whose sources happen to be grace-heavy would look "spread out"
# enough to swamp the genuine between-face difference. Every face
# renders the same source set, so pairing face A's render of source S
# against face B's render of source S holds content fixed and leaves the
# font as the only variable. Across sources the gate then takes the
# MEDIAN, so a single source on which two faces happen to agree cannot
# fake a fallback.


def _render_fingerprint(render_dir: Path, spatium: float) -> dict[str, dict[str, float]]:
    """Per-class median of `(advance, bbox width, bbox height) / spatium`
    over every labeled page of one render. Glyphs whose `bbox_pt` is
    null contribute their advance only."""
    samples: dict[str, dict[str, list[float]]] = {}
    for label_path in sorted(render_dir.glob("page_*.labels.json")):
        doc = json.loads(label_path.read_text())
        for glyph in doc["glyphs"]:
            acc = samples.setdefault(glyph["class"],
                                     {"adv": [], "w": [], "h": []})
            acc["adv"].append(glyph["advance_pt"] / spatium)
            bbox = glyph.get("bbox_pt")
            if bbox is not None:
                acc["w"].append((bbox[2] - bbox[0]) / spatium)
                acc["h"].append((bbox[3] - bbox[1]) / spatium)
    return {cls: {key: float(np.median(values))
                  for key, values in comps.items() if values}
            for cls, comps in samples.items()}


def _aggregate_fingerprints(fingerprints: list[dict]) -> dict[str, dict[str, float]]:
    pooled: dict[str, dict[str, list[float]]] = {}
    for fingerprint in fingerprints:
        for cls, comps in fingerprint.items():
            for key, value in comps.items():
                pooled.setdefault(cls, {}).setdefault(key, []).append(value)
    return {cls: {key: float(np.median(values)) for key, values in comps.items()}
            for cls, comps in pooled.items()}


def _max_rel_diff(a: dict, b: dict) -> float | None:
    """Worst relative disagreement over the classes and components the
    two fingerprints share, or None when too few classes overlap to
    judge. MAX, not mean: two genuinely different faces need differ
    sharply in only one class (some glyphs -- a dot, a stem-like
    stroke -- look nearly the same in every face), whereas a fallback
    matches in ALL of them."""
    shared = sorted(set(a) & set(b))
    worst = 0.0
    used = 0
    for cls in shared:
        components = sorted(set(a[cls]) & set(b[cls]))
        if not components:
            continue
        used += 1
        for key in components:
            x, y = a[cls][key], b[cls][key]
            scale = max(abs(x), abs(y))
            if scale == 0:
                continue
            worst = max(worst, abs(x - y) / scale)
    return worst if used >= MIN_SHARED_CLASSES else None


def _face_distance(a: dict[str, dict], b: dict[str, dict]) -> float | None:
    """Median, over the sources both faces rendered, of the worst
    per-class disagreement on that source. None when no source is
    comparable."""
    diffs = []
    for source_id in sorted(set(a) & set(b)):
        diff = _max_rel_diff(a[source_id], b[source_id])
        if diff is not None:
            diffs.append(diff)
    return float(np.median(diffs)) if diffs else None


def faces_report(root: Path, tol: float = FACE_TOL) -> dict:
    """Gate P3c-G4. For every face in the dataset, report whether its
    glyph geometry is distinguishable from every other face of the same
    engine (`applied`). Faces are compared only WITHIN an engine: an MS3
    face matching an MS4 face says nothing about either one's fallback,
    since the outlines a face resolves to are a property of the engine
    binary.

    `self_spread` is how much a face's own renders OF ONE SOURCE differ
    from each other after normalization -- variants of one source differ
    only in spatium and page size, so this is the residual left by the
    spatium normalization itself, and a face only counts as applied when
    it out-distances both `tol` and that residual.
    """
    root = Path(root)
    samples: dict[str, dict[str, list[dict]]] = {}
    for render_dir in _render_dirs(root):
        doc = json.loads((render_dir / "render.json").read_text())
        face = doc.get("face", "")
        # Pair by source so content is held fixed across faces. A
        # dataset without provenance (hand-built fixtures) falls back to
        # one pooled bucket rather than failing.
        source_id = doc.get("provenance", {}).get("source_id", "")
        spatium = float(doc.get("style", {}).get("spatium", 0)) or 1.0
        by_source = samples.setdefault(face, {})
        fingerprint = _render_fingerprint(render_dir, spatium)
        if fingerprint:
            by_source.setdefault(source_id, []).append(fingerprint)

    aggregates = {
        face: {source_id: _aggregate_fingerprints(fps)
               for source_id, fps in by_source.items()}
        for face, by_source in samples.items()
    }
    rows = []
    for face in sorted(samples):
        by_source = samples[face]
        aggregate = aggregates[face]
        classes = sorted({cls for fp in aggregate.values() for cls in fp})
        row = {"face": face,
               "renders": sum(len(fps) for fps in by_source.values()),
               "classes": len(classes), "self_spread": 0.0,
               "nearest": None, "nearest_diff": None,
               "applied": False, "reason": ""}
        if not classes:
            row["reason"] = "no-labels"
            rows.append(row)
            continue
        spreads = [diff
                   for source_id, fps in by_source.items()
                   for diff in (_max_rel_diff(fp, aggregate[source_id])
                                for fp in fps)
                   if diff is not None]
        row["self_spread"] = max(spreads, default=0.0)
        engine = face.split("/")[0]
        candidates = []
        for other in sorted(aggregates):
            if other == face or other.split("/")[0] != engine:
                continue
            diff = _face_distance(aggregate, aggregates[other])
            if diff is not None:
                candidates.append((diff, other))
        if not candidates:
            row["reason"] = "no-comparison-face"
            rows.append(row)
            continue
        diff, nearest = min(candidates)
        row["nearest"], row["nearest_diff"] = nearest, diff
        if diff <= tol:
            row["reason"] = f"collides-with:{nearest}"
        elif diff <= row["self_spread"]:
            row["reason"] = f"within-own-spread:{nearest}"
        else:
            row["applied"] = True
        rows.append(row)
    return {"tol": tol, "faces": rows,
            "unconfirmed": [r["face"] for r in rows if not r["applied"]]}


def print_faces_report(report: dict) -> int:
    for row in report["faces"]:
        diff = "-" if row["nearest_diff"] is None else f"{row['nearest_diff']:.4f}"
        print(f"[faces][SUMMARY] face={row['face']} renders={row['renders']} "
              f"classes={row['classes']} self_spread={row['self_spread']:.4f} "
              f"nearest={row['nearest'] or '-'} nearest_diff={diff} "
              f"applied={'Y' if row['applied'] else 'N'} "
              f"reason={row['reason'] or '-'}")
    total = len(report["faces"])
    applied = total - len(report["unconfirmed"])
    print(f"[gate][SUMMARY] P3c-G4 applied={applied}/{total} "
          f"pass={'Y' if applied == total and total else 'N'}")
    return 0 if total and not report["unconfirmed"] else 1


# ---------------------------------------------------------------------
# Frozen eval set / status / COCO
# ---------------------------------------------------------------------

def freeze_dataset(root: Path, seed: int, profile_path: Path = DEFAULT_PROFILE,
                   out_name: str = "eval_frozen") -> dict:
    """Spec §6.5: degrade every clean page ONCE, with a recorded seed,
    into `<root>/<out_name>/<render_id>/`, so eval numbers stay
    comparable across time (training-time degradation is applied fresh
    each epoch instead and is not this).

    Per-page seeds are drawn from `default_rng(seed + 1)` over the
    sorted page list, so re-running reproduces byte-identical output and
    a page's degradation does not depend on how many pages preceded it
    in the walk. The output is not re-walked on a second run: it carries
    labels but no `render.json`, and `_render_dirs` keys off exactly
    that.
    """
    root = Path(root)
    out_root = root / out_name
    profile = degrade.load_profile(profile_path)
    pages = []
    for render_dir in _render_dirs(root):
        for label_path in sorted(render_dir.glob("page_*.labels.json")):
            doc = json.loads(label_path.read_text())
            png = render_dir / doc["image"]["file"]
            if png.exists():
                pages.append((render_dir.name, png, label_path))
    child_seeds = np.random.default_rng(seed + 1).integers(
        0, 2 ** 32, size=len(pages))
    for index, (render_id, png, label_path) in enumerate(pages):
        degrade.freeze_eval_page(
            png, label_path, out_root / render_id, profile,
            np.random.default_rng(int(child_seeds[index])))
    print(f"[freeze][SUMMARY] pages={len(pages)} out={out_root} "
          f"profile={profile_path}")
    return {"pages": len(pages), "out": str(out_root),
            "profile": str(profile_path)}


def dataset_status(root: Path) -> dict:
    """Which phase the dataset is in, and the exact next command."""
    root = Path(root)
    render_dirs = _render_dirs(root)
    label_counts = [len(list(d.glob("page_*.labels.json"))) for d in render_dirs]
    quarantine_path = root / "quarantine.json"
    quarantined = (len(json.loads(quarantine_path.read_text()))
                   if quarantine_path.exists() else 0)
    has_manifest = (root / "manifest.json").exists()
    with_labels = sum(1 for n in label_counts if n)
    if not render_dirs:
        phase, nxt = "empty", (
            f"python Training/generate/build_dataset.py generate "
            f"--root {root} --seed <SEED>")
    elif not with_labels:
        phase, nxt = "generated", (
            f"OMR_DATA_ROOT={root} OMR_LABEL_EXPORT=1 swift test")
    elif not has_manifest:
        phase, nxt = "labeled", (
            f"python Training/generate/build_dataset.py finalize "
            f"--root {root} --seed <SEED>")
    else:
        phase, nxt = "finalized", (
            f"python Training/generate/build_dataset.py faces --root {root}")
    return {"root": str(root), "phase": phase, "render_dirs": len(render_dirs),
            "renders_with_labels": with_labels, "label_files": sum(label_counts),
            "quarantined": quarantined, "manifest": has_manifest,
            "eval_frozen": (root / "eval_frozen").is_dir(), "next": nxt}


# ---------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------

def parse_face_overrides(items) -> dict[str, list[str]]:
    """`["ms3=Bravura,Petaluma"]` -> `{"ms3": ["Bravura", "Petaluma"]}`.

    The engine must be a known key of `style_matrix.FACES`; the face
    NAMES are deliberately not validated, because the whole point of a
    probe is to try a face the table does not list yet. A name MuseScore
    does not recognize falls back silently -- which is exactly what the
    face gate then reports."""
    overrides: dict[str, list[str]] = {}
    for item in items or []:
        if "=" not in item:
            raise ValueError(f"--probe-faces expects ENGINE=Face,Face: {item!r}")
        engine, _, faces = item.partition("=")
        if engine not in style_matrix.FACES:
            raise ValueError(f"unknown engine {engine!r} "
                             f"(known: {sorted(style_matrix.FACES)})")
        names = [f.strip() for f in faces.split(",") if f.strip()]
        if not names:
            raise ValueError(f"--probe-faces listed no face for {engine!r}")
        overrides[engine] = names
    return overrides


def _parse_engines(value: str) -> list[str]:
    engines = [e.strip() for e in value.split(",") if e.strip()]
    unknown = [e for e in engines if e not in style_matrix.FACES]
    if unknown:
        raise ValueError(f"unknown engine(s) {unknown} "
                         f"(known: {sorted(style_matrix.FACES)})")
    return engines


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="build_dataset",
        description="Synthetic OMR dataset orchestrator (spec §6.8). "
                    "Exit code 1 means a gate failed (compare, faces).")
    sub = parser.add_subparsers(dest="cmd", required=True)

    gen = sub.add_parser("generate", help="phase 1: sources -> PDF -> raster")
    gen.add_argument("--root", required=True)
    gen.add_argument("--seed", type=int, required=True)
    gen.add_argument("--engines", default="ms4")
    gen.add_argument("--per-face", type=int, default=1)
    gen.add_argument("--textures", type=int, default=20)
    gen.add_argument("--extra-sources", nargs="*", default=[])
    gen.add_argument("--probe-faces", nargs="*", default=[],
                     metavar="ENGINE=Face,Face")
    gen.add_argument("--allow-existing", action="store_true")

    fin = sub.add_parser("finalize", help="phase 3: manifest + P3c-G2/G3")
    fin.add_argument("--root", required=True)
    fin.add_argument("--seed", type=int, required=True)
    fin.add_argument("--class-floor", type=int, default=CLASS_FLOOR)

    status = sub.add_parser("status", help="which phase this dataset is in")
    status.add_argument("--root", required=True)

    faces = sub.add_parser("faces", help="gate P3c-G4: was each face applied")
    faces.add_argument("--root", required=True)
    faces.add_argument("--tol", type=float, default=FACE_TOL)

    freeze = sub.add_parser("freeze", help="spec §6.5 frozen eval set")
    freeze.add_argument("--root", required=True)
    freeze.add_argument("--seed", type=int, required=True)
    freeze.add_argument("--profile", default=str(DEFAULT_PROFILE))

    coco = sub.add_parser("coco", help="convenience COCO detection export")
    coco.add_argument("--root", required=True)
    coco.add_argument("--out", default=None)

    compare = sub.add_parser("compare", help="gate P3c-G1: byte identity")
    compare.add_argument("root_a")
    compare.add_argument("root_b")
    return parser


def main(argv=None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.cmd == "generate":
        try:
            engines = _parse_engines(args.engines)
            overrides = parse_face_overrides(args.probe_faces)
        except ValueError as error:
            parser.error(str(error))  # exits 2, no traceback
        generate_dataset(
            Path(args.root), args.seed, engines,
            args.per_face, args.textures,
            [Path(p) for p in args.extra_sources],
            face_overrides=overrides,
            allow_existing=args.allow_existing)
        return 0
    if args.cmd == "finalize":
        finalize_dataset(Path(args.root), args.seed,
                         class_floor=args.class_floor)
        return 0
    if args.cmd == "status":
        state = dataset_status(Path(args.root))
        print(f"[status] root={state['root']} phase={state['phase']} "
              f"render_dirs={state['render_dirs']} "
              f"renders_with_labels={state['renders_with_labels']} "
              f"label_files={state['label_files']} "
              f"quarantined={state['quarantined']} "
              f"manifest={'Y' if state['manifest'] else 'N'} "
              f"eval_frozen={'Y' if state['eval_frozen'] else 'N'}")
        print(f"[status] next: {state['next']}")
        return 0
    if args.cmd == "faces":
        return print_faces_report(faces_report(Path(args.root), tol=args.tol))
    if args.cmd == "freeze":
        freeze_dataset(Path(args.root), args.seed, Path(args.profile))
        return 0
    if args.cmd == "coco":
        root = Path(args.root)
        out = Path(args.out) if args.out else root / "coco.json"
        print(f"[coco][SUMMARY] out={coco_export.write_coco(root, out)}")
        return 0
    problems = manifest.compare_datasets(Path(args.root_a), Path(args.root_b))
    for problem in problems:
        print(f"[compare] {problem}")
    print(f"[compare][SUMMARY] identical={'N' if problems else 'Y'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
