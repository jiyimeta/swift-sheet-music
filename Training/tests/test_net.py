import pytest
import torch

from model import net


def test_the_heads_are_stride_four_and_the_right_width():
    model = net.SymbolNet(num_classes=62, width=16)
    hm, off, geom = model(torch.zeros(2, 1, 128, 128))
    assert hm.shape == (2, 62, 32, 32)
    assert off.shape == (2, 2, 32, 32)
    assert geom.shape == (2, 4, 32, 32)


def test_the_heatmap_bias_starts_the_model_confident_that_most_cells_are_empty():
    # A CenterNet bias of -2.19 puts the initial probability near 0.1;
    # without it the focal loss spends its first epochs undoing a 0.5
    # prior over 62 classes x every cell.
    model = net.SymbolNet()
    assert model.heatmap_head.bias.detach().mean().item() == pytest.approx(-2.19, abs=1e-6)


def test_the_export_wrapper_emits_probabilities():
    wrapped = net.ExportWrapper(net.SymbolNet(num_classes=3, width=8))
    hm, _, _ = wrapped(torch.zeros(1, 1, 64, 64))
    assert float(hm.min()) >= 0.0 and float(hm.max()) <= 1.0
