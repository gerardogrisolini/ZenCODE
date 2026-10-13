# Independent CPR / native-history validation

This is a validation handoff, not evidence of a passing run. The implementation
agent did not run builds, tests, or GUI automation. The prior Python prototype
proved only its documented ASCII resize transitions, not this Swift integration.

## Automated gates

Run the normal SwiftPM build and TUI tests first. In particular:

```sh
unset ZENCODE_SUPPORT_DIRECTORY ZENCODE_CPR_HARNESS_DIR ZENCODE_CPR_HARNESS_TTY
swift build --target ZenCODECore
swift test --filter TerminalCursorReportTests --no-parallel
swift test --filter TerminalPrimaryScreenTests --no-parallel
swift test --filter TerminalSharedChatReaderDockTests --no-parallel
swift test --filter TerminalStatusBarRenderingTests --no-parallel
swift test --filter TerminalChatRenderCoordinatorTests --no-parallel
swift test --filter TerminalCheckboxMenuRenderingTests --no-parallel
swift test --no-parallel
```

The regular test suites install their own support-directory sandbox. Do not
export a shared `ZENCODE_SUPPORT_DIRECTORY` for these commands: it overrides that
sandbox and can contaminate later suites. The opt-in real-terminal harness below
requires its own explicitly isolated support directory instead.

The new fixtures inject their own report demultiplexer and primary screen; they
must not call `activate` or install a global writer. The combined-sink/cursor-edge
fixtures now send transcript through the product compositor and use its explicit
cursor seam, not out-of-band writes that silently invalidate its physical anchor.
The lightweight VT model is not an Apple Terminal emulator and cannot establish
real-terminal correctness on its own.

Repair regressions cover `ESC[20` received **before** query arming followed by
`0~` and pasted `CSI 10;1 R`; a fresh isolated Escape after timeout with no reply;
a bounded old truncated report prefix; unsupported 80x24 → 20x48 with content
below stale row 24; and queued chunks drained once, in order, by both stop and
new-session preparation, before/after query arming. The dock-growth fixture
asserts exact CRLF row allocation: its sink receives raw VT bytes, not LF text
normalized by termios. It still asserts reserve growth and the new margin.

The latest independent gate passed build and the full 3112-test/216-suite run,
but the real Swift harness failed at the first 80x24 → 45x24 resize: a CPR query
was written, followed about 0.799 s later by `cursor report failed or stale`.
The 60 complete payloads survived; the partial Unicode continuation was separated
by fallback chrome, with no demonstrated byte loss. This is **not a runtime pass**.
Evidence: `/private/tmp/zencode-swift-cpr-validation-ba37a4a8-f0d7-4820-ae03-1da63ec7a096/REPORT.md`.
The subsequent change is diagnostic-only, not a handshake fix: the previous logs
cannot distinguish absent/rejected CPR, callback delay, or stale generation.
New diagnostics and fixtures have not been built/run by their implementer.

## Swift harness in a fresh, isolated Apple Terminal window

Use a **new Terminal window**, not the operator's existing chat terminal. No
profile, provider, network, GUI-driving code, or new production CLI flag is used.
Build tests beforehand, then run only this filtered opt-in test. Redirect test
runner stdout/stderr to a file: unsolicited test-runner text must not share the
screen owned by the harness. The `swift test --skip-build` wrapper did not leave
the test process in the foreground group in the observed runtime. Use the direct
Swift Testing helper below with the already-built Mach-O test executable (not the
`.xctest` directory). This is not a production CLI. The harness opens `/dev/tty`
with `O_RDWR`, checks the explicit tty and foreground group, and passes that fd
to raw input/output. It does not rewire stdin or read keys from a second fd.

Example, typed in that new window:

```sh
cd /Users/gerardo/Projects/ZenCODE
ROOT="/private/tmp/zencode-swift-cpr-$(uuidgen)"
(umask 077 && mkdir "$ROOT") || exit 1
mkdir -p "$ROOT/support" || exit 1
export ZENCODE_CPR_HARNESS_DIR="$ROOT"
export ZENCODE_CPR_HARNESS_TTY="$(tty)"
export ZENCODE_SUPPORT_DIRECTORY="$ROOT/support"
printf '%s\n' "$ROOT"
DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
DYLD_LIBRARY_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper \
  --test-bundle-path /Users/gerardo/Projects/ZenCODE/.build/out/Products/Debug/ZenCODECoreTests.xctest/Contents/MacOS/ZenCODECoreTests \
  --testing-library swift-testing --filter TerminalNativeCPRHarness/isolatedTerminalSession --no-parallel \
  > "$ROOT/test-runner.log" 2>&1
```

Create `$ROOT/support` **before** launching: Foundation symlink resolution of a
nonexistent leaf can retain `/private/tmp`, failing the normalized support guard.
The Xcode helper/library paths above are the invocation used by the real driver;
adjust them together only for another Xcode installation. The environment is
limited to this new window/command, never exported into the automated test gates.

The harness refuses a mismatched/non-foreground tty, a directory without a UUID
suffix directly under `/private/tmp`, or support storage outside `$ROOT/support`.
It exclusively claims the directory and log: **never reuse an earlier run's
root**, including the failed run above. `/dev/tty` may identify itself by that
alias; in that case the explicitly named device is checked against the same
foreground process group before raw mode is entered. No existing tty is targeted
or foreground ownership changed. It restores termios, releases margins, closes
its modal, and exits after `quit` or a 240-second bound. It opens no app session
and contacts no service. Run only the filtered harness in its foreground session;
stdin forwarding is not a prerequisite. There is no shared `*-current` pointer.

An external validator writes atomic `cmd-0001.json`, `cmd-0002.json`, etc. into
`$ROOT`. Each has an `op`; `append` also has `text`. Wait for the corresponding
`ack-0001.json` before sending another command. `ready.json` records tty/pid and
initial dimensions, `writes.jsonl` records the actual product VT writes,
`finished.json` records submitted input and menu outcome. `snapshot` can poll
`queryPending`, `appendOnly`, draft, submitted text and menu outcome.

`cpr-diagnostics.jsonl` is emitted only by the opt-in test's injected sink. It
records request IDs, raw input bytes/read boundaries/errors, report parsing and
callback scheduling/delivery, resize/query generations and geometry, plus termios
and foreground-group snapshots at commands. It is capped at 16,384 events of at
most 512 characters plus one `diagnostic.truncated` record; timestamps include
monotonic uptime. Treat this artifact as input-sensitive: use synthetic input
only. Production instances have a nil sink and do not log input. The sink does
not read the tty or acquire TUI locks. Compare `screen.query.written`,
`raw.device.byte`, `report.parsed`, `report.delivery.begin`, and
`screen.completion.locked` to separate absent bytes, parser rejection, callback
scheduling delay, and stale/invalid anchors; `report.failure` identifies timeout
or cancellation. A truncation or scheduling perturbation is not success evidence.

The latest corrected external driver is in the evidence root above (`driver.py`,
`harness.sh`, `writes.jsonl`). Preserve its explicit capture form:
`get contents of tab 1 of window id <owned-id>` (and separately `history`).
`contents of t` returned an object-specifier string in an earlier attempt.
Guard every operation by the newly owned window ID and tty, never the front
window. History and viewport must not be concatenated. The driver's `input_text`
uses `do script`, which is **not proven raw key injection**; do not use it to claim
Space/Enter/Escape or draft-edit success. Menu open/close commands exercise lifecycle,
not keyboard handling.

Commands:

- `{"op":"append","text":"PAYLOAD-000|...\n"}` — streamed product output.
  Use multiple commands for partial lines, split `e` + combining accent,
  emoji + ZWJ + emoji, flags, split SGR/OSC and CR/LF.
- `{"op":"menu"}` — reserved primary-screen checkbox surface, prompt inactive.
  Space toggles, arrows move, Enter confirms, Escape cancels. The same raw input
  instance handles keys, paste and CPR; there is no second tty reader.
- `{"op":"close"}` — cancel and close the menu.
- `{"op":"resize"}` — after physically resizing the **named fresh window**,
  sample its real geometry and invoke the product status-bar resize path. The
  screen's SIGWINCH generation gates output before this command arrives. Poll
  `snapshot` until `queryPending` is false before judging the resulting screen.
- `{"op":"fault"}` — explicitly inject the product CPR-failure fallback for
  interactive inspection. This is a test-only injection, not a claim that the
  real terminal stopped replying; timeout/late reply are separate pipe tests.
- `{"op":"snapshot"}` / `{"op":"quit"}` — inspect / clean shutdown.

Required evidence: the 80x24 → 45x24 → 80x24 → 80x18 → 45x18 → 80x24 cycle,
including two physical resizes before a commit; unique/in-order payload markers
across native history + viewport; one visible footer/menu; output during menus;
partial output continuing after resize; split Unicode and escapes; CR and LF at
right margin; height <= 5; 80x24 → 20x48 fallback with transcript below row 24;
timeout/rejected CPR with no selection/default applied; preserved draft that
visibly accepts edits and can actually submit, including isolated Escape then `f`
after a timeout with no reply.
Save VT logs, screen/history capture and explicit expected payload alongside the
report. Do not infer history preservation from only the final visible screen.

## Protocol and remaining limits to review

CPR has no request ID. A session permits one in-flight query. Timeout/cancellation
fences future queries; one late numeric `CSI row;column R` is drained, then such
sequences again belong to ordinary key parsing (including modified F3). While a
report is outstanding, a key with exactly that wire representation is inherently
indistinguishable from CPR. Arming is refused without changing input state when
any ESC/CSI prefix is already buffered, including an opening paste delimiter.
Only a report prefix already present at timeout/cancellation gets a 750 ms grace
period; an unfinished prefix is then released without dropping bytes. Newly
pressed Escape/partial CSI follows ordinary raw-reader polling, even while one
late complete report is expected. Test both cases; do not add blind query retries.

The writer retains only the unfinished paragraph to compute continuation and
repair its last grapheme, not to replay transcript. Escape buffering is bounded.
Actual Unicode widths still depend on the terminal/font; especially exercise
wide glyphs at the last cell, variation selectors, ZWJ and CR overwrite.
The fallback preserves unknown chrome rather than erasing guessed coordinates.
It resets DECOM/margins, uses `CUP 999999;1` clamped by the emulator to the current
physical bottom, then allocates a fresh line with CRLF; no stale height is used.
Verify this clamp on the real emulator as part of the tall/narrow resize gate.
Shutdown/restart also drains pending chunks without erasure when resize ownership
is stale, even before the debounced query was armed. Obsolete chrome can remain
in native history. No ED3/RIS/history cleanup is
allowed. Direct uncoordinated binary/TTY writes are outside the compositor's
ownership contract and must not be introduced by the harness.
