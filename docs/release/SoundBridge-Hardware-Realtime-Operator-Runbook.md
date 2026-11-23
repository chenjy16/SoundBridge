# SoundBridge — Hardware Realtime Validation Operator Runbook

**Status:** executed once, on one device and one format — the scope, the numbers
and the gaps are registered in
[Known-Limitations §2C](../risks/Known-Limitations.md#2c-硬件实时验证登记2026-11-23).
Every other scenario below is still unexecuted.
**Applies to:** a supervised run on an Apple-silicon Mac with the driver
installed, the proxy device present, and a physical output the operator can hear.

This runbook is written for a human operator sitting at the machine. It assumes
the operator can hear the output device. Every command below is either read-only
or explicitly marked as *state-changing*, and no state-changing command may be
run without the approval listed in §0.3.

> **One rule outranks every other instruction in this document:** the operator
> **must not leave the machine routed to SoundBridge** after the test. Restoring
> the original default output and verifying it is not an optional epilogue — it
> is the last mandatory step (§4), and a run without it is `INCOMPLETE`
> regardless of what the timing data says.

---

## 0. Preconditions

### 0.1 What must already be true

| Check | Command (read-only) | Expected |
|---|---|---|
| Driver present and loaded | `pgrep -fl "Core Audio Driver (SoundBridgeDriver.driver)"` | one process |
| Driver version | `defaults read /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist CFBundleShortVersionString` | `1.2.0` |
| Protocol matches the Host | `tools/check_protocol_layout.sh` | `0x00020200`, header 320 |
| App version | `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/SoundBridge.app/Contents/Info.plist` | `1.2.0` |
| No stale Host | `pgrep -fl SoundBridgeHost` | empty |
| No stale mapping | `ls /tmp \| grep -i soundbridge` | empty |
| Disk space for logs | `df -h /` | ≥ 1 GiB free |
| Harness builds | see §0.2 | exit 0 |

If the driver is missing or the wrong version, **stop**. Installing or replacing
it is approval `A7` in the assessment document and is not part of this runbook.

### 0.2 Build the harness (safe; writes only under `build/`)

```
mkdir -p build/hwvalidate

swiftc -O -swift-version 5 \
  -o build/hwvalidate/sb-hw-validate \
  tools/hardware-validation/sb-hw-validate.swift

clang -O2 -std=c11 -Wall -Wextra \
  -I packages/shared/include \
  -o build/hwvalidate/sb-shm-probe \
  tools/hardware-validation/sb-shm-probe.c
```

Both must compile with no warnings. `build/` is git-ignored; nothing here touches
the repository's tracked files.

### 0.3 Approvals that must be on record before any of §2

| ID | Approval |
|---|---|
| A1 | launching `SoundBridge.app` so the proxy device appears |
| A2 | selecting the SoundBridge device as the macOS default output |
| A3 | playing real audio through it |
| A4 | the 30-minute supervised window |
| A5 | CPU-load scenario H7 (if used beyond a 30 s smoke run) |
| A6 | H8 device removal / re-appearance |
| A10 | any production telemetry change (p99.9 field, bucket-count export) |

Do not read "you may inspect" as permission for A1–A6. They are separate.

---

## 1. Before testing

Run in this order. Steps 1–6 do not change audio state; step 7 is approval A1.

1. **Record the original default output** — name *and* UID:

   ```
   build/hwvalidate/sb-hw-validate inventory --out build/hwvalidate/runs/<runID>-before.json
   ```

   Read `defaults.defaultOutput.uid` out of that file and write it down in the
   report header. If the UID is missing, say so explicitly; do not substitute the
   display name.

2. **Record the original input device** (inventory only, never used):

   same file, `defaults.defaultInput.uid`.

3. **Record the machine**: macOS version/build, model, architecture, core count,
   memory, free disk. `inventory` captures OS version, cores and architecture;
   capture the model with `sysctl -n hw.model`.

4. **Confirm a known-good fallback physical output** (§1.3 of the assessment).
   On this machine: `BuiltInSpeakerDevice` (built-in), plus the two display
   outputs. A virtual or aggregate device is **not** a valid fallback — it cannot
   prove that audible output came back.

5. **Confirm the SoundBridge device is installed and available.** This is two
   different facts:
   * driver loaded — `pgrep -fl "Core Audio Driver (SoundBridgeDriver.driver)"`;
   * proxy device enumerated — `build/hwvalidate/sb-hw-validate inventory` must
     list a device whose UID starts with the SoundBridge prefix, or
     `/tmp/soundbridge-devices.txt` must exist and contain it.

   Before the Host runs, the second fact is false by construction. That is
   expected; step 7 fixes it.

6. **Confirm the test can be stopped immediately.** The operator must be able to
   hit `Ctrl-C` in the `collect` terminal, then quit the App from the menu bar.
   Both are instant and neither disturbs other applications.

7. *(approval A1)* **Launch the App** so the Host runs and the proxy appears:

   ```
   open -a /Applications/SoundBridge.app
   pgrep -fl SoundBridgeHost          # must now print one process
   ls /tmp | grep -i soundbridge      # mapping + devices.txt must now exist
   build/hwvalidate/sb-hw-validate inventory --out build/hwvalidate/runs/<runID>-host-up.json
   ```

   Confirm the SoundBridge device is now in the list and note its **UID**. The
   UID — not the name — is what every later command uses.

   **Which UID.** CoreAudio exposes the proxy as `<physicalUID>-soundbridge`
   (e.g. `410C54C2-0000-0000-051F-0103803C2278-soundbridge`), while the Host keys
   its shared mapping by the **physical** UID
   (`/tmp/soundbridge-501-410C54C2-…`). Pass the proxy UID to `collect` and
   `sb-hw-validate` strips the `-soundbridge` suffix itself when it derives the
   mapping path; `sb-shm-probe` takes either form. Verified on this machine: the
   file `/tmp/soundbridge-501-410C54C2-0000-0000-051F-0103803C2278` exists while
   `/tmp/soundbridge-501-410C54C2-…-soundbridge` does not.

8. **Confirm the Host is healthy** before playing anything:

   ```
   log show --last 2m --predicate 'subsystem == "com.soundbridge.host"' --style compact | tail -30
   log show --last 2m --predicate 'subsystem == "com.soundbridge.host"' --style compact | grep -ci "error\|degraded\|failed"
   ```

   Errors that pre-date the test must be understood before starting, not
   discovered mid-run.

9. **Confirm the operator is physically present for the whole window** and that
   the machine will not sleep (`caffeinate -dimsu` in a spare terminal is
   acceptable; it is not a routing change).

Discard `build/hwvalidate/runs/<runID>-host-up.json` if the SoundBridge UID is absent — that means
the App/Host did not actually publish a device, and the run would collect nothing.

---

## 2. During testing

### 2.1 Start the collector

```
build/hwvalidate/sb-hw-validate collect \
  --device-uid <SoundBridge UID from step 7> \
  --out-dir build/hwvalidate/runs/<runID> \
  --duration 1800 \
  --window 10
```

The first line it prints must show the **actual** bucket and deadline, e.g.
`bucket=48000Hz/512f deadline=10666.7us`. If the printed bucket is not the format
you expect, stop and reconcile before continuing — a wrong bucket means every
deadline in the report is wrong.

Sanity checks in the first 30 seconds:

| Check | Where | Expected |
|---|---|---|
| Callbacks are rising | `build/hwvalidate/runs/<runID>/result.md` written at the end; meanwhile `... collect` prints nothing per window, so in a second terminal run `log show --last 30s --style compact --predicate 'subsystem=="com.soundbridge.host"'` **on a timer**. Do not use `log stream` for this: it block-buffers into a pipe and shows nothing while the Host is alive | `Callback timing: n=` climbing by ≈ 86–94 per 5 s at 512/48000 (≈93.75 callbacks/s) |
| Observed vs expected rate | final JSON, `windows[].observedCallbackRateHz` / `expectedCallbackRateHz` | ratio 0.7–1.3 |
| Device is running | `windows[].ioRunning` | true |
| Driver counters reachable | first `collect` log line: `shared-memory probe: …` (not the "not found" warning) | path printed |

If `collect` exits with `NO CORE AUDIO IO OBSERVED`, nothing was rendering: the
SoundBridge device selected in step 7 is not the one macOS is playing through.
Re-check the default output. Do not "fix" this by editing the result file.

### 2.2 Select SoundBridge as the output *(approval A2)*

The operator does this manually — the harness will not. Verify afterwards, using
CoreAudio rather than the UI:

```
build/hwvalidate/sb-hw-validate inventory --out build/hwvalidate/runs/<runID>-routed.json
```

`defaults.defaultOutput.uid` must now be the SoundBridge UID.

### 2.3 Scenarios

Mark each scenario start/end with the marker command so the timeline is
self-describing. Use the exact strings the harness recognises for H8, `restore`,
and `skip` (case-insensitive substring match).

```
build/hwvalidate/sb-hw-validate marker --out-dir build/hwvalidate/runs/<runID> --note "H1 start"
build/hwvalidate/sb-hw-validate marker --out-dir build/hwvalidate/runs/<runID> --note "H1 end"
```

| ID | Scenario | How to drive it | Status expected on this machine |
|---|---|---|---|
| H1 | Stable playback baseline | play a long, gapless track; no EQ changes; 5–10 min | `PASS` if callbacks + rate ratio + zero overBudget hold |
| H2 | One-band EQ update | change a single band in the App UI a few times, ~2 s apart | `PASS` / `FAIL` |
| H3 | Ten-band EQ update | change all ten bands (or apply a preset), ~2 s apart | `PASS` / `FAIL` |
| H4 | Preamp change | sweep preamp in steps; listens for clipping/zipper noise | `PASS` / `FAIL`, with symptoms recorded |
| H5 | Hostile snapshot writer | drive the **existing** preset/EQ path as fast as the UI allows; do **not** add a stress hook | `PASS WITH LIMITATION` — refused snapshot reads are only visible if the Host logs them; a refused read that produces no log entry is `not observable`, not "zero" |
| H6 | Publish contention / refusal | — | **`SKIPPED — NOT SAFELY REPRODUCIBLE`**. There is no supported way to hold `PublisherToken` from outside the Host; the only way would be a production test hook, which the task forbids. A skipped H6 must be reported as skipped, never as passed |
| H7 | Reversible CPU load | `collect … --cpu-load 4` (starts 4 × `/usr/bin/yes`, kills them on exit) or run stress externally | `PASS` / `FAIL`. Must be announced before it starts |
| H8 | Device removal / re-appearance | disconnect the **physical** device the proxy feeds, or switch away and back | **Not executed in F0–F2**; needs approval A6 |

Notes that keep the data honest:

* H5 must not become a contest to provoke refusals. "No refusal observed" is a
  valid, reportable outcome; it is not a failure and it is not a pass of some
  other property.
* H6 must never be reported as passed. If someone later finds a supported way to
  induce contention, it becomes its own scenario with its own evidence.
* H7's load processes are killed by the harness on exit (`defer { kill(pid,
  SIGTERM) }`). If the harness is SIGKILLed, verify with `pgrep yes` and kill
  them manually.

### 2.4 Format and buffer changes

Never change the sample rate or buffer size deliberately during a run. If either
changes on its own (display hotplug, another app, a device sleep), the harness
records a `format-changed` entry with old/new bucket, old/new deadline and a
timestamp, and starts a **new window**. Do not merge the two windows when reading
the report, and do not compare their `overBudget` values as if they shared a
deadline.

Deadline arithmetic, for checking the report by hand:

```
deadline_us = frames / sample_rate * 1e6
   64 / 48000  =  1333.3 µs
  128 / 48000  =  2666.7 µs
  512 / 48000  = 10666.7 µs
 1024 / 48000  = 21333.3 µs
```

### 2.5 Audible symptoms

Every symptom gets a timestamp and a scenario tag, immediately:

```
build/hwvalidate/sb-hw-validate marker --out-dir build/hwvalidate/runs/<runID> --note "H3 click at 00:04:12"
build/hwvalidate/sb-hw-validate marker --out-dir build/hwvalidate/runs/<runID> --note "H1 dropout ~0.5s"
```

Use the words `click`, `dropout`, or `symptom` so the report's criterion C7 can
tell a symptom marker from a scenario marker. "I heard nothing wrong" is also
worth a marker (`"H1 no symptom heard"`) — absence of a report is not evidence of
absence of a symptom.

### 2.6 Abort conditions

Stop immediately — `Ctrl-C` the collector, then restore output per §4 — on any of:

* persistent audible dropouts (more than a brief click), or audio that stops
  entirely and does not come back;
* the SoundBridge device disappearing and not returning;
* a fan ramp to maximum, or the machine becoming uncomfortably hot;
* runaway CPU (`--cpu-load` processes not accounted for, or `top` showing a
  sustained unexplained load);
* loss of the fallback output path — i.e. you are no longer sure you can get
  sound back;
* the operator has to leave.

An aborted run is a legitimate result. Record the abort reason as a marker and in
the report; the verdict becomes `INCOMPLETE`, not `FAIL`, unless a criterion was
actually violated.

---

## 3. Producing the report

The collector writes `build/hwvalidate/runs/<runID>/result.json` and `result.md`. The Markdown is
machine-generated; the human report is the template:

```
cp tools/hardware-validation/report-template.md build/hwvalidate/runs/<runID>/report.md
```

Fill in every field from evidence, and delete nothing:

* a metric that could not be read is written `not observable`, never `0`;
* a scenario that was skipped keeps `SKIPPED — <reason>`;
* a scenario that never ran is `NOT EXECUTED`, which is different from skipped;
* if `p99.9` is requested and unavailable, the report says
  `p99.9 — not observable (TimingSnapshot exposes up to p99)`.

Re-rendering the Markdown from JSON must not require the machine to be in any
particular state:

```
build/hwvalidate/sb-hw-validate report --results build/hwvalidate/runs/<runID>/result.json
```

### 3.1 Verdict

Exactly one of:

* `PASS — HARDWARE REALTIME VALIDATION VERIFIED`
* `CONDITIONAL PASS — HARDWARE VALIDATION WITH DOCUMENTED LIMITATIONS`
* `FAIL — HARDWARE REALTIME VALIDATION FAILED`
* `INCOMPLETE — REQUIRED HARDWARE EVIDENCE MISSING`

The existing software verdict
(`PASS — SOFTWARE INTEGRATION VERIFIED; HARDWARE REALTIME VALIDATION PENDING`)
is a separate statement and is not edited by a hardware run.

`PASS` requires all ten criteria in the assessment/template to be met, including
restoration. Any `NOT OBSERVABLE` required metric, any `NOT EXECUTED` scenario, or
an unverified restore forces `INCOMPLETE`. A `CONDITIONAL PASS` is the ceiling
when p99.9 is unavailable (it always is, until approval A10) or the collection
was shorter than 60 s.

---

## 4. After testing — mandatory

Order matters. Steps 1–3 are the ones that keep the machine usable.

1. **Restore the original default output** using the UID recorded in §1 step 1.
   On this machine that is currently PHL 279M1RV,
   `410C54C2-0000-0000-051F-0103803C2278`. This is the operator's action; the
   harness does not do it.

2. **Verify the restored device UID** — not the name, and not the UI label:

   ```
   build/hwvalidate/sb-hw-validate inventory --out build/hwvalidate/runs/<runID>-after.json
   ```

   `defaults.defaultOutput.uid` must equal the value from §1 step 1. Record the
   result as a marker the report can cite:

   ```
   build/hwvalidate/sb-hw-validate marker --out-dir build/hwvalidate/runs/<runID> \
     --note "restore verified: default output UID = 410C54C2-0000-0000-051F-0103803C2278"
   ```

3. **Verify normal output playback** — play something and listen. This is not
   optional: a correct UID with silent output is still a broken machine.

4. **Quit the App** (menu bar → Quit). Then confirm the Host and the proxy are
   gone:

   ```
   pgrep -fl SoundBridgeHost          # must be empty
   ls /tmp | grep -i soundbridge      # must be empty
   build/hwvalidate/sb-hw-validate inventory   # SoundBridge device gone
   ```

   The App removes `/tmp/soundbridge-*` on a clean quit; that is what makes the
   driver retire the proxy device.

5. **Confirm Host and Driver health**: coreaudiod still running, driver helper
   still resident, no new errors in the last 5 minutes of the Host subsystem.

6. **Preserve the raw material.** Do not edit, trim, or "clean up" `result.json`,
   `result.md`, `markers.jsonl`, or saved `log show` output. If a log excerpt is
   needed in the report, paste it verbatim.

7. **Generate the final report** from the template (§3), state the verdict, and
   state explicitly which scenarios were skipped and which metrics were
   unobservable.

8. **Confirm the machine is not routed to SoundBridge.** Read the UID once more,
   after the App has been quit, and paste it into the report's final line. This
   is the check that closes the run.

---

## 5. Commands that are not run during F0–F2

Listed so that "prepared" is never confused with "executed". Each requires an
approval from §0.3.

```
open -a /Applications/SoundBridge.app                       # A1
# select SoundBridge as default output in System Settings   # A2
# play audio                                                # A3
build/hwvalidate/sb-hw-validate collect --device-uid … --duration 1800   # A4
build/hwvalidate/sb-hw-validate collect … --cpu-load 4                   # A5
# disconnect / re-connect the physical device               # A6
sudo tools/sb_install_transaction.sh …                      # A7  (never in F3 either)
sudo tools/uninstall_driver.sh                              # A7
sudo killall coreaudiod                                     # A8
make dmg ; make full-release                                # not needed for F3
git commit / git tag / git push                             # forbidden by the task
```

---

## 6. Known limitations the operator must repeat in the report

1. **No p99.9.** `TimingSnapshot` exposes up to p99. Adding it is approval A10.
2. **Quantiles are cumulative since the Host started**, not per window. Per-window
   counts are true deltas; per-window quantiles are not available.
3. **H6 cannot be run** without a production test hook, which is forbidden.
4. **Driver underruns** are read out-of-band from the live mapping; the Host's own
   log line is redacted and cannot be used.
5. **A counter is not an ear.** Zero driver underruns does not prove nobody heard
   a dropout, and a recorded click does not prove the callback missed its
   deadline. Both must be reported side by side, not merged into one verdict.
