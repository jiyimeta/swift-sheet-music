import os
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pypdfium2 as pdfium
import pytest

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


def test_pdf_is_complete_rejects_trailing_garbage_after_eof(tmp_path):
    """A torn append could leave a stale `%%EOF` from an earlier revision
    inside the last-1024-byte window while the true file tail is
    corrupt. Requiring the LAST non-whitespace bytes to be `%%EOF` (not
    just "`%%EOF` appears somewhere in the tail") catches that a plain
    substring search would miss."""
    good = tmp_path / "good.pdf"
    _make_pdf(good)
    garbled = tmp_path / "garbled.pdf"
    garbled.write_bytes(good.read_bytes() + b"GARBAGE-NOT-PART-OF-PDF")
    assert not export_pdf.pdf_is_complete(garbled)


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


def test_run_supervised_kills_full_process_group_on_timeout():
    """The REAL timeout/kill path (`run=None`'s implementation), not the
    injected-`run` fakes above. `_run_supervised` supervises an
    arbitrary argv, so this needs no MuseScore: "sleep 5" under a short
    timeout exercises the exact own-process-group + SIGKILL logic
    MuseScore would go through. The observable outcome checked is that
    the child is actually reaped and its process group no longer exists
    -- not merely that the call returned -- so both `os.kill` (process)
    and `os.killpg` (group) must raise ProcessLookupError afterward."""
    real_popen = subprocess.Popen
    captured = {}

    def spy_popen(*args, **kwargs):
        proc = real_popen(*args, **kwargs)
        captured["pid"] = proc.pid
        return proc

    orig_popen = export_pdf.subprocess.Popen
    export_pdf.subprocess.Popen = spy_popen
    try:
        result = export_pdf._run_supervised(["sleep", "5"], timeout_s=0.2)
    finally:
        export_pdf.subprocess.Popen = orig_popen

    assert result.timed_out is True
    assert result.returncode is None
    pid = captured["pid"]
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)
    with pytest.raises(ProcessLookupError):
        os.killpg(pid, 0)


def test_export_pdf_write_then_hang_via_real_run_supervised_is_success(tmp_path):
    """End-to-end through the REAL `_run_supervised` (`run=None`): a
    process that writes a complete PDF and then hangs -- MS4's exact
    measured shape -- must still be judged a success by `export_pdf`
    without any dependency injection, proving the default path and
    `pdf_is_complete` compose the way the injected-`run` tests above
    already prove they should. No MuseScore needed: a tiny stand-in
    script plays MuseScore's role (write the output, then hang) using
    the venv's own interpreter, invoked exactly like `export_pdf` would
    invoke a real `mscore_bin` (argv: stub, "-o", out_pdf, source)."""
    stub = tmp_path / "stub_mscore.py"
    stub.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        "import time\n"
        "import pypdfium2 as pdfium\n"
        "out = sys.argv[2]  # mirrors `mscore -o <out> <source>`\n"
        "doc = pdfium.PdfDocument.new()\n"
        "doc.new_page(595, 842)\n"
        "doc.save(out)\n"
        "time.sleep(5)\n"
    )
    stub.chmod(stub.stat().st_mode | 0o111)
    out = tmp_path / "out.pdf"
    o = export_pdf.export_pdf(str(stub), tmp_path / "s.mscx", out, timeout_s=0.5)
    assert o.ok is True
    assert o.timed_out is True


def test_run_supervised_swallows_process_lookup_error_race_during_kill(monkeypatch):
    """Between `TimeoutExpired` firing and the kill line running, the
    child may already have exited on its own -- `os.getpgid`/
    `os.killpg` then raise `ProcessLookupError`, which must NOT
    propagate out of `_run_supervised` (that would crash the whole
    batch driver instead of falling through to the completeness check,
    which is what should happen: the process is already gone, so judge
    the file). `os.killpg` is monkeypatched to simulate that race
    deterministically rather than trying to win a real timing race."""
    def raise_lookup(*_args, **_kwargs):
        raise ProcessLookupError()

    monkeypatch.setattr(export_pdf.os, "killpg", raise_lookup)
    # "sleep 0.2" under a much shorter timeout still hits the
    # TimeoutExpired branch; because the real kill is stubbed out, the
    # process is left to exit on its own shortly after -- fast and
    # deterministic, no orphan left behind.
    result = export_pdf._run_supervised(["sleep", "0.2"], timeout_s=0.05)
    assert result.timed_out is True
    assert result.returncode is None


def test_mscore_version_real_path_survives_missing_binary(tmp_path):
    """Best-effort per its own docstring: a missing binary must not
    raise out of a function documented that way. No MuseScore needed --
    the whole point is a path that doesn't exist."""
    missing = tmp_path / "no_such_mscore"
    assert export_pdf.mscore_version(str(missing)) == ""


def test_mscore_version_real_path_survives_timeout(monkeypatch):
    """Same best-effort contract for a hung `--version` invocation.
    `subprocess.run` is monkeypatched to raise `TimeoutExpired`
    directly rather than actually waiting out the real 60s timeout."""
    def raise_timeout(*_args, **_kwargs):
        raise subprocess.TimeoutExpired(cmd="mscore", timeout=60)

    monkeypatch.setattr(export_pdf.subprocess, "run", raise_timeout)
    assert export_pdf.mscore_version("mscore") == ""


def test_mscore_version_uses_injected_run(tmp_path):
    """The version probe is a second, distinct call site (stdout capture,
    not file-completeness supervision) but must be equally injectable so
    the suite never needs a real `mscore` binary."""
    def fake_run(cmd):
        return SimpleNamespace(stdout="MuseScore Studio 4.4.2\n", stderr="")

    v = export_pdf.mscore_version("mscore", run_capture=fake_run)
    assert v == "MuseScore Studio 4.4.2"


def test_mscore_version_falls_back_to_stderr(tmp_path):
    """Some builds print --version to stderr; either stream must work."""
    def fake_run(cmd):
        return SimpleNamespace(stdout="", stderr="MuseScore 3.6.2\n")

    v = export_pdf.mscore_version("mscore", run_capture=fake_run)
    assert v == "MuseScore 3.6.2"
