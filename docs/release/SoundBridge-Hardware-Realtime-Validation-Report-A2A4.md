# SoundBridge Hardware Realtime Validation — Real CoreAudio Run (approvals A2–A4)

> This is a **real** run, not a template and not a rehearsal. Every number below
> comes from `build/hwvalidate/runs/a2a4/run1/result.json` (machine-readable
> source of truth), from `sb-shm-probe` reading the live shared mapping, or from
> a verbatim `log show` line quoted at the point of use.
>
> Approval scope for this run: **A2** (route the default output to the proxy),
> **A3** (play real test audio, observe for 30 minutes), **A4** (run the agreed
> H7 CPU-load scenario), then restore the original physical output. H8 (device
> removal), driver install/uninstall, CoreAudio restart, machine restart, SIP
> changes and production code changes were **not** authorised and were **not**
> performed.

---

## 1. Run identity

| Field | Value |
|---|---|
| Run ID (`result.json → runID`) | `775205DC-2832-4D37-964A-3008422B0858` |
| Observation start (UTC) | `2026-11-23T08:13:10.540Z` |
| Observation end (UTC) | `2026-11-23T08:43:10.624Z` |
| Observation start (local) | `2026-11-23T16:13:10.540+08:00` |
| Observation end (local) | `2026-11-23T16:43:10.624+08:00` |
| Requested duration | 1800 s (30 min) |
| Windows recorded | 180 of 180 requested, window length 10 s |
| Timezone (`result.json → timezone`) | `Asia/Shanghai` |
| Approvals on record | A1 (launch), A2 (route), A3 (play + 30 min), A4 (H7) |
| Harness revision | `main@eb45303` + uncommitted `tools/hardware-validation/*` (see §12) |
| Operator | user; the agent drove the tooling and observed the machine |

### 1.1 Timeline (from `markers.jsonl`, verbatim)

```
{"timestamp":"2026-11-23T08:12:42Z","note":"(playback-start.txt) afplay test-tone-32min.wav started"}
{"timestamp":"2026-11-23T08:12:55.739Z","note":"H1 start — stable playback baseline, afplay test-tone-32min.wav at -24 dBFS, routed to the proxy"}
{"timestamp":"2026-11-23T08:22:55.764Z","note":"H7 start — 4 x /usr/bin/yes CPU load for 300s"}
{"timestamp":"2026-11-23T08:27:55.793Z","note":"H7 stop — CPU load processes killed"}
{"timestamp":"2026-11-23T08:43:13.274Z","note":"H1 end — collect exited rc=0"}
{"timestamp":"2026-11-23T08:43:43.159Z","note":"restore verified — default output UID is 410C54C2-0000-0000-051F-0103803C2278 (physical PHL 279M1RV), read back after the write"}
```

The first line of the block above is taken from `playback-start.txt` rather than
`markers.jsonl`; the other five are the markers verbatim.

## 2. Machine

| Field | Value |
|---|---|
| macOS version / build | `27.2.1 / 26B131` |
| Model | `Mac16,10` (Mac mini, Apple M4) |
| Architecture | `arm64` |
| Logical cores | 10 |
| Memory | 16 GB |
| Free disk at start / end | 125 GiB / 124 GiB |
| Load average at start / end | `3.16 3.29 3.33` / `2.96 2.82 3.22` |

The machine was **not** otherwise idle: baseline load average was ~3 on 10 cores
before the run began, from unrelated user processes. This is stated rather than
corrected for, because silencing the machine would have changed the conditions
under test.

## 3. Software under test

| Field | Value |
|---|---|
| Driver path | `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver` |
| Driver `CFBundleIdentifier` | `com.soundbridge.driver` |
| Driver version | `1.2.0` |
| Driver protocol / header size | `0x00020200 / 320` bytes |
| Driver loaded (helper process) | yes — `48806 Core Audio Driver (SoundBridgeDriver.driver)` |
| Host path | `/Applications/SoundBridge.app/Contents/MacOS/SoundBridgeHost` |
| Host pid | `71610` |
| App pid | `71605` |
| Version (`VERSION`) | `1.2.0` |
| Host launch mechanism | spawned by `SoundBridgeApp` (no launchd) |

`coreaudiod` (`48791`) and the driver helper (`48806`) were **not** restarted at
any point; both pids are unchanged from before A1.

## 4. Device and routing

| Field | Value |
|---|---|
| Original default output — name | `PHL 279M1RV` |
| **Original default output — UID** | `410C54C2-0000-0000-051F-0103803C2278` |
| Device under test — name | `PHL 279M1RV (SoundBridge)` |
| **Device under test — UID** | `410C54C2-0000-0000-051F-0103803C2278-soundbridge` |
| Device under test — `AudioDeviceID` | 144 (physical device is 124) |
| Shared-memory mapping used | `/tmp/soundbridge-501-410C54C2-0000-0000-051F-0103803C2278` |
| Routed to SoundBridge | `2026-11-23T07:55:0xZ` — `sb-set-default-output --uid …-soundbridge`, read back OK (inventory before `07:54:58.643Z` still showed the physical device; inventory after `07:55:09.843Z` showed the proxy) |
| Routed back to original | `2026-11-23T08:43:43Z` — `sb-set-default-output --uid …410C54C2…`, read back OK |
| **Restore verified by UID** | yes — after the write, again in a separate process (`--verify`), and again in `after-restore.json` (`08:43:43.149Z`, UID `410C54C2-…`) |
| Normal output playback verified by ear | **not verified** — no human listening was arranged (§8) |

### 4.1 Actual format (not the requested one)

| Field | Value | Source |
|---|---|---|
| Sample rate | `48000` Hz | `kAudioDevicePropertyNominalSampleRate`, and stream physical format, both agree |
| IO buffer frames | `512` | `kAudioDevicePropertyBufferFrameSize` |
| Deadline | `10666.7 µs` | `512 / 48000 × 1e6` |
| Channels | 2 | stream configuration |
| Bucket key | `48000Hz/512f` | one bucket for the whole run |

### 4.2 Format changes observed during the run

`result.json → formatChanges` is an empty array. No
`nominal-sample-rate-changed`, `buffer-frame-size-changed` or
`device-disappeared` listener event fired in 1800 s of observation. The Host
does not log rate or buffer changes at all, so this conclusion rests on the
harness's own CoreAudio property listeners, not on Host output.

## 5. Scenario results

| ID | Scenario | Status | Evidence | Notes |
|---|---|---|---|---|
| H1 | Stable playback baseline | `PASS` | 180 windows, 169686 callbacks, 0 `overBudget`, rate ratio 1.00 | synthetic tone, single format |
| H2 | One-band EQ updates | `NOT EXECUTED` | — | requires EQ UI changes; outside A2–A4 |
| H3 | Ten-band EQ updates | `NOT EXECUTED` | — | same |
| H4 | Preamp changes | `NOT EXECUTED` | — | same |
| H5 | Hostile snapshot writer | `NOT EXECUTED` | refused reads: `not observable` | needs an unsupported writer |
| H6 | Publish contention / refusal | `SKIPPED — NOT SAFELY REPRODUCIBLE` | no supported mechanism to hold the token from outside the Host; a test hook is forbidden | must never be reported as passed |
| H7 | Reversible CPU load | `PASS` | 4 × `/usr/bin/yes`, `08:22:55Z` → `08:27:55Z` (300 s), 0 `overBudget` in the overlapping 31 windows | see §9 |
| H8 | Device removal / re-appearance | `NOT EXECUTED` | — | needs approval A6; explicitly withheld |

## 6. Per-window timing

`p50/p95/p99/max` are **cumulative since `AudioRenderer` was constructed**, not
per window; `callbacks`, `overBudget` and `underrun` are true per-window deltas.
`Q = C` for every row (cumulative). p99.9 is `not observable` for every row (§10).

| # | Start (UTC) | End (UTC) | Bucket | Deadline µs | Callbacks | obs/exp rate | overBudget | p50 µs | p95 µs | p99 µs | **p99.9 µs** | Max µs | max≥floor | underruns | Q |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|:--:|---:|:--:|
| 0 | 08:12:56 | 08:13:06 | `48000Hz/512f` | 10666.7 | 469 | 93.80 / 93.75 | 0 | 28 | 68 | 72 | `not observable` | 322 | no | 0 | C |
| 1 | 08:13:06 | 08:13:16 | `48000Hz/512f` | 10666.7 | 938 | 93.79 / 93.75 | 0 | 28 | 68 | 72 | `not observable` | 322 | no | 0 | C |
| 29 | 08:17:48 | 08:17:58 | `48000Hz/512f` | 10666.7 | 468 | 93.60 / 93.75 | 0 | 30 | 68 | 72 | `not observable` | 322 | no | 0 | C |
| 58 | 08:22:40 | 08:22:50 | `48000Hz/512f` | 10666.7 | 937 | 93.69 / 93.75 | 0 | 30 | 68 | 74 | `not observable` | 322 | no | 0 | C |
| 59 | 08:22:50 | 08:23:01 | `48000Hz/512f` | 10666.7 | 938 | 93.80 / 93.75 | 0 | 30 | 68 | 74 | `not observable` | 322 | no | 0 | C |
| 60 | 08:23:01 | 08:23:11 | `48000Hz/512f` | 10666.7 | 1406 | 93.74 / 93.75 | 0 | 30 | 68 | 74 | `not observable` | 322 | no | 0 | C |
| 74 | 08:25:22 | 08:25:32 | `48000Hz/512f` | 10666.7 | 938 | 93.79 / 93.75 | 0 | 30 | 68 | 72 | `not observable` | 322 | no | 0 | C |
| 88 | 08:27:43 | 08:27:53 | `48000Hz/512f` | 10666.7 | 469 | 93.80 / 93.75 | 0 | 30 | 68 | 72 | `not observable` | 322 | no | 0 | C |
| 89 | 08:27:53 | 08:28:03 | `48000Hz/512f` | 10666.7 | 1406 | 93.74 / 93.75 | 0 | 30 | 68 | 72 | `not observable` | 322 | no | 0 | C |
| 90 | 08:28:03 | 08:28:13 | `48000Hz/512f` | 10666.7 | 938 | 93.79 / 93.75 | 0 | 30 | 68 | 72 | `not observable` | 322 | no | 0 | C |
| 120 | 08:33:05 | 08:33:15 | `48000Hz/512f` | 10666.7 | 937 | 93.71 / 93.75 | 0 | 30 | 68 | 72 | `not observable` | 322 | no | 0 | C |
| 150 | 08:38:08 | 08:38:18 | `48000Hz/512f` | 10666.7 | 469 | 93.61 / 93.75 | 0 | 30 | 68 | 74 | `not observable` | 322 | no | 0 | C |
| 179 | 08:43:00 | 08:43:10 | `48000Hz/512f` | 10666.7 | 937 | 93.70 / 93.75 | 0 | 32 | 68 | 74 | `not observable` | 322 | no | 0 | C |

Rows 2–28, 30–57, 61–73, 75–87, 91–119, 121–149 and 151–178 are omitted here
only for length; all 180 rows are in `result.json → windows[]` and in
`result.md`.

Why a window sometimes holds 1406 callbacks instead of ~938: the Host emits one
`Callback timing:` line every ~5 s, and a window's delta is measured between the
newest sample before it and the newest sample inside it. When the boundary falls
such that the covered span is ~15 s, the delta is ~1406 callbacks. The rate
column divides by that span, which is why it stays at ~93.7 Hz instead of
inflating.

**Totals**

| Field | Value |
|---|---|
| Windows recorded | 180 |
| Total callbacks | 169686 |
| Windows with zero callbacks | 0 |
| Callbacks per window, min / max | 468 / 1407 |
| Total `overBudget` in bucket `48000Hz/512f` | **0** |
| Total excess | 0.0 ms |
| Driver underruns during the run | **0** (sum of per-window deltas) |
| Ring overruns during the run | **0** (sum of per-window deltas) |
| Underrun source | `sb-shm-probe (read-only mmap of the live mapping)` |
| Log sources seen | `SoundBridgeHost=729` — and nothing else |
| Cumulative max, whole run | 322 µs, never saturated (real maximum, not a floor) |
| Cumulative p50 / p95 / p99, range over the run | 28–32 / 68 (constant) / 72–74 |

### 6.1 The strongest single piece of evidence that real audio flowed

The Host's `Callback timing:` line carries a `silence=` counter, which counts
callbacks that emitted a silence/refusal block instead of ring data. Before
playback started it was climbing with every callback. During playback it was
frozen, while `n` kept rising at the expected rate. Verbatim, mid-run:

```
2026-11-23 16:33:18.734 Df SoundBridgeHost[71610:2bde10] [com.soundbridge.host:AudioRenderer] Callback timing: n=268118 min=0.0us p50=30.0us p95=68.0us p99=72.0us max=322.0us overBudget=0 excess=0.0ms silence=52927
2026-11-23 16:33:23.735 Df SoundBridgeHost[71610:2bde10] [com.soundbridge.host:AudioRenderer] Callback timing: n=268587 min=0.0us p50=30.0us p95=68.0us p99=72.0us max=322.0us overBudget=0 excess=0.0ms silence=52927
```

`n` advanced 469 in 5 s (93.8/s) while `silence` stayed at 52927 — the same value
it held before `afplay` was started. Every one of the 169686 counted callbacks
therefore produced real ring content, not a silence fallback. This is a stronger
statement than "the callback ran": it says the ring was being fed.

## 7. Events and recovery

`result.json → events[]` contains 366 entries, of which 365 are the Host's
periodic `Render path: inFlight=0 deferred=false holdsMapping=true
retireTimeouts=0` line (classified `render-path`) and 1 is the harness's own
`collector` start event.

**No** `host-recovery`, `host-recovery-failure`, `device-hotplug`,
`host-degraded`, `host-shutdown`, `driver-underrun` or `ring-overrun` event was
logged at any point. This is zero observed, **not** proof that recovery works:
H8 was withheld, so nothing exercised it (C6).

## 8. Audible symptoms (operator)

`not assessed`. No human was positioned to listen, and the agent cannot hear.
`result.json` records C7 as `MET (none reported)` — that phrase means "no symptom
was reported", which is the weak claim. It does **not** mean the audio was
confirmed audible, and it must not be read as such. Nobody verified that the
-24 dBFS tone reached the monitor's speakers at an audible level.

## 9. Load and thermal

| Field | Value |
|---|---|
| CPU load scenario | `4 × /usr/bin/yes`, started `2026-11-23T08:22:55.764Z`, killed `2026-11-23T08:27:55.793Z` (300 s); `pgrep -x yes` = 0 afterwards |
| Load average before / during peak / after | `3.16` / `6.47` / `2.96` |
| Windows overlapping H7 | 31 |
| Callbacks in those windows | 29531 |
| `overBudget` in those windows | **0** |
| Host `cpu=` field | `0.0%` for all 180 windows |
| Thermal pressure | `not observable` — `pmset -g therm` reports no thermal or performance warning level recorded |
| Fan behaviour | `not observable` |

The `cpu=` field is the DSP load figure the Host prints; it read `0.0` (one
decimal place) in every window, including under load. That is not evidence the
render thread used no CPU — it means the figure is too coarse to resolve it.
Per-window timing latency is the metric that actually moved: cumulative p50
drifted 28 → 30 µs as load was applied and stayed at 30 after it was removed,
and settled at 32 µs by the end of the run. Because p50 is cumulative, this is
drift in the running distribution, not a per-window measurement.

Nothing at any point approached the 10666.7 µs deadline: the worst single
callback observed in 30 minutes was 322 µs, 33× under budget.

## 10. Telemetry limitations — carried forward verbatim

| Limitation | Statement |
|---|---|
| p99.9 | `not observable` — `AudioRenderer.TimingSnapshot` exposes p50/p95/p99/max only; `rf_rt_hist_quantile_bucket()` could supply it with one added field (approval A10, not applied) |
| Per-window quantiles | unavailable — the histogram is cumulative since `AudioRenderer` construction and exposes no bucket counts. Every `p50/p95/p99` above describes the run so far, not its own 10 s |
| Driver underruns via Host log | `not observable` — the Host's `Buffer underrun: +N (total: T)` line interpolates Ints without `privacy: .public` and arrives redacted; counters were read out-of-band from the live mapping instead |
| H6 contention | `SKIPPED — NOT SAFELY REPRODUCIBLE` |
| H8 removal | `NOT EXECUTED` — requires approval A6 |
| Audibility | a counter cannot prove nothing was heard, and a heard click cannot prove a deadline miss |

One further limitation applies to the observer itself: it reads the log by
re-running `log show --last 12s` every 5 s (see §12), i.e. ~360 extra processes
over the run. That cost is small but not zero, and it is part of what was
measured.

## 11. Verdict

**Verdict:** `INCOMPLETE — REQUIRED HARDWARE EVIDENCE MISSING`

**Reasons:**

1. p99.9 latency is `not observable`, so the strongest verdict this evidence can
   support is `CONDITIONAL PASS` at best, never `PASS`.
2. H2, H3, H4, H5 and H8 were not executed, and H6 is `SKIPPED — NOT SAFELY
   REPRODUCIBLE`. Five of the eight scenarios carry no evidence.
3. C6 (Host/device recovery) was never exercised, so it is `NOT EXECUTED`
   rather than `MET`.
4. C7 (audible symptoms) was not assessed by a listener.

**What was actually established, and its exact scope:** with a 48 kHz / 512-frame
single format, a steady synthetic tone, no EQ activity and one 30-minute session,
the SoundBridge render callback met its 10666.7 µs deadline on all 169686
observed callbacks, including through 300 s of 4-process CPU load, with zero
driver underruns and zero ring overruns. That is a narrow but real result. It is
not a statement about EQ changes, other buffer sizes, other sample rates, device
removal, or long-term soak.

**Criteria:**

| ID | Statement | Status | Evidence |
|---|---|---|---|
| C1 | Genuine CoreAudio IO callback activity proven | **MET** | 169686 callbacks in 180 windows; `deviceIsRunning` in 180/180; observed/expected rate ratio 1.00–1.00; only `SoundBridgeHost` accepted as a log source |
| C2 | Actual sample rate and buffer frame count observed | **MET** | one bucket, `48000Hz/512f` |
| C3 | Timing compared against the deadline of its own format | **MET** | each window derives frames/rate from its own snapshot |
| C4 | All deadline misses reported | **MET** | `overBudget` summed over all windows = 0 |
| C5 | Driver underrun observability documented | **MET** | per-window deltas from a read-only mmap of the live mapping; 0 for the whole run |
| C6 | Host/device recovery evaluated | **NOT EXECUTED** | 0 recovery/hotplug/degraded events; H8 withheld |
| C7 | Audible symptoms recorded by the operator | **NOT ASSESSED** | no listener; `MET (none reported)` in the JSON is the weak claim only |
| C8 | Original default output restored and verified | **MET** | restored after the run; UID read back as `410C54C2-…` in the writing process and again by `--verify` |
| C9 | Skipped scenarios remain visibly skipped | **MET** | H2–H5/H8 `NOT EXECUTED`, H6 `SKIPPED`, none reported as passing |
| C10 | No required evidence is missing | **UNMET** | C6 and C7 |
| C-extra | p99.9 latency reported | **NOT OBSERVABLE** | one field in `TimingSnapshot` would fix it; not applied |

The software integration verdict is unchanged and is not restated as a hardware
result: `PASS — SOFTWARE INTEGRATION VERIFIED; HARDWARE REALTIME VALIDATION PENDING`.

**Artefacts preserved** (all under the gitignored `build/` tree):

```
build/hwvalidate/runs/a2a4/run1/result.json          machine-readable result, schema v1
build/hwvalidate/runs/a2a4/run1/result.md            harness-rendered Markdown
build/hwvalidate/runs/a2a4/run1/markers.jsonl        5 operator markers
build/hwvalidate/runs/a2a4/run1/h7.log              H7 start/stop, both with UTC stamps
build/hwvalidate/runs/a2a4/run1/h7.pids             the four /usr/bin/yes pids
build/hwvalidate/runs/a2a4/run1/load-at-start.txt   uptime before
build/hwvalidate/runs/a2a4/run1/load-at-end.txt     uptime after
build/hwvalidate/runs/a2a4/run1/playback-start.txt  playback start + restore timestamps
build/hwvalidate/runs/a2a4/run1/drive.out           full driver stdout
build/hwvalidate/runs/a2a4/run1/after-restore.json  inventory after restore
build/hwvalidate/runs/a2a4/a2-before.json           inventory before routing
build/hwvalidate/runs/a2a4/a2-after-route.json      inventory after routing
build/hwvalidate/audio/test-tone-32min.wav          the file that was played
build/hwvalidate/audio/gen_test_tone.py             how it was generated
```

## 12. Harness defects found by running it for real

The F2 harness had been exercised only against a Host that was not playing. The
first minute of A2–A4 showed that this was not enough. Five defects, all fixed in
`tools/hardware-validation/sb-hw-validate.swift` **before** the reported run
started, and none of them in production code:

| # | Defect | Symptom | Fix |
|---|---|---|---|
| 1 | `log stream` block-buffers when stdout is not a tty | 12 s of streaming into a pipe delivered **zero** lines; a file target held one header line until the process was killed. Every `collect` run saw nothing and exited 4 | re-read the trailing window with `log show --last 12s` every 5 s, dedupe on the verbatim line |
| 2 | Optional regex group read with `NSNotFound` | `parseTimingLine` crashed with `NSRangeException: Range {9223372036854775807, 0}` on **every** unsaturated-max line — i.e. always. The harness had never parsed a single timing line | route every capture through a `capture(_:_:_:)` that returns `nil` for non-participating groups |
| 3 | Timestamp regex demanded a UTC offset | `--style compact` prints no offset, so every timestamp silently degraded to `Date()` ("now") and every rate derived from a timestamp difference measured the harness's own polling interval (82.9 / 124.1 Hz instead of 93.75) | accept both shapes; parse the offsetless form in local time; truncate to milliseconds |
| 4 | First window absorbed the Host's entire uptime | window 0 reported 119526 callbacks and 11941 Hz, because the counters are cumulative since the Host started | consume the priming poll as a baseline, not as window content |
| 5 | Callback rate divided by wall-clock window length | with samples every ~5 s, a 10 s window can hold samples 15 s apart, so the rate was wrong by up to ±33% | divide by the span between the two samples' own timestamps |

A sixth change is not a bug fix but a correction to how the harness reports
failure: a run that **cannot read the log** used to exit 4 with the same words as
a run that read the log and saw nothing play. It now exits 5 with
`COULD NOT READ HOST LOG: …`, so an observation failure can never be quoted as a
hardware result.

Consequence worth stating plainly: the "F1/F2 preparation complete" claim
covered the harness's *design*, not its behaviour against a live Host. Four of
the five defects above would have silently produced a `NO CORE AUDIO IO
OBSERVED` verdict on a perfectly healthy run, and one would have crashed.

## 13. Machine state after the run

| Item | State |
|---|---|
| Default output | `PHL 279M1RV` `410C54C2-0000-0000-051F-0103803C2278` (physical), verified |
| `afplay` | stopped, 0 processes |
| `/usr/bin/yes` load processes | stopped, 0 processes |
| Host / App | **still running** — pids 71610 / 71605, as A1 left them |
| Proxy devices | still present (`…-soundbridge` for both monitors) |
| `/tmp` mappings + lock | still present (`/tmp/soundbridge-501-*`, `/tmp/soundbridge-devices.txt`, `/tmp/soundbridge-host-501.lock`) |
| `coreaudiod` | pid 48791, not restarted |
| Driver helper | pid 48806, not restarted |
| Driver install state | unchanged; nothing installed or removed |
| Repository | `main@eb45303`, 24 modified + 25 untracked paths, all pre-existing except `tools/hardware-validation/sb-set-default-output.swift`; no production code touched |

Removing the proxy devices and the `/tmp` mappings requires quitting the App,
which was not part of A2–A4 and was therefore **not** done. Say the word and it
can be torn down.
