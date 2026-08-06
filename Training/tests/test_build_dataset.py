"""Orchestrator tests. Hermetic by construction: no MuseScore, no
network, no dataset on disk -- the MuseScore boundary is the injected
`exporter` seam and the pdfium boundary is the injected `rasterizer`
seam, so every test here runs against `tmp_path` alone.
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from generate import build_dataset, rasterize
from generate.export_pdf import ExportOutcome
from tests.pdf_builder import music_pdf


class _ExporterSpy:
    """Injected stand-in for `export_pdf.export_pdf`.

    `writes_pdf` is deliberately independent of `ok`: the interesting
    case for the rasterize gate is an exporter that FAILED its
    completeness check yet still left a file at `out_pdf` (exactly what
    a torn MuseScore export looks like on disk). Only an `ok`-driven
    gate can skip that file; a mere `out_pdf.exists()` check could not.
    """

    def __init__(self, ok=True, writes_pdf=True):
        self.ok = ok
        self.writes_pdf = writes_pdf
        self.calls = []

    def __call__(self, mscore_bin, source, out_pdf, timeout_s=300.0, run=None):
        self.calls.append((str(mscore_bin), Path(source).name))
        if self.writes_pdf:
            Path(out_pdf).write_bytes(b"%PDF-1.4 fake\n%%EOF")
        return ExportOutcome(ok=self.ok, timed_out=False, exit_code=0,
                             retried=False, reason="" if self.ok else "boom")


class _RasterizerSpy:
    """Injected stand-in for `rasterize.rasterize_pdf`. Writes a REAL
    (tiny) grayscale PNG, because downstream consumers read the rendered
    image's actual pixel size rather than recomputing it."""

    def __init__(self):
        self.calls = []

    def __call__(self, pdf_path, out_dir, dpi):
        self.calls.append((Path(pdf_path).name, int(dpi)))
        out = Path(out_dir) / "page_0.png"
        Image.fromarray(np.zeros((8, 6), dtype=np.uint8)).save(out)
        return [out]


def _generate(tmp_path, **kwargs):
    """`generate_dataset` with the small deterministic defaults every
    test here shares, plus injected seams."""
    params = dict(seed=3, engines=["ms4"], per_face=1, texture_count=0,
                  extra_sources=[], exporter=_ExporterSpy(),
                  rasterizer=_RasterizerSpy())
    params.update(kwargs)
    return build_dataset.generate_dataset(tmp_path, **params), params


# --------------------------------------------------------------------
# Plan
# --------------------------------------------------------------------

def test_plan_is_deterministic_and_engine_qualified():
    a = build_dataset.plan_renders(seed=3, engines=["ms4"], per_face=1,
                                   texture_count=2)
    assert a == build_dataset.plan_renders(seed=3, engines=["ms4"], per_face=1,
                                           texture_count=2)
    assert all(r["face"].startswith("ms4/") for r in a)
    ids = [r["render_id"] for r in a]
    assert ids == sorted(ids)
    assert len(set(ids)) == len(ids)


def test_plan_assigns_every_render_a_dpi_from_the_grid():
    """The plan is fully predictive of what `generate_dataset` executes,
    dpi included -- so a reviewer can read the plan without running it."""
    plan = build_dataset.plan_renders(seed=3, engines=["ms4"], per_face=1,
                                      texture_count=1)
    assert plan
    assert {r["dpi"] for r in plan} <= set(rasterize.DPI_GRID)
    # Not a constant column: the grid is actually sampled.
    assert len({r["dpi"] for r in plan}) > 1


def test_plan_predicts_exactly_what_generate_executes(tmp_path):
    summary, params = _generate(tmp_path, texture_count=1)
    plan = build_dataset.plan_renders(
        seed=3, engines=["ms4"], per_face=1, texture_count=1)
    planned = {r["render_id"]: r["dpi"] for r in plan}
    actual = {}
    for render_json in sorted(tmp_path.glob("*/render.json")):
        doc = json.loads(render_json.read_text())
        actual[doc["render_id"]] = doc["dpi"]
    assert actual == planned
    assert summary["exported"] == len(planned)


# --------------------------------------------------------------------
# Generate
# --------------------------------------------------------------------

def test_generate_writes_render_dirs_and_quarantines(tmp_path):
    summary, _ = _generate(tmp_path, texture_count=1)
    dirs = [p for p in tmp_path.iterdir() if p.is_dir()]
    assert dirs
    assert summary["exported"] == len(dirs)
    first = sorted(dirs)[0]
    render = json.loads((first / "render.json").read_text())
    assert {"render_id", "source", "pdf", "engine", "face", "dpi", "seed",
            "style", "provenance"} <= set(render)
    assert render["engine"] == "ms4"
    assert render["face"].startswith("ms4/")
    assert render["seed"] == 3
    assert render["pdf"] == "score.pdf"
    assert set(render["style"]) == {"spatium", "page_w_in", "page_h_in"}
    assert (first / "source.mscx").exists()
    assert (first / "score.pdf").exists()
    assert (first / "page_0.png").exists()


def test_generate_records_quarantines_and_continues(tmp_path):
    summary, _ = _generate(tmp_path, texture_count=1,
                           exporter=_ExporterSpy(ok=False))
    assert summary["exported"] == 0
    q = json.loads((tmp_path / "quarantine.json").read_text())
    assert q
    assert all({"render_id", "reason"} <= set(item) for item in q)
    assert summary["quarantined"] == q
    # Continued to the end rather than aborting on the first failure.
    assert len(q) == summary["driven"]


def test_generate_never_rasterizes_a_pdf_that_failed_the_export_gate(tmp_path):
    """THE `ExportOutcome.ok` GATE. `rasterize_pdf` deliberately does not
    re-check completeness (it is called once per grid dpi), so the
    orchestrator is the only thing standing between a torn PDF and the
    rasterizer. The fake exporter here leaves a file at `out_pdf` and
    still reports `ok=False`, so nothing but an `ok`-driven gate can
    keep the rasterizer away from it."""
    rasterizer = _RasterizerSpy()
    exporter = _ExporterSpy(ok=False, writes_pdf=True)
    summary, _ = _generate(tmp_path, texture_count=1,
                           exporter=exporter, rasterizer=rasterizer)
    assert exporter.calls              # it really did try to export
    assert rasterizer.calls == []      # ... and never rasterized anything
    assert summary["exported"] == 0
    assert list(tmp_path.rglob("page_*.png")) == []
    assert list(tmp_path.rglob("render.json")) == []


def test_generate_rasterizes_each_exported_pdf_once_at_its_planned_dpi(tmp_path):
    rasterizer = _RasterizerSpy()
    summary, _ = _generate(tmp_path, texture_count=1, rasterizer=rasterizer)
    assert len(rasterizer.calls) == summary["exported"]
    assert {name for name, _ in rasterizer.calls} == {"score.pdf"}
    planned = sorted(r["dpi"] for r in build_dataset.plan_renders(
        seed=3, engines=["ms4"], per_face=1, texture_count=1))
    assert sorted(dpi for _, dpi in rasterizer.calls) == planned


def test_generate_refuses_a_root_that_already_holds_renders(tmp_path):
    """Regenerating over an existing dataset would leave the previous
    run's `*.labels.json` in place, and `finalize` would hash them into
    the new manifest as if the current run had produced them."""
    _generate(tmp_path, texture_count=0)
    with pytest.raises(build_dataset.DatasetExists):
        _generate(tmp_path, texture_count=0)
    # The escape hatch exists and is explicit.
    summary, _ = _generate(tmp_path, texture_count=0, allow_existing=True)
    assert summary["exported"] > 0


def test_extra_sources_are_carried_with_provenance(tmp_path):
    import zipfile

    extra = tmp_path / "extra"
    extra.mkdir()
    from generate import gen_coverage
    mscx_text = gen_coverage.coverage_sources(1)[0][1]
    (extra / "own_song.mscx").write_text(mscx_text)
    buf = extra / "own_zipped.mscz"
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("own_zipped.mscx", mscx_text)

    root = tmp_path / "ds"
    build_dataset.generate_dataset(
        root, seed=3, engines=["ms4"], per_face=1, texture_count=0,
        extra_sources=[extra], exporter=_ExporterSpy(),
        rasterizer=_RasterizerSpy())
    by_source = {}
    for render_json in sorted(root.glob("*/render.json")):
        doc = json.loads(render_json.read_text())
        by_source.setdefault(doc["provenance"]["source_id"], doc)

    assert "ext_own_song" in by_source
    assert "extz_own_zipped" in by_source
    assert by_source["ext_own_song"]["provenance"]["kind"] == "extra_mscx"
    assert by_source["ext_own_song"]["source"] == "source.mscx"
    assert by_source["extz_own_zipped"]["provenance"]["kind"] == "extra_mscz"
    assert by_source["extz_own_zipped"]["source"] == "source.mscz"
    # Provenance records where the owner's original actually came from.
    assert by_source["ext_own_song"]["provenance"]["origin"] == str(
        extra / "own_song.mscx")
    # And the generated ones say so too, without a filesystem origin.
    generated = [d for d in by_source.values()
                 if d["provenance"]["kind"] == "coverage"]
    assert generated
    assert generated[0]["provenance"]["origin"] == "generate.gen_coverage"
    # The .mscz arm really did rewrite the zip, not copy it.
    styled = (root / by_source["extz_own_zipped"]["render_id"] / "source.mscz")
    with zipfile.ZipFile(styled) as z:
        inner = z.read("own_zipped.mscx").decode("utf-8")
    assert "<musicalSymbolFont>" in inner


def test_an_extra_source_with_no_style_block_is_quarantined_by_name(tmp_path):
    """Whole-branch review, Important 3. `--extra-sources` accepts
    arbitrary user-authored scores (the runbook's step 1 tells the
    operator to pass exactly that), and one with no `<Style>` element
    used to be style-rewritten into a silent no-op: exported in
    MuseScore's DEFAULT face while `dataset_plan.json` and `render.json`
    both recorded the face that was requested.

    Now it never reaches the exporter. Asserts the whole record, and
    that the reason names the offending file, because "it was
    quarantined somehow" would also be satisfied by an unrelated
    failure."""
    extra = tmp_path / "extra"
    extra.mkdir()
    from generate import gen_coverage
    styleless = gen_coverage.coverage_sources(1)[0][1].replace(
        "<Style>\n      <Spatium>1.76389</Spatium>\n    </Style>\n", "")
    assert "<Style>" not in styleless
    (extra / "no_style.mscx").write_text(styleless)

    root = tmp_path / "ds"
    exporter = _ExporterSpy()
    summary = build_dataset.generate_dataset(
        root, seed=3, engines=["ms4"], per_face=1, texture_count=0,
        extra_sources=[extra], exporter=exporter,
        rasterizer=_RasterizerSpy())

    offending = [q for q in summary["quarantined"]
                 if q["source_id"] == "ext_no_style"]
    assert offending, "the styleless source must be quarantined"
    for record in offending:
        assert record["reason"].startswith("style-not-applied:")
        assert str(extra / "no_style.mscx") in record["reason"]
        assert record["engine"] == "ms4"
        assert record["face"].startswith("ms4/")
        assert set(record) == {"render_id", "source_id", "engine", "face",
                               "reason", "exit_code", "timed_out", "retried"}
        # Never exported, so no render.json can claim a face for it, and
        # no styled source was left behind either.
        assert not (root / record["render_id"] / "render.json").exists()
        assert not (root / record["render_id"] / "source.mscx").exists()
    # It never reached MuseScore at all: the exporter ran once per
    # render that survived `_write_source`, not once per planned render.
    assert len(exporter.calls) == summary["exported"]
    assert len(exporter.calls) == summary["driven"] - len(offending)
    assert all(q["source_id"] == "ext_no_style" for q in summary["quarantined"])
    # The rest of the dataset still built.
    assert summary["exported"] > 0
    assert summary["driven"] == summary["exported"] + len(summary["quarantined"])


def test_duplicate_extra_source_ids_are_rejected(tmp_path):
    """Two directories each holding `song.mscx` would silently collapse
    into one source (last write wins) if ids were not checked."""
    a, b = tmp_path / "a", tmp_path / "b"
    for d in (a, b):
        d.mkdir()
        (d / "song.mscx").write_text("<museScore><Score></Score></museScore>")
    with pytest.raises(build_dataset.DuplicateSourceID):
        build_dataset.collect_sources(seed=3, texture_count=0,
                                      extra_sources=[a, b])


# --------------------------------------------------------------------
# Finalize
# --------------------------------------------------------------------

def _write_labels(render_dir: Path, page: int, glyphs: list[dict],
                  census: dict[str, int]) -> None:
    (render_dir / f"page_{page}.labels.json").write_text(json.dumps({
        "schema": 1,
        "page": {"index": page, "width_pt": 595.0, "height_pt": 842.0},
        "image": {"file": f"page_{page}.png", "dpi": 300,
                  "label_transform": [1, 0, 0, 0, 1, 0, 0, 0, 1]},
        "glyphs": glyphs, "paths": [], "beams": [], "curves": [], "texts": [],
        "census": {"glyphs_by_class": census, "texts": 0},
    }, indent=2, sort_keys=True) + "\n")


def _glyph(cls: str, w: float, h: float, adv: float) -> dict:
    return {"class": cls, "bbox_pt": [10.0, 10.0, 10.0 + w, 10.0 + h],
            "origin_pt": [10.0, 10.0], "advance_pt": adv,
            "rendered_size_pt": 5.0, "font_size_pt": 0.0}


def test_finalize_builds_manifest(tmp_path):
    _generate(tmp_path, texture_count=0)
    first = sorted(p for p in tmp_path.iterdir() if p.is_dir())[0]
    _write_labels(first, 0, [], {"noteheadBlack": 3})
    summary = build_dataset.finalize_dataset(tmp_path, seed=3,
                                             version_probe=lambda _b: "")
    assert (tmp_path / "manifest.json").exists()
    assert summary["class_counts"]["noteheadBlack"] == 3
    assert summary["dataset_seed"] == 3
    assert summary["page_count"] == 1
    on_disk = json.loads((tmp_path / "manifest.json").read_text())
    assert on_disk == summary


def _summary_fields(line: str) -> dict:
    """`[gate][SUMMARY] P3c-G1-selfcheck labels=1 problems=0 pass=Y` ->
    `{"labels": "1", "problems": "0", "pass": "Y"}`. Parsing the line
    into fields keeps these assertions off substring matching."""
    return dict(token.split("=", 1) for token in line.split() if "=" in token)


def test_finalize_self_checks_the_manifest_it_just_wrote(tmp_path, capsys):
    """Whole-branch review, Minor 3: `manifest.verify_manifest` had no
    caller anywhere in `generate/` and no subcommand -- it could not be
    run at all. `finalize` is its natural home: two-root byte identity
    (`compare`, P3c-G1) only means something if each manifest actually
    describes the dataset next to it, and this is the moment that is
    still cheap to assert."""
    _generate(tmp_path, texture_count=0)
    first = sorted(p for p in tmp_path.iterdir() if p.is_dir())[0]
    _write_labels(first, 0, [_glyph("noteheadBlack", 6, 5, 7)],
                  {"noteheadBlack": 1})
    doc = build_dataset.finalize_dataset(tmp_path, seed=3,
                                         version_probe=lambda _b: "")

    lines = [line for line in capsys.readouterr().out.splitlines()
             if "P3c-G1-selfcheck" in line]
    assert len(lines) == 1
    fields = _summary_fields(lines[0])
    assert fields["labels"] == "1" == str(len(doc["label_sha256"]))
    assert fields["problems"] == "0"
    assert fields["pass"] == "Y"


def test_finalize_self_check_fails_when_the_manifest_did_not_survive(
        tmp_path, capsys, monkeypatch):
    """The self-check must be a real read-back, not a formatting
    flourish: a `manifest.json` that is truncated on the way to disk is
    reported as a problem and flips the line to `pass=N`. Exercises the
    malformed-manifest guard through the wiring, and would fail against
    any implementation that prints the line without calling
    `verify_manifest`."""
    _generate(tmp_path, texture_count=0)
    first = sorted(p for p in tmp_path.iterdir() if p.is_dir())[0]
    _write_labels(first, 0, [_glyph("noteheadBlack", 6, 5, 7)],
                  {"noteheadBlack": 1})

    real_write = build_dataset.manifest.write_manifest

    def truncating_write(root, doc):
        path = Path(real_write(root, doc))
        path.write_text(path.read_text()[:40])
        return path

    monkeypatch.setattr(build_dataset.manifest, "write_manifest",
                        truncating_write)
    build_dataset.finalize_dataset(tmp_path, seed=3, version_probe=lambda _b: "")

    out = capsys.readouterr().out.splitlines()
    gate = [line for line in out if "P3c-G1-selfcheck" in line]
    assert len(gate) == 1
    fields = _summary_fields(gate[0])
    assert fields["problems"] == "1"
    assert fields["pass"] == "N"
    assert [line for line in out
            if line.startswith("[verify] manifest unreadable:")]


def test_finalize_records_only_engines_the_dataset_actually_used(tmp_path):
    _generate(tmp_path, texture_count=0)
    probed = []

    def probe(binary):
        probed.append(binary)
        return "MuseScore 4.4.2"

    summary = build_dataset.finalize_dataset(tmp_path, seed=3,
                                             version_probe=probe)
    assert set(summary["engines"]) == {"ms4"}
    assert summary["engines"]["ms4"] == "MuseScore 4.4.2"
    assert len(probed) == 1


def test_finalize_scores_the_export_and_coverage_gates(tmp_path):
    _generate(tmp_path, texture_count=0)
    dirs = sorted(p for p in tmp_path.iterdir() if p.is_dir())
    _write_labels(dirs[0], 0, [], {"noteheadBlack": 3})
    gates = build_dataset.finalize_dataset(
        tmp_path, seed=3, class_floor=2, version_probe=lambda _b: "",
    )["gates"]
    # Nothing was quarantined by the ok=True exporter -> P3c-G2 passes.
    assert gates["P3c-G2"]["driven"] == len(dirs)
    assert gates["P3c-G2"]["exported"] == len(dirs)
    assert gates["P3c-G2"]["success_rate"] == 1.0
    assert gates["P3c-G2"]["pass"] is True
    # Only one class cleared the floor of 2, so the coverage gate fails.
    assert gates["P3c-G3"]["pass"] is False
    assert gates["P3c-G3"]["below_floor"] == len(
        build_dataset.vocabulary.CLASS_NAMES) - 1


def test_export_success_gate_fails_below_the_threshold(tmp_path):
    _generate(tmp_path, texture_count=0, exporter=_ExporterSpy(ok=False))
    gates = build_dataset.finalize_dataset(
        tmp_path, seed=3, version_probe=lambda _b: "")["gates"]
    assert gates["P3c-G2"]["exported"] == 0
    assert gates["P3c-G2"]["success_rate"] == 0.0
    assert gates["P3c-G2"]["pass"] is False


def test_generate_records_the_plan_it_drove(tmp_path):
    """`dataset_plan.json` is what makes the two later phases able to
    tell "this render never happened" from "this render never existed"."""
    summary, _ = _generate(tmp_path, texture_count=0)
    plan = json.loads((tmp_path / "dataset_plan.json").read_text())
    assert plan["planned_renders"] == summary["driven"]
    assert plan["seed"] == 3
    assert plan["engines"] == ["ms4"]
    assert plan["expected_faces"] == sorted(
        f"ms4/{face}" for face in build_dataset.style_matrix.FACES["ms4"])
    # No machine-specific path is recorded here; provenance lives per
    # render, and this file is compared across hosts.
    assert plan["extra_source_ids"] == []


def test_export_gate_uses_the_planned_denominator_not_what_survived(tmp_path):
    """An interrupted `generate` leaves renders that were neither
    exported nor quarantined. Recomputing the denominator from disk
    counts only the survivors, so a run that died a third of the way
    through reports a perfect export rate."""
    _generate(tmp_path, texture_count=0)
    planned = json.loads(
        (tmp_path / "dataset_plan.json").read_text())["planned_renders"]
    dirs = sorted(p for p in tmp_path.iterdir() if p.is_dir())
    for stale in dirs[: len(dirs) // 2]:
        shutil.rmtree(stale)
    gates = build_dataset.finalize_dataset(
        tmp_path, seed=3, version_probe=lambda _b: "")["gates"]
    assert gates["P3c-G2"]["driven"] == planned
    assert gates["P3c-G2"]["exported"] == len(dirs) - len(dirs) // 2
    assert gates["P3c-G2"]["missing"] == len(dirs) // 2
    assert gates["P3c-G2"]["pass"] is False


def test_export_gate_falls_back_to_disk_when_no_plan_was_written(tmp_path):
    _generate(tmp_path, texture_count=0)
    (tmp_path / "dataset_plan.json").unlink()
    gates = build_dataset.finalize_dataset(
        tmp_path, seed=3, version_probe=lambda _b: "")["gates"]
    dirs = [p for p in tmp_path.iterdir() if p.is_dir()]
    assert gates["P3c-G2"]["driven"] == len(dirs)
    assert gates["P3c-G2"]["denominator"] == "disk"
    assert gates["P3c-G2"]["pass"] is True


# --------------------------------------------------------------------
# P3c-G4 -- face applied
# --------------------------------------------------------------------

_SHAPES = {"noteheadBlack": (1.30, 1.00, 1.40),
           "clefG": (2.60, 6.80, 2.80),
           "accidentalSharp": (1.00, 2.60, 1.20),
           "restQuarter": (1.10, 2.90, 1.30)}


def _face_render(root: Path, render_id: str, face: str, spatium: float,
                 scale: float, source_id: str = "cov_ties",
                 content: float = 1.0) -> None:
    """One render whose glyph geometry is `scale` x a reference face's.
    Two faces built with the same `scale` are geometrically
    indistinguishable -- which is exactly what a silent font fallback
    looks like in the labels.

    `content` scales every glyph on top of that, standing in for
    within-face variation that is a property of the SOURCE rather than
    the font (grace noteheads, cue-size staves).
    """
    d = root / render_id
    d.mkdir(parents=True)
    (d / "render.json").write_text(json.dumps({
        "schema": 1, "render_id": render_id, "source": "source.mscx",
        "pdf": "score.pdf", "engine": face.split("/")[0], "face": face,
        "dpi": 300, "seed": 3,
        "style": {"spatium": spatium, "page_w_in": 8.27, "page_h_in": 11.69},
        "provenance": {"source_id": source_id, "kind": "coverage",
                       "origin": "generate.gen_coverage"},
    }, indent=2, sort_keys=True) + "\n")
    factor = scale * content * spatium
    glyphs = [_glyph(cls, w * factor, h * factor, adv * factor)
              for cls, (w, h, adv) in _SHAPES.items()]
    _write_labels(d, 0, glyphs, {cls: 1 for cls in _SHAPES})


def test_face_gate_confirms_faces_whose_geometry_is_distinct(tmp_path):
    _face_render(tmp_path, "a_ms4_Bravura_v0", "ms4/Bravura", 1.75, 1.00)
    _face_render(tmp_path, "a_ms4_Leland_v1", "ms4/Leland", 2.10, 1.09)
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert set(by_face) == {"ms4/Bravura", "ms4/Leland"}
    assert by_face["ms4/Bravura"]["applied"] is True
    assert by_face["ms4/Leland"]["applied"] is True
    assert by_face["ms4/Leland"]["nearest"] == "ms4/Bravura"
    assert by_face["ms4/Leland"]["nearest_diff"] > report["tol"]
    assert by_face["ms4/Leland"]["classes"] == 4
    assert report["unconfirmed"] == []


def test_face_gate_catches_a_face_that_silently_fell_back(tmp_path):
    """The load-bearing case: MuseScore resolves an unmatched font name
    silently, so a render LABELED `petaluma` can be DRAWN in the
    fallback (Bravura) with no error anywhere. Identical normalized
    geometry across two different face labels is that fallback's
    signature."""
    _face_render(tmp_path, "a_ms3_Bravura_v0", "ms3/Bravura", 1.75, 1.00)
    _face_render(tmp_path, "a_ms3_Petaluma_v1", "ms3/Petaluma", 2.10, 1.00)
    _face_render(tmp_path, "a_ms3_MuseJazz_v2", "ms3/MuseJazz", 1.90, 1.22)
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert by_face["ms3/Petaluma"]["applied"] is False
    assert by_face["ms3/Petaluma"]["nearest"] == "ms3/Bravura"
    assert by_face["ms3/Petaluma"]["nearest_diff"] < report["tol"]
    assert by_face["ms3/Bravura"]["applied"] is False
    assert by_face["ms3/MuseJazz"]["applied"] is True
    assert sorted(report["unconfirmed"]) == ["ms3/Bravura", "ms3/Petaluma"]


def test_face_gate_is_not_defeated_by_within_face_content_variation(tmp_path):
    """Faces are compared PER SOURCE. One class's geometry varies within
    a face by content -- a grace notehead is a smaller `noteheadBlack`
    -- and that variation is far larger here (2x) than the genuine
    between-face difference (9%). Pooling a face's sources together
    would drown the signal and report every face as unconfirmed."""
    for face, scale in [("ms4/Bravura", 1.00), ("ms4/Leland", 1.09)]:
        short = face.split("/")[1]
        _face_render(tmp_path, f"cov_ties_ms4_{short}_v0", face, 1.75, scale,
                     source_id="cov_ties", content=1.0)
        _face_render(tmp_path, f"cov_grace_ms4_{short}_v0", face, 1.75, scale,
                     source_id="cov_grace", content=0.5)
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert report["unconfirmed"] == []
    assert by_face["ms4/Leland"]["renders"] == 2
    # The between-face distance reflects the font difference alone, not
    # the 2x content swing.
    assert 0.05 < by_face["ms4/Leland"]["nearest_diff"] < 0.15


def test_face_gate_catches_a_fallback_even_with_content_variation(tmp_path):
    """The other direction: identical outlines must still register as a
    collision when the sources vary in size."""
    for face in ["ms3/Bravura", "ms3/Petaluma"]:
        short = face.split("/")[1]
        _face_render(tmp_path, f"cov_ties_ms3_{short}_v0", face, 1.75, 1.00,
                     source_id="cov_ties", content=1.0)
        _face_render(tmp_path, f"cov_grace_ms3_{short}_v0", face, 2.10, 1.00,
                     source_id="cov_grace", content=0.5)
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert by_face["ms3/Petaluma"]["nearest_diff"] < report["tol"]
    assert sorted(report["unconfirmed"]) == ["ms3/Bravura", "ms3/Petaluma"]


def test_face_gate_does_not_compare_across_engines(tmp_path):
    """An MS3 face and an MS4 face are different engine binaries; equal
    geometry between them says nothing about either one's fallback, so
    they must never be each other's `nearest`."""
    _face_render(tmp_path, "a_ms3_Bravura_v0", "ms3/Bravura", 1.75, 1.00)
    _face_render(tmp_path, "a_ms4_Bravura_v0", "ms4/Bravura", 1.75, 1.00)
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert by_face["ms3/Bravura"]["nearest"] is None
    assert by_face["ms3/Bravura"]["reason"] == "no-comparison-face"
    assert by_face["ms3/Bravura"]["applied"] is False


def test_face_gate_survives_a_fully_broken_bbox_chain(tmp_path):
    """Residual risk 1: if ink-bbox recovery is broken, every `bbox_pt`
    is null. Advance widths are still face metrics, so the gate must
    keep discriminating on those alone rather than reporting every face
    as unconfirmed."""
    for render_id, face, spatium, adv_scale in [
        ("a_ms4_Bravura_v0", "ms4/Bravura", 1.75, 1.00),
        ("a_ms4_Leland_v1", "ms4/Leland", 2.10, 1.09),
    ]:
        d = tmp_path / render_id
        d.mkdir()
        (d / "render.json").write_text(json.dumps({
            "schema": 1, "render_id": render_id, "source": "source.mscx",
            "pdf": "score.pdf", "engine": "ms4", "face": face, "dpi": 300,
            "seed": 3,
            "style": {"spatium": spatium, "page_w_in": 8.27,
                      "page_h_in": 11.69},
        }, indent=2, sort_keys=True) + "\n")
        glyphs = []
        for cls, adv in [("noteheadBlack", 1.40), ("clefG", 2.80),
                         ("accidentalSharp", 1.20), ("restQuarter", 1.30)]:
            g = _glyph(cls, 1.0, 1.0, adv * adv_scale * spatium)
            g["bbox_pt"] = None
            glyphs.append(g)
        _write_labels(d, 0, glyphs, {})
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert all(r["applied"] for r in report["faces"])
    assert by_face["ms4/Leland"]["nearest_diff"] > report["tol"]


def test_face_gate_reports_a_face_with_no_labels(tmp_path):
    _face_render(tmp_path, "a_ms4_Bravura_v0", "ms4/Bravura", 1.75, 1.00)
    bare = tmp_path / "a_ms4_Petaluma_v1"
    bare.mkdir()
    (bare / "render.json").write_text(json.dumps({
        "schema": 1, "render_id": bare.name, "source": "source.mscx",
        "pdf": "score.pdf", "engine": "ms4", "face": "ms4/Petaluma",
        "dpi": 300, "seed": 3,
        "style": {"spatium": 1.75, "page_w_in": 8.27, "page_h_in": 11.69},
    }, indent=2, sort_keys=True) + "\n")
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert by_face["ms4/Petaluma"]["renders"] == 0
    assert by_face["ms4/Petaluma"]["reason"] == "no-labels"
    assert by_face["ms4/Petaluma"]["applied"] is False


def test_face_gate_reports_an_expected_face_that_never_rendered(tmp_path):
    """A face whose every render was QUARANTINED -- a font MuseScore
    refuses, an export that crashes only on that face -- is precisely
    what this gate exists to catch, and it is absent from the render
    directories. Deriving the face list from what happens to be on disk
    would score it out of existence and pass."""
    _face_render(tmp_path, "cov_ties_ms4_Bravura_v0", "ms4/Bravura", 1.75, 1.00)
    _face_render(tmp_path, "cov_ties_ms4_MuseJazz_v1", "ms4/MuseJazz", 1.90, 1.22)
    (tmp_path / "dataset_plan.json").write_text(json.dumps({
        "schema": 1, "seed": 3, "engines": ["ms4"], "per_face": 1,
        "expected_faces": ["ms4/Bravura", "ms4/MuseJazz", "ms4/Petaluma"],
        "planned_renders": 3,
    }, indent=2, sort_keys=True) + "\n")
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert set(by_face) == {"ms4/Bravura", "ms4/MuseJazz", "ms4/Petaluma"}
    assert by_face["ms4/Petaluma"]["renders"] == 0
    assert by_face["ms4/Petaluma"]["reason"] == "no-renders"
    assert by_face["ms4/Petaluma"]["confirmed"] is False
    assert report["unconfirmed"] == ["ms4/Petaluma"]


def test_face_gate_expects_quarantined_faces_when_no_plan_was_written(tmp_path):
    """Cheap fallback for a dataset with no `dataset_plan.json`:
    `quarantine.json` records the face of every failed render."""
    _face_render(tmp_path, "cov_ties_ms4_Bravura_v0", "ms4/Bravura", 1.75, 1.00)
    _face_render(tmp_path, "cov_ties_ms4_MuseJazz_v1", "ms4/MuseJazz", 1.90, 1.22)
    (tmp_path / "quarantine.json").write_text(json.dumps([
        {"render_id": "cov_ties_ms4_Petaluma_v2", "source_id": "cov_ties",
         "engine": "ms4", "face": "ms4/Petaluma", "reason": "boom"},
    ], indent=2, sort_keys=True) + "\n")
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert by_face["ms4/Petaluma"]["reason"] == "no-renders"
    assert report["unconfirmed"] == ["ms4/Petaluma"]


def test_face_gate_reads_the_embedded_music_font_name(tmp_path):
    """The positive signal: what font did the renderer actually embed."""
    for render_id, face, scale, embedded in [
        ("cov_ties_ms4_Bravura_v0", "ms4/Bravura", 1.00, "ABCDEF+Bravura"),
        ("cov_ties_ms4_Petaluma_v1", "ms4/Petaluma", 1.22, "GHIJKL+Petaluma"),
    ]:
        _face_render(tmp_path, render_id, face, 1.75, scale)
        music_pdf(tmp_path / render_id / "score.pdf", embedded)
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert by_face["ms4/Petaluma"]["font_ok"] is True
    assert by_face["ms4/Petaluma"]["font_names"] == ["Petaluma"]
    assert by_face["ms4/Petaluma"]["applied"] is True
    assert by_face["ms4/Petaluma"]["confirmed"] is True
    assert report["unconfirmed"] == []


def test_face_gate_font_check_catches_a_fallback_the_geometry_missed(tmp_path):
    """THE REASON THIS SIGNAL EXISTS. The deferred questions ask "is
    this Petaluma?", and a distinctness gate can only answer "is this
    different from the faces I compared against". Here the geometry is
    distinct enough to pass, yet the PDF embeds Bravura -- the face
    silently fell back, and only the font name says so."""
    _face_render(tmp_path, "cov_ties_ms3_Bravura_v0", "ms3/Bravura", 1.75, 1.00)
    music_pdf(tmp_path / "cov_ties_ms3_Bravura_v0" / "score.pdf",
              "ABCDEF+Bravura")
    _face_render(tmp_path, "cov_ties_ms3_Petaluma_v1", "ms3/Petaluma", 1.75, 1.22)
    music_pdf(tmp_path / "cov_ties_ms3_Petaluma_v1" / "score.pdf",
              "GHIJKL+Bravura")
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert by_face["ms3/Petaluma"]["applied"] is True      # geometry says fine
    assert by_face["ms3/Petaluma"]["font_ok"] is False     # the font says no
    assert by_face["ms3/Petaluma"]["confirmed"] is False   # verdict: no
    assert by_face["ms3/Petaluma"]["font_names"] == ["Bravura"]
    assert "font" in by_face["ms3/Petaluma"]["reason"]
    assert report["unconfirmed"] == ["ms3/Petaluma"]


def test_face_gate_accepts_the_two_renamed_faces_under_either_spelling(tmp_path):
    """MuseScore registers two faces under a lookup name that differs
    from the label (MScore/Emmentaler, Gootville/Gonville), so the
    embedded font may carry either -- both must count as a match, or the
    gate would report a correct render as a fallback."""
    _face_render(tmp_path, "cov_ties_ms4_MScore_v0", "ms4/MScore", 1.75, 1.00)
    music_pdf(tmp_path / "cov_ties_ms4_MScore_v0" / "score.pdf",
              "ABCDEF+Emmentaler")
    _face_render(tmp_path, "cov_ties_ms4_Gootville_v1", "ms4/Gootville", 1.75, 1.22)
    music_pdf(tmp_path / "cov_ties_ms4_Gootville_v1" / "score.pdf",
              "GHIJKL+Gonville")
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert by_face["ms4/MScore"]["font_ok"] is True
    assert by_face["ms4/Gootville"]["font_ok"] is True
    assert report["unconfirmed"] == []


def test_face_gate_falls_back_to_geometry_when_no_pdf_is_readable(tmp_path):
    """No `score.pdf` (or an unreadable one) must not fail a face: the
    geometry gate still applies, and the row says the font evidence was
    unavailable rather than pretending it was checked."""
    _face_render(tmp_path, "cov_ties_ms4_Bravura_v0", "ms4/Bravura", 1.75, 1.00)
    _face_render(tmp_path, "cov_ties_ms4_Leland_v1", "ms4/Leland", 1.75, 1.09)
    report = build_dataset.faces_report(tmp_path)
    by_face = {r["face"]: r for r in report["faces"]}
    assert by_face["ms4/Leland"]["font_ok"] is None
    assert by_face["ms4/Leland"]["font_names"] == []
    assert by_face["ms4/Leland"]["confirmed"] is True
    assert "font-unavailable" in by_face["ms4/Leland"]["reason"]


def test_pin_page_holds_page_size_fixed_without_disturbing_spatium(tmp_path):
    """`style_variants` draws page size AND spatium per variant, so two
    faces normally differ in page size too -- different line breaking,
    a different per-page glyph mix, a shifted per-class median even for
    identical outlines. The probe pins the page so the face is the only
    variable; it must not perturb the spatium draw, or the probe would
    stop being comparable to a normal run."""
    pinned = build_dataset.plan_renders(seed=3, engines=["ms4"], per_face=2,
                                        texture_count=0, pin_page=True)
    loose = build_dataset.plan_renders(seed=3, engines=["ms4"], per_face=2,
                                       texture_count=0)
    assert {(r["page_w_in"], r["page_h_in"]) for r in pinned} == {
        build_dataset.PROBE_PAGE_IN}
    assert len({(r["page_w_in"], r["page_h_in"]) for r in loose}) > 1
    assert [r["spatium"] for r in pinned] == [r["spatium"] for r in loose]
    assert len({r["spatium"] for r in pinned}) > 1


def test_pinned_page_size_reaches_the_written_render_json(tmp_path):
    _generate(tmp_path, texture_count=0, pin_page=True)
    sizes = set()
    for render_json in sorted(tmp_path.glob("*/render.json")):
        style = json.loads(render_json.read_text())["style"]
        sizes.add((style["page_w_in"], style["page_h_in"]))
    assert sizes == {build_dataset.PROBE_PAGE_IN}


def test_probe_faces_overrides_the_matrix_without_editing_style_matrix(tmp_path):
    """How the Petaluma/Leland-on-MS3 questions get answered: run the
    matrix with the candidate face added, then read the face gate. The
    override must be scoped -- `style_matrix.FACES` is restored."""
    from generate import style_matrix
    before = dict(style_matrix.FACES)
    plan = build_dataset.plan_renders(
        seed=3, engines=["ms3"], per_face=1, texture_count=0,
        face_overrides={"ms3": ["Bravura", "Petaluma"]})
    assert {r["face"] for r in plan} == {"ms3/Bravura", "ms3/Petaluma"}
    assert style_matrix.FACES == before
    assert style_matrix.FACES["ms3"] == before["ms3"]


def test_probe_faces_argument_is_parsed_into_a_mapping():
    assert build_dataset.parse_face_overrides(
        ["ms3=Bravura,Petaluma", "ms4=Leland"]) == {
            "ms3": ["Bravura", "Petaluma"], "ms4": ["Leland"]}
    with pytest.raises(ValueError):
        build_dataset.parse_face_overrides(["ms3"])
    with pytest.raises(ValueError):
        build_dataset.parse_face_overrides(["nope=Bravura"])


# --------------------------------------------------------------------
# Status / freeze / compare
# --------------------------------------------------------------------

def test_status_names_the_phase_at_each_point_of_the_pipeline(tmp_path):
    empty = build_dataset.dataset_status(tmp_path)
    assert empty["phase"] == "empty"
    assert empty["render_dirs"] == 0

    _generate(tmp_path, texture_count=0)
    generated = build_dataset.dataset_status(tmp_path)
    assert generated["phase"] == "generated"
    assert generated["render_dirs"] > 0
    assert generated["renders_with_labels"] == 0
    assert "OMR_LABEL_EXPORT=1" in generated["next"]

    first = sorted(p for p in tmp_path.iterdir() if p.is_dir())[0]
    _write_labels(first, 0, [], {"noteheadBlack": 1})
    labeled = build_dataset.dataset_status(tmp_path)
    assert labeled["phase"] == "labeled"
    assert labeled["renders_with_labels"] == 1
    assert labeled["label_files"] == 1

    build_dataset.finalize_dataset(tmp_path, seed=3,
                                   version_probe=lambda _b: "")
    assert build_dataset.dataset_status(tmp_path)["phase"] == "finalized"


def test_freeze_degrades_every_page_and_is_reproducible(tmp_path):
    render = tmp_path / "cov_ties_ms4_Leland_v0"
    render.mkdir()
    (render / "render.json").write_text(json.dumps({
        "schema": 1, "render_id": render.name, "source": "source.mscx",
        "pdf": "score.pdf", "engine": "ms4", "face": "ms4/Leland",
        "dpi": 300, "seed": 3,
        "style": {"spatium": 1.75, "page_w_in": 8.27, "page_h_in": 11.69},
    }, indent=2, sort_keys=True) + "\n")
    rng = np.random.default_rng(0)
    page = rng.integers(0, 256, size=(64, 48), dtype=np.uint8)
    Image.fromarray(page).save(render / "page_0.png")
    _write_labels(render, 0, [_glyph("noteheadBlack", 6, 5, 7)],
                  {"noteheadBlack": 1})

    summary = build_dataset.freeze_dataset(tmp_path, seed=3)
    assert summary["pages"] == 1
    out = tmp_path / "eval_frozen" / render.name
    assert (out / "page_0.png").exists()
    frozen = json.loads((out / "page_0.labels.json").read_text())
    assert frozen["image"]["file"] == "page_0.png"
    assert len(frozen["image"]["label_transform"]) == 9
    # Geometric stages ran, so the transform is not the identity.
    assert frozen["image"]["label_transform"] != [1, 0, 0, 0, 1, 0, 0, 0, 1]
    assert frozen["glyphs"] == json.loads(
        (render / "page_0.labels.json").read_text())["glyphs"]

    first_png = (out / "page_0.png").read_bytes()
    first_json = (out / "page_0.labels.json").read_bytes()
    build_dataset.freeze_dataset(tmp_path, seed=3)
    assert (out / "page_0.png").read_bytes() == first_png
    assert (out / "page_0.labels.json").read_bytes() == first_json


def test_freeze_does_not_recurse_into_its_own_output(tmp_path):
    """`eval_frozen/<render_id>/` holds a `page_*.labels.json` too; if it
    were walked as a render directory the second freeze would degrade
    already-degraded pages."""
    render = tmp_path / "r0"
    render.mkdir()
    (render / "render.json").write_text(json.dumps(
        {"schema": 1, "render_id": "r0", "pdf": "score.pdf", "dpi": 300},
        indent=2, sort_keys=True) + "\n")
    Image.fromarray(np.zeros((32, 32), dtype=np.uint8)).save(
        render / "page_0.png")
    _write_labels(render, 0, [], {})
    assert build_dataset.freeze_dataset(tmp_path, seed=3)["pages"] == 1
    assert build_dataset.freeze_dataset(tmp_path, seed=3)["pages"] == 1
    # The marker `freeze` writes must NOT be `render.json` -- that is the
    # single fact keeping a second freeze off its own output.
    assert not (tmp_path / "eval_frozen" / "r0" / "render.json").exists()
    assert (tmp_path / "eval_frozen" / "r0" / "frozen.json").exists()


def test_frozen_eval_set_is_reachable_by_the_coco_export(tmp_path):
    """Whole-branch review, Important 2. `freeze` writes no `render.json`
    (see above), and `coco_export` used to require one -- so
    `coco --root $R` skipped `eval_frozen` and `coco --root $R/eval_frozen`
    emitted an empty file without a word. The frozen eval set (spec §6.5)
    therefore had NO path to the only detector-consumable format. Driven
    end to end through the real `freeze_dataset` -> `labels_to_coco`
    chain, not against a hand-written frozen directory."""
    render = tmp_path / "r0"
    render.mkdir()
    (render / "render.json").write_text(json.dumps(
        {"schema": 1, "render_id": "r0", "pdf": "score.pdf", "dpi": 300},
        indent=2, sort_keys=True) + "\n")
    rng = np.random.default_rng(0)
    Image.fromarray(rng.integers(0, 256, size=(64, 48), dtype=np.uint8)).save(
        render / "page_0.png")
    _write_labels(render, 0, [_glyph("noteheadBlack", 6, 5, 7)],
                  {"noteheadBlack": 1})

    build_dataset.freeze_dataset(tmp_path, seed=3)
    frozen_root = tmp_path / "eval_frozen"

    coco = build_dataset.coco_export.labels_to_coco(frozen_root)
    assert [i["file_name"] for i in coco["images"]] == ["r0/page_0.png"]
    assert len(coco["annotations"]) == 1

    # `images[]` reports the DEGRADED raster actually on disk...
    degraded = Image.open(frozen_root / "r0" / "page_0.png")
    assert (coco["images"][0]["width"], coco["images"][0]["height"]) == degraded.size
    # ...while the y-flip was anchored to the CLEAN raster, which the
    # scanner profile resampled away from the degraded one.
    frozen_labels = json.loads(
        (frozen_root / "r0" / "page_0.labels.json").read_text())
    assert frozen_labels["image"]["source_size_px"] == [48, 64]
    assert degraded.size != (48, 64)


# --------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------

_REPO_ROOT = Path(build_dataset.__file__).resolve().parents[2]


def _cli(*args, cwd=_REPO_ROOT):
    return subprocess.run(
        [sys.executable, "Training/generate/build_dataset.py", *args],
        cwd=cwd, capture_output=True, text=True, timeout=300)


def test_cli_runs_from_the_repo_root_without_pythonpath(tmp_path):
    """Every runbook command is copy-pasteable from the repo root, where
    `swift test` also has to run. Invoked by script path, `Training/` is
    not on `sys.path` -- the module bootstraps it."""
    done = _cli("status", "--root", str(tmp_path))
    assert done.returncode == 0, done.stderr
    assert "phase=empty" in done.stdout


def test_cli_compare_exits_nonzero_on_a_difference(tmp_path):
    import shutil
    a, b = tmp_path / "a", tmp_path / "b"
    _generate(a, texture_count=0)
    first = sorted(p for p in a.iterdir() if p.is_dir())[0]
    _write_labels(first, 0, [], {"noteheadBlack": 1})
    build_dataset.finalize_dataset(a, seed=3, version_probe=lambda _b: "")
    shutil.copytree(a, b)
    assert _cli("compare", str(a), str(b)).returncode == 0

    label = b / first.name / "page_0.labels.json"
    label.write_text(label.read_text().replace("noteheadBlack", "noteheadHalf"))
    differs = _cli("compare", str(a), str(b))
    assert differs.returncode == 1
    assert "identical=N" in differs.stdout


def test_cli_faces_exits_nonzero_when_a_face_is_unconfirmed(tmp_path):
    _face_render(tmp_path, "a_ms4_Bravura_v0", "ms4/Bravura", 1.75, 1.00)
    _face_render(tmp_path, "a_ms4_Petaluma_v1", "ms4/Petaluma", 2.10, 1.00)
    fell_back = _cli("faces", "--root", str(tmp_path))
    assert fell_back.returncode == 1
    assert "applied=0/2" in fell_back.stdout

    _face_render(tmp_path, "a_ms4_MuseJazz_v2", "ms4/MuseJazz", 1.90, 1.22)
    still_bad = _cli("faces", "--root", str(tmp_path))
    assert still_bad.returncode == 1
    assert "applied=1/3" in still_bad.stdout


def test_cli_rejects_a_bad_engine_or_probe_face_as_a_usage_error(tmp_path):
    """A mistyped argument must not look like a crash, and must not
    leave a half-written dataset behind."""
    bad_engine = _cli("generate", "--root", str(tmp_path), "--seed", "3",
                      "--engines", "ms9")
    assert bad_engine.returncode == 2
    assert "Traceback" not in bad_engine.stderr

    bad_probe = _cli("generate", "--root", str(tmp_path), "--seed", "3",
                     "--probe-faces", "ms4")
    assert bad_probe.returncode == 2
    assert "Traceback" not in bad_probe.stderr
    assert list(tmp_path.iterdir()) == []


def test_cli_reports_an_already_populated_root_as_a_usage_error(tmp_path):
    """The single most likely operator mistake -- rerunning `generate`
    into the same root -- must read as a usage error like any other,
    not as a crash. It also must not reach MuseScore: the check fires
    before the first export."""
    _generate(tmp_path, texture_count=0)
    again = _cli("generate", "--root", str(tmp_path), "--seed", "3")
    assert again.returncode == 2
    assert "Traceback" not in again.stderr
    assert "--allow-existing" in again.stderr


def test_cli_coco_writes_a_detection_json(tmp_path):
    _generate(tmp_path, texture_count=0)
    first = sorted(p for p in tmp_path.iterdir() if p.is_dir())[0]
    _write_labels(first, 0, [_glyph("noteheadBlack", 6, 5, 7)],
                  {"noteheadBlack": 1})
    done = _cli("coco", "--root", str(tmp_path))
    assert done.returncode == 0, done.stderr
    doc = json.loads((tmp_path / "coco.json").read_text())
    assert len(doc["annotations"]) == 1
    assert doc["annotations"][0]["category_id"] == (
        build_dataset.vocabulary.CLASS_NAMES.index("noteheadBlack") + 1)
    assert "[coco][WARN]" not in done.stdout


def test_cli_coco_warns_when_a_root_yields_no_images(tmp_path):
    """An empty export is nearly always a wrong `--root`, and it used to
    be indistinguishable from a good one -- `write_coco` reported the
    output path and nothing else. Still exit 0: `coco` is a convenience
    export, not a gate."""
    done = _cli("coco", "--root", str(tmp_path))
    assert done.returncode == 0, done.stderr
    assert "[coco][WARN]" in done.stdout
    doc = json.loads((tmp_path / "coco.json").read_text())
    assert doc["images"] == []
