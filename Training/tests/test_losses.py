import pytest
import torch

from model import losses


def test_focal_loss_is_zero_for_a_perfect_prediction():
    target = torch.zeros(1, 2, 4, 4); target[0, 1, 2, 2] = 1.0
    logits = torch.full_like(target, -20.0); logits[0, 1, 2, 2] = 20.0
    assert float(losses.focal(logits, target)) == pytest.approx(0.0, abs=1e-4)


def test_focal_loss_punishes_a_missed_peak_more_than_a_soft_background():
    # Two targets, same wrong prediction (pred ~= 0 everywhere): one has a
    # true peak (target == 1) the model completely misses, the other has
    # only a "soft" background cell (target == 0.8, the kind of value the
    # Gaussian falloff around a nearby peak leaves behind) at the same
    # spot. The (1 - target)^4 penalty reduction in the negative term
    # exists precisely so a soft cell like that — where a real detector's
    # false positives cluster — costs far less than a genuine miss.
    logits = torch.full((1, 1, 4, 4), -20.0)  # pred ~= 0 everywhere
    missed_peak = torch.zeros(1, 1, 4, 4)
    missed_peak[0, 0, 2, 2] = 1.0
    soft_background = torch.zeros(1, 1, 4, 4)
    soft_background[0, 0, 2, 2] = 0.8
    assert (float(losses.focal(logits, missed_peak))
            > float(losses.focal(logits, soft_background)))


def test_masked_l1_ignores_everything_outside_the_mask():
    pred = torch.ones(1, 4, 3, 3) * 5
    target = torch.zeros(1, 4, 3, 3)
    mask = torch.zeros(1, 1, 3, 3); mask[0, 0, 1, 1] = 1
    assert float(losses.masked_l1(pred, target, mask)) == pytest.approx(5.0)
