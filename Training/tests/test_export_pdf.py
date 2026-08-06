from pathlib import Path
from types import SimpleNamespace

import pypdfium2 as pdfium

from generate import export_pdf


def _make_pdf(path: Path) -> None:
    doc = pdfium.PdfDocument.new()
    doc.new_page(595, 842)
    doc.save(str(path))


def test_pdf_is_complete_accepts_real_and_rejects_truncated(tmp_path):
    good = tmp_path / "good.pdf"
    _make_pdf(good)
    assert export_pdf.pdf_is_complete(good)
    bad = tmp_path / "bad.pdf"
    bad.write_bytes(good.read_bytes()[:-40])  # chop trailer/%%EOF
    assert not export_pdf.pdf_is_complete(bad)
    assert not export_pdf.pdf_is_complete(tmp_path / "absent.pdf")


def test_complete_file_plus_timeout_is_success(tmp_path):
    """MS4's measured shape: writes the PDF, never exits -> timeout kill,
    but the complete file means SUCCESS."""
    out = tmp_path / "out.pdf"

    def hang_but_write(cmd, timeout_s):
        _make_pdf(out)
        return SimpleNamespace(returncode=None, timed_out=True)

    o = export_pdf.export_pdf("mscore", tmp_path / "s.mscx", out,
                              timeout_s=1, run=hang_but_write)
    assert o.ok and o.timed_out and not o.retried


def test_nonzero_exit_with_complete_file_is_success(tmp_path):
    """Crashpad shape: successful export, non-zero exit."""
    out = tmp_path / "out.pdf"

    def crash_after_write(cmd, timeout_s):
        _make_pdf(out)
        return SimpleNamespace(returncode=139, timed_out=False)

    o = export_pdf.export_pdf("mscore", tmp_path / "s.mscx", out, run=crash_after_write)
    assert o.ok and o.exit_code == 139


def test_no_file_retries_once_then_quarantines(tmp_path):
    out = tmp_path / "out.pdf"
    calls = []

    def never_writes(cmd, timeout_s):
        calls.append(cmd)
        return SimpleNamespace(returncode=1, timed_out=False)

    o = export_pdf.export_pdf("mscore", tmp_path / "s.mscx", out, run=never_writes)
    assert not o.ok and o.retried and len(calls) == 2
    assert "incomplete" in o.reason


def test_retry_can_succeed_on_second_attempt(tmp_path):
    out = tmp_path / "out.pdf"
    state = {"n": 0}

    def flaky(cmd, timeout_s):
        state["n"] += 1
        if state["n"] == 2:
            _make_pdf(out)
        return SimpleNamespace(returncode=0, timed_out=False)

    o = export_pdf.export_pdf("mscore", tmp_path / "s.mscx", out, run=flaky)
    assert o.ok and o.retried


def test_stale_output_is_removed_before_running(tmp_path):
    """A leftover complete PDF from a previous render must not count."""
    out = tmp_path / "out.pdf"
    _make_pdf(out)

    def never_writes(cmd, timeout_s):
        return SimpleNamespace(returncode=0, timed_out=False)

    o = export_pdf.export_pdf("mscore", tmp_path / "s.mscx", out, run=never_writes)
    assert not o.ok


def test_mscore_version_uses_injected_run(tmp_path):
    """The version probe is a second, distinct call site (stdout capture,
    not file-completeness supervision) but must be equally injectable so
    the suite never needs a real `mscore` binary."""
    def fake_run(cmd):
        return SimpleNamespace(stdout="MuseScore Studio 4.4.2\n", stderr="")

    v = export_pdf.mscore_version("mscore", run=fake_run)
    assert v == "MuseScore Studio 4.4.2"


def test_mscore_version_falls_back_to_stderr(tmp_path):
    """Some builds print --version to stderr; either stream must work."""
    def fake_run(cmd):
        return SimpleNamespace(stdout="", stderr="MuseScore 3.6.2\n")

    v = export_pdf.mscore_version("mscore", run=fake_run)
    assert v == "MuseScore 3.6.2"
