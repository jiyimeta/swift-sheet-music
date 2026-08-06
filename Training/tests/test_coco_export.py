import json
from pathlib import Path

from PIL import Image

from generate import coco_export, vocabulary


def _dataset(root: Path) -> None:
    render = root / "r0"
    render.mkdir(parents=True)
    (render / "render.json").write_text(json.dumps(
        {"schema": 1, "pdf": "score.pdf", "dpi": 300}))
    (render / "page_0.labels.json").write_text(json.dumps({
        "schema": 1,
        "page": {"index": 0, "width_pt": 72.0, "height_pt": 144.0},
        "image": {"file": "page_0.png", "dpi": 300,
                  "label_transform": [1, 0, 0, 0, 1, 0, 0, 0, 1]},
        "glyphs": [{"class": "noteheadBlack", "bbox_pt": [10, 10, 16, 15],
                    "origin_pt": [10.0, 12.5], "advance_pt": 6.0,
                    "rendered_size_pt": 5.0, "font_size_pt": 0.0}],
        "paths": [], "beams": [], "curves": [], "texts": [],
        "census": {"glyphs_by_class": {"noteheadBlack": 1}, "texts": 0},
    }))


def test_coco_categories_follow_vocabulary_order(tmp_path):
    _dataset(tmp_path)
    coco = coco_export.labels_to_coco(tmp_path)
    assert [c["name"] for c in coco["categories"]] == vocabulary.CLASS_NAMES
    assert coco["categories"][0]["id"] == 1  # COCO ids are 1-based


def test_bbox_converts_yup_points_to_ydown_pixels(tmp_path):
    _dataset(tmp_path)
    coco = coco_export.labels_to_coco(tmp_path)
    ann = coco["annotations"][0]
    # dpi 300: scale 300/72. Page height 144pt = 600px.
    # x_px = 10 * 300/72 = 41.67; top y_px = (144-15) * 300/72 = 537.5.
    x, y, w, h = ann["bbox"]
    assert abs(x - 10 * 300 / 72) < 1e-6
    assert abs(y - (144 - 15) * 300 / 72) < 1e-6
    assert abs(w - 6 * 300 / 72) < 1e-6
    assert abs(h - 5 * 300 / 72) < 1e-6
    img = coco["images"][0]
    assert img["width"] == round(72 * 300 / 72)
    assert img["height"] == round(144 * 300 / 72)


def test_reserved_class_glyphs_are_skipped(tmp_path):
    _dataset(tmp_path)
    label = tmp_path / "r0" / "page_0.labels.json"
    doc = json.loads(label.read_text())
    doc["glyphs"].append({"class": "staff5Lines", "bbox_pt": [0, 0, 72, 144],
                          "origin_pt": [0.0, 0.0], "advance_pt": 0.0,
                          "rendered_size_pt": 0.0, "font_size_pt": 100.0})
    label.write_text(json.dumps(doc))
    coco = coco_export.labels_to_coco(tmp_path)
    assert len(coco["annotations"]) == 1  # detector classes only


def test_glyph_with_null_bbox_is_skipped(tmp_path):
    """`bbox_pt` is `null` for an unresolvable outline (schema note in
    OMRLabelTypes.swift) -- must not crash and must not emit an
    annotation for it."""
    _dataset(tmp_path)
    label = tmp_path / "r0" / "page_0.labels.json"
    doc = json.loads(label.read_text())
    doc["glyphs"].append({"class": "noteheadHalf", "bbox_pt": None,
                          "origin_pt": [0.0, 0.0], "advance_pt": 0.0,
                          "rendered_size_pt": 0.0, "font_size_pt": 100.0})
    label.write_text(json.dumps(doc))
    coco = coco_export.labels_to_coco(tmp_path)
    assert len(coco["annotations"]) == 1


# --- Pixel-dimension correction (this task's brief-fix) --------------------
#
# The brief's own sample code computed image width/height with
# `round(page_pt * scale)` and derived every glyph's y-flip from that same
# recomputed height -- both wrong. `round()` disagrees with pdfium's real
# `ceil(page_pt * (dpi/72))` rule whenever the float product lands close to
# (but not exactly on) a whole pixel, which is the COMMON case, not an edge
# case -- e.g. plain A4 (595 x 842pt) at 300dpi, used below.

def test_image_pixel_size_uses_ceil_not_round_when_no_png_exists(tmp_path):
    """No PNG is on disk for this fixture (only the label JSON), so
    coco_export must fall back to the verified ceil rule
    (`rasterize.page_size_px`) -- never `round()`. A4 at 300dpi is a
    completely ordinary combination where the two rules disagree on
    BOTH axes:
        width:  595 * 300/72 = 2479.1666... -> ceil 2480, round 2479
        height: 842 * 300/72 = 3508.3333... -> ceil 3509, round 3508
    (values independently reproduced in Training/tests/test_rasterize.py).
    """
    render = tmp_path / "a4"
    render.mkdir()
    (render / "render.json").write_text(json.dumps({"schema": 1, "dpi": 300}))
    (render / "page_0.labels.json").write_text(json.dumps({
        "schema": 1,
        "page": {"index": 0, "width_pt": 595.0, "height_pt": 842.0},
        "image": {"file": "page_0.png", "dpi": 300,
                  "label_transform": [1, 0, 0, 0, 1, 0, 0, 0, 1]},
        "glyphs": [{"class": "noteheadBlack", "bbox_pt": [10, 10, 16, 15],
                    "origin_pt": [10.0, 12.5], "advance_pt": 6.0,
                    "rendered_size_pt": 5.0, "font_size_pt": 0.0}],
        "paths": [], "beams": [], "curves": [], "texts": [],
        "census": {"glyphs_by_class": {"noteheadBlack": 1}, "texts": 0},
    }))
    assert not (render / "page_0.png").exists()  # precondition: no render

    coco = coco_export.labels_to_coco(tmp_path)
    img = coco["images"][0]
    assert (img["width"], img["height"]) == (2480, 3509)
    assert img["width"] != round(595.0 * 300 / 72)   # proves round() was rejected
    assert img["height"] != round(842.0 * 300 / 72)

    # The y-flip must be anchored to the ACTUAL (ceil'd) pixel height
    # 3509, not the recomputed float product 842.0 * (300/72) ==
    # 3508.3333... A naive re-derivation would put the bbox's top edge
    # 0.6667px too low.
    ann = coco["annotations"][0]
    _, y, _, _ = ann["bbox"]
    correct_top = 3509 - 15 * (300 / 72)
    wrong_top = 842.0 * (300 / 72) - 15 * (300 / 72)  # the bug's formula
    assert abs(y - correct_top) < 1e-6
    assert abs(y - wrong_top) > 0.5  # the two must meaningfully disagree


def test_image_pixel_size_prefers_actual_png_on_disk_over_recomputation(tmp_path):
    """When a rendered PNG DOES exist, its actual `.size` is the ground
    truth for `images[].width` / `.height` and must win over any
    recomputed page_size_px value -- even a correct recomputation,
    because rasterize.py's own contract is "if a rendered image already
    exists, read its actual .size -- never recompute it" (e.g. a page
    that was itself produced by a geometric degradation stage genuinely
    has different pixel dimensions than its page-box points would
    predict).

    NOTE this covers the IMAGE RECORD only. The y-flip is a separate
    question with a separate answer -- see
    `test_non_identity_transform_flips_about_the_clean_raster_height`
    below -- because `label_transform` maps CLEAN-raster pixels to
    degraded pixels, so the flip must be anchored to the clean height
    even when the image on disk is a different size."""
    render = tmp_path / "r0"
    render.mkdir()
    (render / "render.json").write_text(json.dumps({"schema": 1, "dpi": 300}))
    (render / "page_0.labels.json").write_text(json.dumps({
        "schema": 1,
        "page": {"index": 0, "width_pt": 595.0, "height_pt": 842.0},
        "image": {"file": "page_0.png", "dpi": 300,
                  "label_transform": [1, 0, 0, 0, 1, 0, 0, 0, 1]},
        "glyphs": [],
        "paths": [], "beams": [], "curves": [], "texts": [],
        "census": {"glyphs_by_class": {}, "texts": 0},
    }))
    # Deliberately NOT what page_size_px(595, 842, 300) == (2480, 3509)
    # would predict -- standing in for a degraded/resampled page whose
    # actual raster genuinely differs from the clean page-box math.
    Image.new("L", (2500, 3600), color=255).save(render / "page_0.png")

    coco = coco_export.labels_to_coco(tmp_path)
    img = coco["images"][0]
    assert (img["width"], img["height"]) == (2500, 3600)


# --- The degraded (non-identity `label_transform`) path -------------------
#
# Whole-branch review, Important 2. This path was applied by
# `labels_to_coco` but never exercised: the only non-identity transforms
# in the pipeline live in `eval_frozen/<render_id>/`, which
# `freeze_eval_page` writes WITHOUT a `render.json`, and `labels_to_coco`
# used to require one. So the frozen eval set (spec 6.5) had no route to
# COCO at all, and the transform branch had no test. It was also wrong:
# it flipped y about the DEGRADED image's height, while `apply_chain`'s
# composed homography maps CLEAN-raster pixels to degraded pixels (see
# degrade.py's module docstring), so the flip must be anchored to the
# clean raster.

def _degraded_label(page_w_pt, page_h_pt, dpi, transform, glyphs,
                    source_size_px=None) -> dict:
    image = {"file": "page_0.png", "dpi": dpi, "label_transform": list(transform)}
    if source_size_px is not None:
        image["source_size_px"] = list(source_size_px)
    return {
        "schema": 1,
        "page": {"index": 0, "width_pt": page_w_pt, "height_pt": page_h_pt},
        "image": image,
        "glyphs": glyphs,
        "paths": [], "beams": [], "curves": [], "texts": [],
        "census": {"glyphs_by_class": {g["class"]: 1 for g in glyphs},
                   "texts": 0},
    }


def _glyph(bbox_pt) -> dict:
    return {"class": "noteheadBlack", "bbox_pt": list(bbox_pt),
            "origin_pt": [bbox_pt[0], bbox_pt[1]], "advance_pt": 6.0,
            "rendered_size_pt": 5.0, "font_size_pt": 0.0}


def test_non_identity_transform_flips_about_the_clean_raster_height(tmp_path):
    """Numeric end-to-end check of the degraded path, every number
    hand-computable.

    Clean page: 72 x 144 pt at 72 dpi, so scale == 1.0 and the clean
    raster is exactly 72 x 144 px (`page_size_px(72, 144, 72)`).
    Glyph bbox_pt = (10, 20) .. (16, 30), y-up.

    Flip about the CLEAN height (144):
        x:   10 .. 16
        y:   144 - 30 = 114  (top)  ..  144 - 20 = 124  (bottom)

    Homography h = [[2, 0, 5], [0, 2, 7], [0, 0, 1]] (scale 2, shift +5/+7):
        x':  2*10 + 5 =  25  ..  2*16 + 5 =  37   -> w = 12
        y':  2*114 + 7 = 235 ..  2*124 + 7 = 255  -> h = 20

    => bbox == [25, 235, 12, 20].

    The degraded PNG on disk is 149 x 295 px. Flipping about THAT height
    (the old behavior) would give a top of 2*(295 - 30) + 7 == 537 -- off
    by 302 px, more than the glyph is tall, on every annotation of every
    frozen page. The PNG's size is still what `images[]` must report.
    """
    render = tmp_path / "eval0"
    render.mkdir()
    (render / "frozen.json").write_text(json.dumps({"schema": 1}))
    (render / "page_0.labels.json").write_text(json.dumps(_degraded_label(
        72.0, 144.0, 72, [2, 0, 5, 0, 2, 7, 0, 0, 1], [_glyph([10, 20, 16, 30])])))
    Image.new("L", (149, 295), color=255).save(render / "page_0.png")

    coco = coco_export.labels_to_coco(tmp_path)

    img = coco["images"][0]
    assert (img["width"], img["height"]) == (149, 295)  # the actual raster

    x, y, w, h = coco["annotations"][0]["bbox"]
    assert abs(x - 25.0) < 1e-9
    assert abs(y - 235.0) < 1e-9
    assert abs(w - 12.0) < 1e-9
    assert abs(h - 20.0) < 1e-9
    # The old formula, spelled out, must be far away -- not merely "not
    # equal to within a tolerance".
    assert abs(y - (2 * (295 - 30) + 7)) > 100


def test_clean_raster_height_recorded_by_freeze_wins_over_rederivation(tmp_path):
    """`freeze_eval_page` records the clean raster's ACTUAL pixel size in
    `image.source_size_px`, and that recorded value is authoritative --
    re-deriving from page-box points + dpi is only the fallback for a
    label file written before the field existed.

    Here the recorded clean height (145) deliberately differs from what
    `page_size_px(72, 144, 72)` would predict (144), so only an
    implementation that reads the field lands on the expected value:
        top y = 145 - 30 = 115  ->  2*115 + 7 = 237
    (the re-derived answer would be 235, the previous test's number).
    """
    render = tmp_path / "eval0"
    render.mkdir()
    (render / "frozen.json").write_text(json.dumps({"schema": 1}))
    (render / "page_0.labels.json").write_text(json.dumps(_degraded_label(
        72.0, 144.0, 72, [2, 0, 5, 0, 2, 7, 0, 0, 1], [_glyph([10, 20, 16, 30])],
        source_size_px=[72, 145])))
    Image.new("L", (149, 295), color=255).save(render / "page_0.png")

    _, y, _, _ = coco_export.labels_to_coco(tmp_path)["annotations"][0]["bbox"]
    assert abs(y - 237.0) < 1e-9


def test_frozen_render_dirs_are_exported_even_without_a_render_json(tmp_path):
    """`freeze_eval_page` writes a PNG and a label file but no
    `render.json` (that file is the training pipeline's own "this render
    completed" marker, and `_render_dirs` keys off it). `labels_to_coco`
    must therefore recognize the frozen set's own marker too, or
    `coco --root $R/eval_frozen` silently emits an empty file -- which is
    what it used to do."""
    render = tmp_path / "eval0"
    render.mkdir()
    (render / "frozen.json").write_text(json.dumps({"schema": 1}))
    (render / "page_0.labels.json").write_text(json.dumps(_degraded_label(
        72.0, 144.0, 72, [1, 0, 0, 0, 1, 0, 0, 0, 1], [_glyph([10, 20, 16, 30])])))

    coco = coco_export.labels_to_coco(tmp_path)
    assert [i["file_name"] for i in coco["images"]] == ["eval0/page_0.png"]
    assert len(coco["annotations"]) == 1


def test_a_directory_with_neither_marker_is_still_skipped(tmp_path):
    """The markers are a whitelist, not decoration: a half-written render
    (labels present, no marker yet) must stay invisible."""
    render = tmp_path / "half"
    render.mkdir()
    (render / "page_0.labels.json").write_text(json.dumps(_degraded_label(
        72.0, 144.0, 72, [1, 0, 0, 0, 1, 0, 0, 0, 1], [_glyph([10, 20, 16, 30])])))

    coco = coco_export.labels_to_coco(tmp_path)
    assert coco["images"] == []
    assert coco["annotations"] == []
