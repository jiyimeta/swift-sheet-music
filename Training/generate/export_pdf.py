"""MuseScore CLI driver with §6.3 process supervision. MEASURED behavior
this encodes (do not "fix"): MS4 PDF export writes the file then never
exits; `.spos` export on MS4 finishes writing a complete file and then
crashes on shutdown (MS3 exits cleanly instead); MuseScore's crash
reporter can make a *successful* export exit non-zero. Success is judged
ONLY by output-file completeness (trailing `%%EOF` plus a successful
page-count read); exit codes are recorded, never trusted. One retry,
then the caller quarantines the source -- this module reports the
failed `ExportOutcome`, it does not itself maintain a quarantine list.

MuseScore 3 additionally: (a) refuses to open a score written by a
newer MuseScore -- the caller must feed it an MS3-schema source for the
MS3 arm to do anything at all; (b) has no `offscreen` QPA platform on
macOS (`cocoa` is the only one available), so headless invocations must
not force `QT_QPA_PLATFORM=offscreen` for the MS3 binary. Neither binary
is hard-coded: both are environment-overridable so a different host's
install paths don't require editing this file.
"""

import os
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace

import pypdfium2 as pdfium

# Both binaries are env-overridable rather than hard-coded, per this
# task's constraint that a different machine's MuseScore.app locations
# must not require editing tracked code. These particular paths are
# this host's measured defaults, used only when the env var is unset.
MSCORE4_BIN = os.environ.get(
    "OMR_MSCORE4_BIN", "/Applications/MuseScore 4.app/Contents/MacOS/mscore")
MSCORE3_BIN = os.environ.get(
    "OMR_MSCORE3_BIN", "/Applications/MuseScore 3.app/Contents/MacOS/mscore")


@dataclass
class ExportOutcome:
    """Result of one `export_pdf` call (one source, up to two attempts).

    `exit_code` and `timed_out` are recorded for diagnostics but must
    never be read as a success/failure signal by a caller -- `ok` is the
    only field that encodes that judgment, and it is derived solely from
    `pdf_is_complete(out_pdf)` (see module docstring: MS4 "success" can
    time out, and MS4 "success" can exit non-zero via crashpad).
    """
    ok: bool
    timed_out: bool
    exit_code: int | None
    retried: bool
    reason: str = ""


def _run_supervised(cmd: list[str], timeout_s: float):
    """Real subprocess runner: own process group, hard kill on timeout.
    This is the production implementation of the injected `run` seam
    (`export_pdf`'s default when no `run` is passed) and is deliberately
    NOT exercised by the test suite -- doing so would require a real
    `mscore` binary. Every supervision branch it feeds into
    (timeout-but-complete, non-zero-exit-but-complete, incomplete,
    retry, quarantine-worthy failure) is instead tested against a fake
    `run` callable in `Training/tests/test_export_pdf.py`.

    `start_new_session=True` puts the child in its own process group so
    a timeout kill (`os.killpg(..., SIGKILL)`) reaches any grandchildren
    MuseScore spawns too, instead of leaving them orphaned.
    """
    proc = subprocess.Popen(
        cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        proc.wait(timeout=timeout_s)
        return SimpleNamespace(returncode=proc.returncode, timed_out=False)
    except subprocess.TimeoutExpired:
        # The process may already have finished writing a complete PDF
        # (the MS4 "writes then hangs" shape) -- that is judged later by
        # pdf_is_complete, not here. This branch's only job is to make
        # sure nothing is left running.
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        proc.wait()
        return SimpleNamespace(returncode=None, timed_out=True)


def pdf_is_complete(path: Path) -> bool:
    """A PDF counts as complete iff it has a trailing `%%EOF` within the
    last 1024 bytes AND pypdfium2 can open it and report >= 1 page. The
    trailer check alone would accept a file whose xref table points past
    the end of a torn write; the page-count read alone would accept a
    zero-page but otherwise well-formed document. Both together is this
    module's whole completeness contract -- exit codes and timeouts are
    explicitly NOT part of it (see module + ExportOutcome docstrings)."""
    try:
        data = Path(path).read_bytes()
    except OSError:
        return False
    if b"%%EOF" not in data[-1024:]:
        return False
    try:
        doc = pdfium.PdfDocument(str(path))
        n = len(doc)
        doc.close()
        return n >= 1
    except Exception:
        return False


def mscore_version(mscore_bin: str, run=None) -> str:
    """Best-effort `mscore --version` string, for recording engine
    identity alongside a rendered batch. Distinct call shape from
    `export_pdf`'s `run` (which supervises a file-producing invocation
    and returns `(returncode, timed_out)`): this one captures text
    output, so its injected `run` is `Callable[[list[str]],
    SimpleNamespace(stdout, stderr)]`. The default (`run=None`) path
    invokes a real subprocess and is not exercised by the test suite for
    the same reason `_run_supervised` isn't: it would require a real
    `mscore` binary. Either stream may carry the version string
    depending on the build, so both are checked."""
    if run is None:
        completed = subprocess.run(
            [mscore_bin, "--version"], capture_output=True, text=True,
            timeout=60,
        )
        result = SimpleNamespace(stdout=completed.stdout, stderr=completed.stderr)
    else:
        result = run([mscore_bin, "--version"])
    return (result.stdout or result.stderr or "").strip()


def export_pdf(mscore_bin: str, source: Path, out_pdf: Path,
               timeout_s: float = 300.0, run=None) -> ExportOutcome:
    """Render `source` (a `.mscx`/`.mscz`) to `out_pdf` via `mscore_bin`,
    judging success only by `pdf_is_complete(out_pdf)` after each
    attempt -- never by `run`'s returncode/timed_out, which are recorded
    on the result but not trusted (see module docstring). Up to two
    attempts: any leftover `out_pdf` is removed before each `run` call
    so a stale file from a previous render can never be mistaken for
    this attempt's output. On two failed attempts, returns `ok=False`
    with a `reason` describing the last attempt for the caller to log
    and quarantine `source` into a failure list -- this function does
    not maintain that list itself.

    `run` defaults to `_run_supervised` (the real subprocess path) and
    is the injected seam tests use to simulate MuseScore's measured
    behaviors without invoking it: `Callable[[list[str], float],
    SimpleNamespace(returncode, timed_out)]`.
    """
    run = run or _run_supervised
    out_pdf = Path(out_pdf)
    retried = False
    last = SimpleNamespace(returncode=None, timed_out=False)
    for attempt in range(2):
        retried = attempt > 0
        out_pdf.unlink(missing_ok=True)  # stale output must not count
        last = run([mscore_bin, "-o", str(out_pdf), str(source)], timeout_s)
        if pdf_is_complete(out_pdf):
            return ExportOutcome(ok=True, timed_out=last.timed_out,
                                 exit_code=last.returncode, retried=retried)
    return ExportOutcome(
        ok=False, timed_out=last.timed_out, exit_code=last.returncode,
        retried=retried,
        reason=f"incomplete output after retry (exit={last.returncode}, "
               f"timed_out={last.timed_out})",
    )
