import numpy as np

from probes import label_geometry as lg


def test_truth_lines_dedups_a_fragmented_staff_line():
    labels = {"paths": [
        {"kind": "horizontal", "rect_pt": [0, 100, 60, 100], "line_width_pt": 1},
        {"kind": "horizontal", "rect_pt": [60, 100, 120, 100], "line_width_pt": 1},
        {"kind": "horizontal", "rect_pt": [0, 108, 120, 108], "line_width_pt": 1},
        {"kind": "horizontal", "rect_pt": [0, 90, 10, 90], "line_width_pt": 1},
        {"kind": "vertical", "rect_pt": [0, 90, 0, 130], "line_width_pt": 1},
    ]}
    lines = lg.truth_lines(labels, min_len_pt=40.0)
    assert [y for _, _, y in lines] == [100.0, 108.0]
    # The two fragments of the y=100 line union into one 0..120 span, so
    # a probe walking it never leaves the line and never counts the page
    # margin as a break in the ink.
    assert lines[0][0] == 0.0
    assert lines[0][1] == 120.0


def test_staff_spacing_is_the_median_small_gap():
    ys = [100, 108, 116, 124, 132, 300, 308, 316, 324, 332]
    assert lg.staff_spacing_pt(ys) == 8.0


def test_staff_spacing_is_none_without_a_staff():
    assert lg.staff_spacing_pt([100.0]) is None


def test_compose_applies_a_homography():
    h = np.array([[1, 0, 5], [0, 1, -3], [0, 0, 1]], float)
    assert lg.compose(h, 10.0, 10.0) == (15.0, 7.0)
