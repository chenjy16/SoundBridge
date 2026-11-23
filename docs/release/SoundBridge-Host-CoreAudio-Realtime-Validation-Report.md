# SoundBridge — Host + CoreAudio End-to-End Realtime Integration Validation

Status: **in-process validation complete; hardware realtime validation not executed**
Baseline: branch `main`, commit `eb45303` (working tree carries the accepted DSP remediation, uncommitted)
Date of run: 2026-11-23
Host / OS: macOS 27.2.1, arm64 (Apple silicon), 10 logical cores

---

## 1. Scope and what this document does and does not claim

This report covers the path from CoreAudio's render callback through
`AudioRenderer.render(bufferList:frameCount:)`, the shared-memory mapping, the EQ
change detector, `soundbridge_dsp_try_update_eq()`, the DSP block, and back out to
the output buffer. It answers three questions:

1. What does that path actually do, operation by operation, and which operations
   are realtime-safe? (Phase A, in `Host-CoreAudio-Realtime-Execution-Path.md`)
2. What does it cost, and where does the cost sit? (Phase B)
3. Does it survive concurrency, churn, and sustained load? (Phase C, Phase D)

**What is verified.** The code under measurement is the shipping code. The render
function, the shared-memory mapping, the seqlock, the mailbox, the biquad cascade
and the Host's diagnostics are all the real implementations, compiled in release,
driven in-process.

**What is not verified.** No CoreAudio IO thread was involved. There is no device,
no HAL, no real-time priority, no thermal load from a live audio stack, and no
system audio path to interrupt. Consequently:

- No statement here proves that a real IO thread meets its deadline.
- Zero DSP underrun counts in this report are a property of the fixture's ring,
  not evidence that audio was uninterrupted.
- Device removal, sample-rate renegotiation and Host restart were exercised at the
  Host API layer, not against a real device.

Section 8 states the verdict that follows from that split, and no more.

---

## 2. Baseline and working-tree state

The tree was recorded before any change. `main` at `eb45303`, 36 entries of
`git status --porcelain` (24 modified, 12 untracked), carrying the accepted DSP
remediation. Nothing was reset, stashed, checked out, reverted or cleaned at any
point in this work. Nothing was committed, pushed or tagged.

Files added by this validation:

| File | Purpose |
|---|---|
| `docs/release/Host-CoreAudio-Realtime-Execution-Path.md` | Phase A: the call graph, classified |
| `packages/host/Tests/SoundBridgeHostTests/HostRealtimeMeasurementTests.swift` | Phase B, gated by `SB_RT_MEASURE=1` |
| `packages/host/Tests/SoundBridgeHostTests/HostRealtimeIntegrationTests.swift` | Phase C gap coverage, always runs |
| `packages/host/Tests/SoundBridgeHostTests/HostRealtimeSoakTests.swift` | Phase D, gated by `SB_RT_SOAK=1` |
| `docs/release/SoundBridge-Host-CoreAudio-Realtime-Validation-Report.md` | this document |
| `docs/release/SoundBridge-Host-CoreAudio-Integration-Findings.md` | findings with status |

No production source was changed. Phase A found nothing that required a
correction, and the measurement (§5) did not change that: the one candidate
(`F-HC-01`) turned out to be three to four orders of magnitude below the budget.

The only edit to an existing document was the three corrections the task
requested in `SoundBridge-DSP-Engine-Remediation-Report.md` (§2.1, §2.2, §2.3 of
the task): the consumer statement now says one acquire load and at most one
compare-exchange with no retry loop, the producer statement no longer claims
wait-freedom or a wall-clock bound for every producer path, and §H now says
verbatim that no existing public signature or symbol changed and one new entry
point was added.

---

## 3. Phase A — the path, in one paragraph

`render()` stamps the clock, records the first pass once, guards on capacity,
enters the mapping through `rf_rt_gate_enter` (a sequence-counted lease), reads
the ring, loads the 48-byte EQ snapshot through a seqlock with a hard ceiling of
four attempts, compares it with the last one it applied, calls
`soundbridge_dsp_try_update_eq` and `soundbridge_dsp_set_bypass` only when the
snapshot differs, calls `soundbridge_dsp_process_interleaved`, applies the volume
and writes the result into the output buffers. It never allocates, never locks, and
never logs; it never blocks waiting on another thread, and the one loop it can
enter (`mailbox.publish`, inside `try_update_eq`) is lock-free rather than
wait-free. The full operation-by-operation table, including the
list of things that are *not* in the path, is in
`Host-CoreAudio-Realtime-Execution-Path.md`.

The one question the task singled out:

> Determine whether `refresh_config_coeffs()` currently executes on the CoreAudio
> render thread when `try_update_eq()` is called from `AudioRenderer.render()`.

`refresh_config_coeffs()` does not. It is called from exactly two places,
`soundbridge_dsp_set_sample_rate` and `soundbridge_dsp_apply_preset`, both
control-thread entry points that take the blocking publisher lock. **But the
equivalent arithmetic does run on the render thread**: `try_update_eq` recomputes
the coefficients of every updated band inline, with the same `bandBiquadCoeffs`
that `refresh_config_coeffs` uses.

§5 bounds that arithmetic without isolating it. The complete accepted ten-band
call measures 91 ns and the complete accepted one-band call measures 21 ns; the
difference of those two end-to-end means implies an incremental cost of about
7.8 ns per additional band. That figure is an **estimate derived from two
measurements**, not an independently measured coefficient-calculation duration —
see §5.3.

---

## 4. Phase B — method, configuration, instrumentation

### 4.1 Configuration

| Item | Value |
|---|---|
| Sample rate | 48 000 Hz |
| Frames per callback | 512 (sweep: 64 / 128 / 512 / 1024) |
| Channels | 2 |
| Callback deadline | 10 666.7 µs at 512 frames (`frames / sample_rate`) |
| Architecture | arm64 |
| Build | release: `swift test -c release`, DSP static library from CMake Release (`-O3 -fno-math-errno`, no `-ffast-math`) |
| Callbacks per scenario | 20 000 (frame sweep: 2 000 – 20 000 by block size) |
| Component samples | 20 000 calls per component; 200 000 for the seqlock; 60 000 for the refusal path |

`callback_deadline = frames_per_callback / sample_rate`. It is reported so a
reader can form a ratio; it is not a safety threshold and no threshold is
asserted anywhere in this work.

### 4.2 Instrumentation and its overhead

Two tiers, never mixed:

- **Whole callback.** One `mach_absolute_time()` pair around
  `AudioRenderer.render`. The callback already stamps twice for its own
  latency histogram, so the fixture adds a second pair: on the order of 50 ns
  against a 7 100 ns callback, i.e. below 1 %. The seam is visible: the same run
  reports the *production* histogram (one stamp pair, 2 µs buckets, upper edge),
  and the two agree within one bucket (§5.1).
- **Components.** One stamp pair around a 20 000-iteration loop, divided by the
  iteration count. Per-call stamps were rejected: `mach_absolute_time` advances
  in 41.67 ns ticks here (`numer=125`, `denom=3`), so a per-call quantile of a
  100 ns call is quantised to two or three ticks and means nothing.

### 4.3 Two measurement defects that were found and fixed

Recorded because both produced plausible-looking numbers.

1. **The renderer read a mapping the fixture was not feeding.** The render gate
   publishes exactly one mapping, chosen as
   `preferredRenderUID ?? deviceMemory.values.first`
   (`SharedMemoryManager.refreshRenderMemory`). A fixture that creates several
   mappings in one manager therefore races the gate's choice, and a renderer can
   read an empty mapping: `rf_ring_read` returns zero frames, the DSP block is
   skipped, and the callback costs 0.5 µs instead of 7 µs. Every scenario now
   owns its own manager *and* names its mapping as the preferred render UID.
2. **Sub-microsecond quantiles.** Replaced with loop means (§4.2).

The first defect is the reason an earlier run showed five scenarios at
0.2–0.5 µs. Those numbers were discarded, not reported.

### 4.4 How to reproduce

```
cd packages/host
SB_RT_MEASURE=1 swift test -c release --filter HostRealtimeMeasurementTests
SB_RT_SOAK=1    swift test -c release --filter HostRealtimeSoakTests
```

Both suites skip themselves without the variable, so `make test-host` stays fast.
`SB_RT_SOAK_SCALE=0.1` turns the soak into a smoke test.

---

## 5. Phase B — results

All values are microseconds unless stated.

**Deadline scope.** Every row is compared against *its own* deadline,
`frames_per_callback / sample_rate`, and never against a shared one. At 48 kHz:
512 frames → 10 666.7 µs, 64 frames → 1 333.3 µs, 128 frames → 2 666.7 µs,
1 024 frames → 21 333.3 µs. The 10 666.7 µs figure therefore applies **only** to
the 512-frame scenarios; the `over` column in §5.2 is computed against each row's
own deadline, and the two tables below are not comparable row-to-row through a
single number.

### 5.1 B1.1 — whole callback, eight scenarios

| scenario | n | min | p50 | p95 | p99 | p99.9 | max | over |
|---|---|---|---|---|---|---|---|---|
| no parameter change | 20 000 | 6.6 | 7.1 | 17.9 | 27.8 | 83.1 | 234.5 | 0 |
| one band changes every callback | 20 000 | 8.0 | 8.3 | 22.8 | 37.3 | 102.6 | 208.0 | 0 |
| ten bands change every callback | 20 000 | 8.0 | 8.5 | 23.6 | 39.4 | 96.9 | 300.7 | 0 |
| preamp changes every callback | 20 000 | 7.1 | 8.0 | 20.5 | 33.2 | 83.7 | 378.9 | 0 |
| snapshot rewritten by another thread | 20 000 | 6.7 | 8.5 | 22.6 | 36.8 | 137.2 | 490.8 | 0 |
| steady state, 20 CPU hogs on 10 cores | 20 000 | 6.8 | 18.0 | 46.1 | 211.8 | 753.4 | 2 082.2 | 0 |

Production histogram from the same steady-state run, for cross-check:
`n=20 050  p50=8.0  p95=18.0  p99=28.0  max=236.0  overBudget=0  saturated=false`.
Diagnostics from the same run: `memoryUnavailable=0 capacityExceeded=0
channelMismatch=0 underrunFrames=0 dspFrames=10 265 600 cpu=0.06 %`.

Scenarios 5 and 6 of the task list — a rejected publish and a retry after
rejection — cannot be forced at the renderer layer, because the publisher token
lives behind the engine handle and the DSP test seam
(`test_support::hold_publisher_token`) is a C++ symbol the Host cannot reach. They
are measured on the real engine instead (§5.3), and the whole-callback bound is
derived rather than asserted: the refusal path is strictly shorter than the
acceptance path, so a refused callback cannot cost more than the ten-band row
that it is a prefix of.

### 5.1.1 Run-to-run variance

The suite was run twice on the same machine. The medians reproduce; the tails do
not, and that is worth stating rather than averaging away:

| scenario | run 1 p50 / p99 / p99.9 / max | run 2 p50 / p99 / p99.9 / max |
|---|---|---|
| no parameter change | 7.1 / 27.8 / 83.1 / 234.5 | 7.0 / 24.2 / 47.9 / 98.1 |
| ten bands change | 8.5 / 39.4 / 96.9 / 300.7 | 9.0 / 36.2 / 442.6 / 3 148.6 |
| 20 CPU hogs | 18.0 / 211.8 / 753.4 / 2 082.2 | 17.9 / 131.4 / 1 767.4 / **9 765.6** |

The second run's worst callback under full oversubscription reached 91.5 % of the
deadline. It did not miss; it came close. It is a descheduled user-space thread,
and no amount of care inside `render()` prevents it. Two consequences:

- the medians and the p95 here are properties of the code; the p99.9 and max are
  properties of this machine's scheduler on that run;
- a real IO thread should be *better* than this, not worse, because it gets
  time-constraint priority. That is a prediction, not a measurement, and it is
  why §10 does not call this a hardware pass.

For the same reason, no single row below should be read to more than two
significant figures.

Every row above was measured at 512 frames, so the shared 10 666.7 µs deadline is
correct for all of them; the `over` column there does count against it.

### 5.2 B1.2 — frame-size sweep

The `deadline` column is per row and is not a shared constant: each scenario is
divided by its own `frames_per_callback / sample_rate`. A 64-frame callback has
one eighth of the time budget and roughly one eighth of the work, so the four
block sizes must not be compared against the 512-frame figure.

| scenario | n | p50 | p95 | p99 | p99.9 | max | deadline | over |
|---|---|---|---|---|---|---|---|---|
| steady, 64 frames | 20 000 | 1.0 | 2.4 | 3.0 | 16.9 | 86.6 | 1 333.3 | 0 |
| ten bands, 64 frames | 20 000 | 1.4 | 3.0 | 6.7 | 18.6 | 49.4 | 1 333.3 | 0 |
| steady, 128 frames | 15 625 | 1.9 | 4.5 | 7.6 | 24.2 | 101.5 | 2 666.7 | 0 |
| ten bands, 128 frames | 15 625 | 2.7 | 5.6 | 10.2 | 29.9 | 76.7 | 2 666.7 | 0 |
| steady, 512 frames | 3 906 | 7.1 | 14.4 | 25.5 | 59.4 | 72.5 | 10 666.7 | 0 |
| ten bands, 512 frames | 3 906 | 8.3 | 16.3 | 32.2 | 59.2 | 75.5 | 10 666.7 | 0 |
| steady, 1024 frames | 2 000 | 15.3 | 31.8 | 47.4 | 65.3 | 78.8 | 21 333.3 | 0 |
| ten bands, 1024 frames | 2 000 | 15.0 | 32.3 | 50.0 | 90.5 | 90.7 | 21 333.3 | 0 |

Cost scales with frames, i.e. with the work, and the fraction of the deadline it
consumes stays roughly flat (p99 of deadline: 0.2 % at 64 frames, 0.3 % at 1024).
Smaller blocks are not "cheaper" in the only sense that matters — they are a
larger share of a smaller deadline.

### 5.3 B2.1 — component costs on the real C entry points

Means over a long loop (`mach_absolute_time` tick 41.67 ns; per-call quantiles are
not meaningful at this scale, which is why this table has no p95/p99/p99.9 column
and §5.1 does).

| component | bands | n | mean | notes |
|---|---|---|---|---|
| `process_interleaved` | 10 | 20 000 | 7 203 ns | 512 frames, both channels |
| `process_interleaved` | 1 | 20 000 | 3 502 ns | same |
| `try_update_eq` (accepted) | 10 | 20 000 | 91 ns | recompute + one publish |
| `try_update_eq` (accepted) | 1 | 20 000 | 21 ns | same |
| `try_update_eq` + `process_interleaved` | 10 | 10 000 | 10 209 ns | one changed block, ramp active for 480 of 512 frames |
| of which the ramp branch | 10 | — | 2 914 ns | remainder after subtracting the two rows above |
| `try_update_eq` + `process_interleaved` | 1 | 10 000 | 4 601 ns | same |
| of which the ramp branch | 1 | — | 1 078 ns | same |
| `rf_load_eq_snapshot_safe`, no writer | — | 200 000 | 0.5–0.9 ns | 48-byte copy + two acquire loads; 0 give-ups in every run |
| `rf_load_eq_snapshot_safe`, writer active | — | 200 000 | 1.4–1.7 ns | gave up after 4 attempts 117–1 177 times (0.08 %–0.59 % across runs) |

The band count is self-reported: `soundbridge_dsp_get_preset` returned
`num_bands = 10` for the ten-band engine and `1` for the single-band engine, so
the two rows really are doing different amounts of arithmetic.

**What the two `try_update_eq` rows actually contain.** Each is the mean of a
*complete accepted call*, end to end: coefficient calculation for every band in
the preset, the `shadow` update and `set_smooth`, and one successful
`mailbox.publish`. The 91 ns for ten bands and the 21 ns for one band are both of
that composite shape; neither is a coefficient-calculation measurement on its own.

**Where the cost actually is.** `try_update_eq` with ten bands costs 91 ns
end to end. Subtracting the complete one-band call, `(91 − 21) / 9 ≈ 7.8 ns`, is an
**estimated incremental cost of one additional band**, and it is an estimate in
two respects: it is a difference of two composite means, and dividing by nine
assumes the per-band term is linear and that the fixed part (token exchange,
publish, function overhead) is identical in both calls. It is not a measured
coefficient-calculation duration.

**What was not measured in isolation.**

- **Pure coefficient calculation** was not independently measured. There is no
  seam that runs `bandBiquadCoeffs` without the surrounding `try_update_eq`
  bookkeeping, and this work does not add one.
- **An isolated successful `mailbox.publish`** was not independently measured
  either. There is no seam that publishes without recomputing, and the refused
  row in §5.4 is a *failed* exchange (23 ns) rather than a successful publish, so
  it is not a substitute.

Both sit inside the 91 ns. The 91 ns is nonetheless a real end-to-end measurement
of the operation the render thread performs, which is what the realtime question
asks for; only the *attribution* between its parts is inferred.

Relative to the budget, the 91 ns is 0.0009 % of the **512-frame** deadline
(10 666.7 µs), which is the only deadline it may be compared against.

The interesting part is that it is *not* what the whole-callback delta is made
of. Changing the snapshot does two things: it costs those 91 ns, and it makes
`apply_config` start a 10 ms coefficient ramp (`kCoeffRampSeconds = 0.01f`, 480
samples at 48 kHz), which puts every sample of the following block on the
interpolation branch in `processSampleMono`. Two independent fixtures attribute
the changed-block cost to that ramp:

- whole callback, p50 delta between "no change" and "ten bands change":
  **1.4 µs** (§5.1);
- isolated `try_update_eq` + `process_interleaved` minus its two parts:
  **2.9 µs** for ten bands, **1.1 µs** for one (§5.3).

The two fixtures differ by a factor of about two and the difference was not
chased down; both are three orders of magnitude below the deadline, and the
ordering (the 91 ns publish ≪ ramp branch ≪ deadline) is the same either way.
What the report will not do is present 91 ns as the cost of an EQ change: the
honest figures are "91 ns for the accepted publish, plus a block spent in the
ramp".

### 5.4 B2.2 — refusal path under real token contention

A second thread spins on `soundbridge_dsp_apply_preset` while the measuring thread
calls `try_update_eq` 60 000 times, so the token is genuinely held by a peer.

| bucket | n | mean | notes |
|---|---|---|---|
| accepted | 44 686 | 112 ns | token exchange + recompute + one successful publish |
| refused | 15 314 | 23 ns | token exchange observed the token held; return |
| refusal rate | 25.52 % | — | 15 314 of 60 000 single attempts |
| second immediate attempt succeeded | 425 | — | of the 15 314 refused |

**Which atomic each step actually uses**, because "CAS" is used loosely and the
distinction matters for any claim about bounds:

| site | primitive | attempts | bound |
|---|---|---|---|
| `PublisherToken::tryLock` | `busy_.exchange(true, acquire)` — an **atomic exchange**, not a compare-exchange | 1, no loop | bounded in attempts; no wall-clock bound claimed |
| `ConfigMailbox::consume` / `try_consume` | one `compare_exchange_strong(expected, desired, acq_rel, acquire)` | 1, no loop | bounded in attempts; a failed exchange leaves the publication pending |
| `ConfigMailbox::publish` | `compare_exchange_weak` in a `for(;;)` loop, `acq_rel` with an `acquire` failure order | unbounded loop | **lock-free, not wait-free**; a weak CAS may also fail spuriously, which is one reason the loop exists |
| `PublisherToken::lock` | `busy_.exchange(true, acquire)` in a loop with `yield` | unbounded loop | control threads only; bounded only by the holder's scheduling |

A failed `exchange` and a failed `compare_exchange_*` are different events: the
former tells the caller the token was already held, the latter tells it the state
word moved underneath it. The render path only ever uses the single-attempt forms.
No claim of wait-freedom is made anywhere in this report: lock-freedom guarantees
that *some* thread progresses, not that a *given* call finishes, and nothing here
proves a wall-clock bound for `publish`.

Two things follow. A refusal is cheap — 23 ns, a fifth of an acceptance — so a
callback that loses the race is not a slow callback. And retrying immediately
almost never works while the peer is spinning: a control thread that has the
token tends to still have it 20 ns later. That is the mechanism behind the design
rule in the DSP report: the render path must not retry, and it does not.

---

## 6. Phase C — concurrency and lifecycle matrix

Ten rows. Eight were already covered by existing tests; two were not, and tests
were added for those. No existing lifecycle guarantee was weakened, and no test
expectation was edited to make anything pass.

| # | Scenario | Coverage | File |
|---|---|---|---|
| 1 | EQ update during render | existing | `RTObservabilityTests.testEQUpdatesAndRingWritesDoNotRaceTheCallback` |
| 2 | Rejected publish | existing | `test_engine.cpp: engine_try_update_eq_is_refused_while_a_peer_holds_the_token`; `test_main.cpp: config_mailbox_failed_attempt_leaves_the_update_pending` |
| 3 | Preset switch during render | existing | `test_engine.cpp: engine_concurrent_preset_switching_settles_on_the_last_preset` |
| 4 | Reset followed by preset | existing | `test_engine.cpp: engine_reset_survives_a_following_preset` and the two reset tests beside it |
| 5 | Sample-rate change | **new** + existing engine coverage | `HostRealtimeIntegrationTests.testSampleRateChangeIsRefusedWhileTheRenderPathIsInsideTheMapping`; `test_engine.cpp: engine_sample_rate_change_preserves_preamp`; `RTObservabilityTests.testGateDefersPublicationWhileALeaseIsHeld` |
| 6 | Device removal | existing | `CoreAudioRestartRecoveryTests.testProxyVanishingIsSuspectedOnTheFirstSampleAndConfirmedOnTheSecond` |
| 7 | Device reappearance | existing | `CoreAudioRestartRecoveryTests.testHotplugReusesMappingDuringRapidReappearance` |
| 8 | Shutdown during playback | existing | `GracefulShutdownTests.testAnIncompleteSequenceNeverClaimsToBeComplete`; `AudioRendererRTSafetyTests.testCleanupStopsTheRenderPathBeforeReleasingAnything` |
| 9 | Host restart, single instance | existing | `HostInstanceLockTests.testSecondProcessIsRefusedWhileTheFirstHolds` (+ the SIGKILL case) |
| 10 | Repeated start/stop | existing + **new** | `DegradedLifecycleTests.testHeartbeatRestartDoesNotLeaveAStrayTimer`; `SharedMemoryRecoveryTests.testSequentialRebuildOfSameUIDDoesNotTrap`; `HostRealtimeIntegrationTests.testRepeatedRenderPathCreationAndTeardownKeepsTheMappingUsable` |

### 6.1 The two rows that had nothing

`AudioRenderer.updateSampleRate` had **no test naming it anywhere in the
repository** — a grep over `Tests/` and `apps/` returned nothing. The gate could
have been deleted without a red suite. It is now covered end to end:

- a rebuild is refused while a callback holds the mapping
  (`enterRenderMemory()` outliving the call is exactly the state a callback is
  in, so `waitForRenderPathIdle` cannot see it go to zero), and a refused rebuild
  changes nothing — the applied rate is unchanged;
- once the path is idle the rebuild succeeds;
- the new rate is **published, not applied**: the engine still reports the old
  rate until the next block boundary, and adopts 96 000 Hz on the next callback.

The second gap — a refused publish retried on the next block *at the renderer
layer* — is unreachable without exposing the engine handle, which the task
forbids ("do not redesign the mailbox to make the test possible"). It is covered
one layer down instead: the mailbox test asserts that a failed attempt leaves the
publication pending, and the engine test asserts that a peer holding the token
produces a refusal rather than a stall. §5.4 adds the measured cost of that
refusal.

The render-path churn test creates and destroys 400 render paths over one live
mapping in Phase D (§7.3), and 50 in the unfiltered suite, checking on every
iteration that the mapping was available and that the DSP saw every frame.

---

## 7. Phase D — stress and soak

Configuration as §4.1. `200 000` callbacks at 512 frames and 48 kHz is
`200 000 × 512 / 48 000 ≈ 2 133 s`, i.e. **approximately 35.6 minutes of simulated
audio-frame coverage** — the amount of audio those callbacks would have carried if
a real device had produced them back to back. The suite takes **roughly five
seconds of wall-clock time**, because it is in-process replay with no IO thread
pacing it.

Those two numbers describe different things and must not be conflated: this is
**not** a 35.6-minute continuous playback session, no audio left the process, and
nothing was listened to. It is 35.6 minutes of *frame coverage* executed in about
five seconds of serial CPU time on one thread. All eight scenarios passed with
zero refusals and zero ring underruns.

### 7.1 D1 — steady soak with periodic parameter changes

200 000 callbacks, EQ change every 64 callbacks (3 125 changes).

| metric | value |
|---|---|
| p50 / p95 / p99 / max | 7.8 / 8.7 / 10.8 / 2 991.4 µs |
| callbacks over deadline | 0 of 200 000 |
| production histogram p99 / max | 12.0 / 2 992.0 µs, overBudget = 0 |
| ring underrun frames | 0 |
| DSP frames processed | 102 416 384 = (200 000 + 32) × 512 |
| engine CPU load (EMA) | 0.063 % |
| refusals (memory / capacity / channels) | 0 / 0 / 0 |
| RSS, test process, 11 checkpoints | 29.2 MB at every checkpoint, delta +0.0 MB |

The single 2.99 ms callback is worth naming: it is a descheduled in-process
thread, not work. It is 28 % of *its own* 512-frame deadline (2 991.4 of
10 666.7 µs), and it is exactly the kind of event a real IO thread has priority
and time-constraint scheduling to avoid, and that this harness cannot model.

### 7.2 D2 – D8

| scenario | callbacks / cycles | p50 | p99 | max | over deadline | result |
|---|---|---|---|---|---|---|
| D2 parameter storm: snapshot rewritten every callback, preamp moves, bypass toggles | 100 000 | 8.5 | 11.1 | 123.1 | 0 | dspFrames = (100 000+32)×512 |
| D3 render path churn over one mapping | 400 cycles | — | — | — | — | 0 refusals, 0 short blocks |
| D4 sample-rate churn across 44.1 / 48 / 96 / 192 kHz | 200 changes | — | — | — | — | 0 refused, 0 not adopted |
| D5 device removal / reappearance, same UID | 150 cycles | — | — | — | — | 150 clean refusals while gone, 0 recreate failures, 150 served after return |
| D6 hostile writer spinning on the snapshot | 100 000 | 8.3 | 13.3 | 118.7 | 0 | 0 refusals, frames exact |
| D7 every core oversubscribed (20 hogs on 10 cores) | 100 000 | 8.3 | 59.7 | 811.9 | 0 | p99 = 0.56 % of deadline |
| D8 block size changes every callback (32 … 2048) | 60 000 | 3.8 | 37.4 | 2 491.9 | not computed | 0 refusals, frames exact |

How the `over deadline` column is counted, because it is not one constant:

- D2, D6 and D7 run every callback at 512 frames, so their `0` is counted against
  the 10 666.7 µs deadline that belongs to those rows.
- D8 cycles 32, 64, 128, 256, 512, 1 024 and 2 048 frames, so its deadline changes
  on *every* callback — 666.7 µs at 32 frames, 42 666.7 µs at 2 048. The fixture
  records raw per-callback costs and does not bucket them by the deadline in force,
  and it does not assert any per-block threshold. The entry is therefore
  `not computed`, not `0`. Its `max` of 2 491.9 µs is a mixture of block sizes and
  cannot be placed against any single deadline; a max that exceeds a 32-frame
  deadline is expected and says nothing, because the same number would be 5.8 % of
  a 2 048-frame deadline.
- D3, D4 and D5 assert lifecycle outcomes only and record no per-callback cost, so
  all of their cost columns are `—`.

Two of these deserve a sentence:

- **D5** is the device-removal rehearsal at the Host layer. The callback that ran
  with no mapping refused (150 out of 150), the mapping was recreated under the
  same UID 150 times out of 150, and the DSP received exactly 512 frames on every
  cycle that followed. The renderer holds no pointer across callbacks — the
  mapping is entered and left inside one call — so a removal between two
  callbacks cannot leave it reading freed memory.
- **D7** is the tail, not the median: p50 rises from 7.8 to 8.3 µs under full
  oversubscription, p99 from 10.8 to 59.7 µs. The work does not change; the
  scheduler does.

### 7.3 What Phase D does not establish

Every scenario above is a single thread calling a function, with a ring fed from
the same thread, and a *counter* of underruns that this same thread owns. There is
no IO thread whose deadline can be missed and no device that can glitch. A zero
`underrunFrames` here says the fixture kept its producer ahead of its consumer.
It says nothing about audible dropouts on hardware.

---

## 8. Phase E — regression gate

Run from a clean state, in this order. Every target exited 0.

| Gate | Command | Result |
|---|---|---|
| Protocol single-sourcing | `make protocol-check` | pass (shared header sync, protocol layout, DSP header sync) |
| Version consistency | `make version-check` | pass, 13 sources checked, 0 failed |
| DSP unit tests | `make test-dsp` | 1/1 ctest passed (1.01 s) |
| Host tests | `make test-host` | **411 tests, 10 skipped, 0 failures** (37.0 s) |
| App tests | `make test-app` | **298 tests, 0 failures** (25.5 s) |
| Full suite | `make test` | pass: protocol + version + dsp + driver + host + app + installer + unsigned (97 checks) |
| Host release build | `swift build -c release` in `packages/host` | pass |
| App release build | `make quick` (universal arm64 + x86_64) | pass; bundle binaries are fat `x86_64 arm64` |

The 10 skipped Host tests are exactly the two gated suites added here (8 soak + 2
measurement), which the gate is supposed to skip. No test expectation was changed
to make anything pass, and no DSP source changed in this phase, so the sanitizer
builds were not re-run — the task's rule is that they are re-run only when DSP
sources change.

---

## 9. Findings

Full text, evidence and status in
`SoundBridge-Host-CoreAudio-Integration-Findings.md`. Summary:

| ID | Severity | Statement | Status |
|---|---|---|---|
| F-HC-01 | INFO (was MEDIUM) | A per-band coefficient refresh with trigonometry runs on the render thread inside `try_update_eq` | Measured end to end: 91 ns for ten bands, 0.0009 % of the 512-frame deadline. Per-band attribution is an estimate (§5.3). Closed as acceptable; no code change |
| F-HC-02 | LOW | The EQ seqlock reader gives up after four attempts | Measured: 0.08–0.59 % of reads under a hostile writer; failure is fail-closed (keeps the applied configuration). No change |
| F-HC-03 | LOW | `ConfigMailbox::publish` is a `compare_exchange_weak` loop, so it is lock-free but not wait-free | Wording constraint stands: no wait-freedom, no wall-clock bound. No code change |
| F-HC-04 | INFO | Three `libm` calls per block | Constant per block, unchanged |
| F-HC-05 | GAP | No real CoreAudio device was driven | Open — see §10 |

---

## 10. Verdict

What was verified, and how strongly:

- The render path contains no allocation, no lock, no log and no blocking wait on
  another thread. Its only loop is `ConfigMailbox::publish`, a
  `compare_exchange_weak` loop that is lock-free, is not wait-free, and has no
  proved wall-clock bound; the render thread's `tryLock` and `consume` are
  single-attempt. All of it is exercised by tests, including the refusals.
- The measured cost of the whole callback at the shipping configuration is 7.1 µs
  median, 27.8 µs p99, 83.1 µs p99.9 on this machine, against the 10 666.7 µs
  deadline that belongs to that same 512-frame configuration, with the complete
  accepted ten-band `try_update_eq()` call at 91 ns and the coefficient ramp at
  about 1.4–2.9 µs.
- The path survives a parameter storm, a hostile writer, full CPU
  oversubscription, 400 render-path restarts, 200 sample-rate changes, 150 device
  removal/reappearance cycles at the Host API layer, and a 200 000-callback soak
  that covers 35.6 minutes of simulated audio-frame coverage in about five seconds
  of wall clock, with flat RSS.
- Every regression gate is green.

What was not verified: that a CoreAudio IO thread on a real device meets its
deadline, and that the audible result is uninterrupted. That requires a device,
thermal load and a real-time scheduler, none of which an in-process harness
provides.

Accordingly:

> **PASS — SOFTWARE INTEGRATION VERIFIED; HARDWARE REALTIME VALIDATION PENDING**

The software path is verified to the extent that in-process replay at release
optimisation, a ten-row concurrency matrix and eight stress/soak classes can verify
it. It is not claimed to be a complete realtime integration pass: no unit test and
no synthetic benchmark in this report is evidence about a real IO thread.

### Hardware validation procedure — F-HC-05, **not yet performed**

**Status: open. Nothing in this subsection has been executed.** Every number in
§5 and §7 came from in-process replay on this machine; not one of them is evidence
about a CoreAudio IO thread, a HAL, or a listener. Until the procedure below has
been run end to end and its record filled in, hardware realtime validation stays
*pending*, and no row above may be cited as a hardware result.

The procedure exists so that a hardware run produces attributable evidence rather
than an impression. It changes this machine's audio routing while it runs, which is
exactly why it was not performed unattended as part of this validation.

#### What has to be captured

A run that does not record all of these has not closed the gap:

| # | Record | How | Why it matters |
|---|---|---|---|
| 1 | The **actual** CoreAudio sample rate in force | Audio MIDI Setup for the SoundBridge device, cross-checked against `system_profiler SPAudioDataType`; re-read after every device event | The device renegotiates rate on its own. A run at 44.1 kHz has a different deadline from the 48 kHz baseline, and a rate change mid-run invalidates any comparison to §5 |
| 2 | The **actual** IO buffer size / frames per callback | Audio MIDI Setup for the device, and the `frames` field of the Host's `drainTiming()` line | The Host computes its own budget as `frames / sample_rate`. If the device hands it 128 frames, its deadline is 2 666.7 µs, not 10 666.7 µs — the same trap as §5.2 |
| 3 | Every change to (1) and (2) during the run, with a timestamp | The log line where the Host republishes the mapping, plus Audio MIDI Setup | A silent buffer-size change is a silent deadline change; without it, an over-budget spike has no explanation |
| 4 | **Host callback histograms** per reporting window | `log stream --predicate 'subsystem == "com.soundbridge.host"'`, `drainTiming()` lines: p50 / p95 / p99 / max, per window | These are the real-deadline counterpart of §5.1. Keep per-window lines, not just an average of them |
| 5 | **`overBudget` count**, and `overBudgetExcessMilliseconds` | Same `drainTiming()` lines | A callback that misses its deadline is the only direct evidence of a realtime failure; a p99 below the deadline is not |
| 6 | **Driver underrun counters** | The Driver's own telemetry/underrun counter, read through whatever control surface the Driver exposes | This is the number that stands in for "did the audio actually starve". If the Driver exposes no readable counter, record **"not observable"** — never assume zero |
| 7 | **Device restart / recovery events** | Host log lines around proxy reacquisition, plus `log stream` for the driver process | The Host has restart/recovery logic (`CoreAudioRestartRecoveryTests`); this is the first time it would be exercised by a real removal |
| 8 | **Audible symptoms**, with timestamps | A listening log written during the run: clicks, pops, dropouts, pitch shift, channel swap or inversion, level jump, latency drift | A histogram can be clean while the output glitches, and it can be dirty while nothing is audible. Both are data; only the listener can supply the second |
| 9 | The **original default output device**, recorded before any routing change, and the result of restoring it | `system_profiler SPAudioDataType` / Audio MIDI Setup, before and after | Without the "before" value there is no way to prove the machine was put back |

#### Procedure

1. **Record the baseline first.** Capture the current default output device, its
   sample rate and its buffer size (rows 1, 2, 9 above) *before* touching anything.
   Build and install the release bundle (`make build && make bundle`, then install
   the driver).
2. **Route through SoundBridge** and confirm the Host is actually the process
   producing the callbacks — the `drainTiming()` line must appear in
   `log stream --predicate 'subsystem == "com.soundbridge.host"'` with a non-zero
   `frames` and a plausible deadline. If that line never appears, the run is not a
   hardware validation of this path and should be abandoned, not reinterpreted.
3. **Re-read rows 1 and 2** once the Host is live, and again after any device event.
   Record them at the start, at each checkpoint, and at the end.
4. **Sustained run under load.** Drive ordinary system audio plus the eight
   scenarios of §5.1 for at least 30 minutes, with the CPU under deliberate load
   (the D7 condition: more runnable threads than cores). This is where a real IO
   thread either keeps its deadline or does not.
5. **Collect rows 4 and 5 per window.** Keep the per-window lines; a single
   aggregate hides exactly the windows that matter. Compare the shape to §5.1 —
   the in-process figures are the baseline to beat, and a real IO thread should be
   tighter on the tail, but that is a prediction to be tested, not a result.
6. **Collect row 6** at the same checkpoints. Zero underruns is the claim to
   establish; the in-process suite's zero is a property of its fixture ring and does
   not transfer.
7. **Controlled device removal and reappearance, only where it is safe to do so.**
   Switch the system output away from SoundBridge and back, and (separately)
   unplug and replug the physical device the SoundBridge device is mirroring.
   Record row 7 and row 8 for each event. Do this with the volume low or muted and
   with headphones off the head, because this step *is* expected to produce an
   audible interruption; if the machine is driving anything that must not be
   interrupted, skip the step and record it as skipped — never as passed.
8. **Restore the original default output device** recorded in step 1, then
   **confirm the original routing actually works**: play audio through it, confirm
   the right device is selected, the expected sample rate is back, and nothing is
   left routed through SoundBridge. Record the confirmation. A run that restores the
   setting but does not verify playback has not finished the procedure.
9. **Write the record down** — rows 1–9, with timestamps — before drawing any
   conclusion from it.

#### What would constitute a pass

All of: `overBudget = 0` across the whole run with the device's own frames and
rate recorded for every window; Driver underrun counter at zero, or explicitly
recorded as not observable; no unexplained restart/recovery event; no audible
symptom attributable to the Host path; the removal/reappearance step either cleanly
recovered or explicitly skipped; and the original routing restored and confirmed
working. Anything less is a partial result and should be reported as one.

#### Why it is still pending

Steps 2–8 change the machine's audio routing, and step 7 intentionally interrupts
audio. Neither is something this validation was authorised to do unattended, and
neither can be simulated: an in-process harness has no IO thread to miss a deadline
and no listener to hear a click.
