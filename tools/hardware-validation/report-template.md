# SoundBridge Hardware Realtime Validation — Report Template

> **TEMPLATE.** Nothing in this file is a measurement. `<angle-bracket>` fields
> are filled in by the operator from `result.json`, from `inventory` output, or
> from direct observation.
>
> The worked example at the end of §4 is labelled
> `ILLUSTRATIVE — NOT REAL HARDWARE DATA`. It exists to show the shape of a
> filled table. **It is not a run, and it is not a pass.**

Machine-readable source of truth: `result.json` written by
`build/hwvalidate/sb-hw-validate collect`, validated against
`docs/release/SoundBridge-Hardware-Realtime-Result-Schema.json`.

Rules that apply to every field below:

1. A value that could not be read is written `not observable`. Never `0`, never
   `—`, never left blank.
2. A scenario that was deliberately not run is `SKIPPED — <reason>`. A scenario
   that was never reached is `NOT EXECUTED`. These are different words on
   purpose.
3. `overBudget` from two windows with different `bucket` values must never be
   added together.
4. Any pasted log line is verbatim. No trimming, no paraphrase, no reflowing.

---

## 1. Run identity

| Field | Value |
|---|---|
| Run ID (`result.json → runID`) | `<uuid>` |
| Start (local, ISO 8601, with offset) | `<2026-11-23T15:30:00.000+08:00>` |
| End (local, ISO 8601, with offset) | `<2026-11-23T16:02:11.000+08:00>` |
| Timezone (`result.json → timezone`) | `<Asia/Shanghai>` |
| Operator | `<name>` |
| Approvals on record (`A1`–`A6`, `A10`) | `<A1, A2, A3, A4>` |
| Harness version (git rev of `sb-hw-validate.swift`) | `<branch @ commit>` |

## 2. Machine

| Field | Value |
|---|---|
| macOS version / build | `<27.2.1 / 26B131>` |
| Model | `<Mac16,10>` |
| Architecture | `<arm64>` |
| Logical cores | `<10>` |
| Memory | `<16 GB>` |
| Free disk at start | `<125 GiB>` |

## 3. Software under test

| Field | Value |
|---|---|
| Driver path | `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver` |
| Driver `CFBundleIdentifier` | `<com.soundbridge.driver>` |
| Driver version | `<1.2.0>` |
| Driver protocol / header size | `<0x00020200 / 320>` |
| Driver loaded (helper process) | `<yes — pid …>` |
| Host path | `<…/Contents/MacOS/SoundBridgeHost>` |
| Host version | `<1.2.0>` |
| App version | `<1.2.0>` |
| Host launch mechanism | `spawned by SoundBridgeApp` |

## 4. Device and routing

| Field | Value |
|---|---|
| Original default output — name | `<PHL 279M1RV>` |
| **Original default output — UID** | `<410C54C2-0000-0000-051F-0103803C2278>` |
| Original default input (reference only) | `<BlackHole 16ch / BlackHole16ch_UID>` |
| Device under test — name | `<SoundBridge …>` |
| **Device under test — UID** | `<…>` |
| Fallback physical device confirmed | `<BuiltInSpeakerDevice>` |
| Routed to SoundBridge at start (timestamp) | `<…>` |
| Routed back to original at end (timestamp) | `<…>` |
| **Restore verified by UID after App quit** | `<yes — uid equals the original>` |
| Normal output playback verified by ear | `<yes / no>` |

### 4.1 Actual format (not the requested one)

| Field | Value | Source |
|---|---|---|
| Sample rate | `<48000>` | `kAudioDevicePropertyNominalSampleRate` **and** stream physical format (both must agree; if not, both are listed) |
| IO buffer frames | `<512>` | `kAudioDevicePropertyBufferFrameSize` |
| Buffer range | `<15–4096>` | `kAudioDevicePropertyBufferFrameSizeRange` (context only) |
| Deadline | `<10666.7 µs>` | `frames / rate × 1e6` |
| Channels | `<2>` | stream format |

### 4.2 Format changes observed during the run

Every entry in `result.json → formatChanges`, verbatim, including listener events
that did not change the bucket.

| Timestamp | Event | From | To | From deadline | To deadline |
|---|---|---|---|---:|---:|
| `<…>` | `<format-changed \| nominal-sample-rate-changed \| buffer-frame-size-changed \| device-disappeared>` | `<48000Hz/512f>` | `<48000Hz/256f>` | `<10666.7>` | `<5333.3>` |

If there were none, write `none observed` and say how long the observation was.

## 5. Scenario results

| ID | Scenario | Status | Evidence | Notes |
|---|---|---|---|---|
| H1 | Stable playback baseline | `PASS` \| `FAIL` \| `SKIPPED — …` \| `NOT EXECUTED` | `<windows 0–41, 0 overBudget>` | |
| H2 | One-band EQ updates | | | |
| H3 | Ten-band EQ updates | | | |
| H4 | Preamp changes | | | |
| H5 | Hostile snapshot writer | | refused reads: `<n>` or `not observable` | |
| H6 | Publish contention / refusal | `SKIPPED — NOT SAFELY REPRODUCIBLE` | no supported mechanism to hold the token from outside the Host; a test hook is forbidden | must never be reported as passed |
| H7 | Reversible CPU load | `PASS` \| `FAIL` \| `SKIPPED — …` | `<n>` load processes, start/stop timestamps | |
| H8 | Device removal / re-appearance | `NOT EXECUTED` (needs approval A6) | | |

## 6. Per-window timing

One row per `result.json → windows[]` entry. `p50/p95/p99/max` are **cumulative
since the Host started**; `callbacks`, `overBudget` and `excess` are true
per-window deltas. Do not silently drop the `Q` column.

| # | Start | End | Bucket | Rate | Frames | Deadline µs | Callbacks | obs/exp rate | overBudget | Excess ms | p50 µs | p95 µs | p99 µs | **p99.9 µs** | Max µs | max≥floor | underruns | Q |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|:--:|---:|:--:|
| 0 | `<…>` | `<…>` | `<48000Hz/512f>` | `<48000>` | `<512>` | `<10666.7>` | `<937>` | `<1.00>` | `<0>` | `<0.0>` | `<…>` | `<…>` | `<…>` | `not observable` | `<…>` | `<no>` | `<0>` | `C` |

`Q = C` means the quantiles are cumulative. `max≥floor` means the reported max is
the 16.384 ms overflow floor, i.e. the real maximum is at least that value — a
saturated max must not be read as a precise number.

**Totals**

| Field | Value |
|---|---|
| Windows recorded | `<n>` |
| Total callbacks | `<sum of callbacks>` |
| Total `overBudget` | `<sum within one bucket; list each bucket separately if there is more than one>` |
| Total excess | `<ms>` |
| Driver underruns | `<n>` \| `not observable` |
| Ring overruns | `<n>` \| `not observable` |
| Underrun source | `<sb-shm-probe (read-only mmap of the live mapping)>` |
| Log sources seen | `<SoundBridgeHost=n>` (any other process is evidence the filter worked, not data) |

## 7. Events and recovery

| Timestamp | Event | Detail (verbatim) |
|---|---|---|
| `<…>` | `<host-recovery \| device-hotplug \| host-degraded \| host-shutdown \| driver-underrun>` | `<log line>` |

If none occurred: `no recovery, hotplug or degraded event was logged during the
run; this is zero observed, not proof that recovery works.`

## 8. Audible symptoms (operator)

| Timestamp | Scenario | What was heard | Duration |
|---|---|---|---|
| `<…>` | `<H3>` | `<click>` | `<~50 ms>` |

If nothing was heard, write that explicitly per scenario
(`"H1: nothing heard"`) — and remember that hearing nothing is not the same
claim as "the callback met its deadline".

## 9. Load and thermal

| Field | Value |
|---|---|
| CPU load scenario | `<none>` \| `<n × /usr/bin/yes, started …/stopped …>` \| `<external>` |
| Host CPU % (from `Callback timing: … cpu=`) | `<…>` |
| System load (`uptime`) at start / mid / end | `<…>` |
| Thermal pressure | `<nominal>` \| `not observable` |
| Fan behaviour | `<…>` |

## 10. Telemetry limitations — copy verbatim into the report

| Limitation | Statement |
|---|---|
| p99.9 | `not observable` — `AudioRenderer.TimingSnapshot` exposes p50/p95/p99/max only; `rf_rt_hist_quantile_bucket()` could supply it with one added field (approval A10, not applied) |
| Per-window quantiles | unavailable — the histogram is cumulative since `AudioRenderer` construction and exposes no bucket counts |
| Driver underruns via Host log | `not observable` — the Host's `Buffer underrun: +N (total: T)` line interpolates Ints without `privacy: .public` and arrives redacted; counters are read out-of-band from the live mapping instead |
| H6 contention | `SKIPPED — NOT SAFELY REPRODUCIBLE` |
| H8 removal | `NOT EXECUTED` — requires approval A6 |
| Audibility | a counter cannot prove nothing was heard, and a heard click cannot prove a deadline miss |

## 11. Verdict

One of, and only one of:

- `PASS — HARDWARE REALTIME VALIDATION VERIFIED`
- `CONDITIONAL PASS — HARDWARE VALIDATION WITH DOCUMENTED LIMITATIONS`
- `FAIL — HARDWARE REALTIME VALIDATION FAILED`
- `INCOMPLETE — REQUIRED HARDWARE EVIDENCE MISSING`

**Verdict:** `<…>`

**Reasons (from `result.json → verdictReasons`, verbatim):**

1. `<…>`

**Criteria (`result.json → criteria`):**

| ID | Statement | Status | Evidence |
|---|---|---|---|
| C1 | Genuine CoreAudio IO callback activity proven | `<MET/UNMET>` | `<…>` |
| C2 | Actual sample rate and buffer frame count observed | | |
| C3 | Timing compared against the deadline of its own format | | |
| C4 | All deadline misses reported | | |
| C5 | Driver underrun observability documented | | |
| C6 | Host/device recovery evaluated | | |
| C7 | Audible symptoms recorded by the operator | | |
| C8 | Original default output restored and verified | | |
| C9 | Skipped scenarios remain visibly skipped | | |
| C10 | No required evidence is missing | | |
| C-extra | p99.9 latency reported | `NOT OBSERVABLE` | | 

**The software integration verdict is unchanged and is not restated as a hardware
result:** `PASS — SOFTWARE INTEGRATION VERIFIED; HARDWARE REALTIME VALIDATION PENDING`.

**Artefacts preserved:** `<result.json, result.md, markers.jsonl, saved log excerpt, before/after inventory JSON>`

---

## Appendix A — ILLUSTRATIVE — NOT REAL HARDWARE DATA

> **ILLUSTRATIVE — NOT REAL HARDWARE DATA.** The numbers below were invented to
> show the table shape. They are not a run, not a measurement, and deliberately
> do **not** form a passing result. Do not copy them into a report.

| # | Bucket | Deadline µs | Callbacks | overBudget | p99 µs | p99.9 µs |
|---|---|---:|---:|---:|---:|---|
| 0 | `48000Hz/512f` | 10666.7 | 937 | 0 | 812.0 | `not observable` |
| 1 | `48000Hz/512f` | 10666.7 | 938 | 0 | 815.0 | `not observable` |
| 2 | `48000Hz/256f` | 5333.3 | 1876 | 3 | 901.0 | `not observable` |

The third row is why windows are bucketed: 3 misses against a 5333.3 µs deadline
is a different claim from 3 misses against 10666.7 µs, and adding them would
produce a number that means nothing.

**ILLUSTRATIVE verdict, shown only to demonstrate that a run with missing
evidence must not pass:** `INCOMPLETE — REQUIRED HARDWARE EVIDENCE MISSING`
(p99.9 unobservable, H6 skipped, H8 not executed).
