# SoundBridge — Host + CoreAudio Integration Findings

Companion to `SoundBridge-Host-CoreAudio-Realtime-Validation-Report.md`.
Every finding below was found by tracing or measuring the Host render path, and
every one has an explicit status. Nothing in this document is a proposed
architecture change: the DSP core is out of scope, and no production source was
modified by this validation.

Baseline: `main` @ `eb45303` plus the accepted DSP remediation (uncommitted).
Measurements from `SB_RT_MEASURE=1` at release optimisation, 48 kHz, 512 frames,
2 channels, arm64, deadline 10 666.7 µs.

| ID | Severity | Class | Status |
|---|---|---|---|
| F-HC-01 | INFO (downgraded from MEDIUM) | CONDITIONAL | Closed — measured, acceptable, no change |
| F-HC-02 | LOW | CONDITIONAL | Closed — measured, fail-closed, no change |
| F-HC-03 | LOW | Wording | Open as a constraint — must not be described as wait-free |
| F-HC-04 | INFO | SAFE | Closed — constant per block |
| F-HC-05 | GAP | Verification | Open — hardware realtime validation not executed |
| F-HC-06 | INFO | Measurement | Closed — defect in the harness, fixed |

---

## F-HC-01 — Per-band coefficient trigonometry on the render thread

**Severity now:** INFO. **Was:** MEDIUM, pending measurement.

**Statement.** The full-configuration coefficient refresh
(`refresh_config_coeffs`) is *not* on the render thread: it is called only from
`soundbridge_dsp_set_sample_rate` and `soundbridge_dsp_apply_preset`, both
control-thread entry points that take the blocking publisher lock. But the same
arithmetic *is* on the render thread: when the 48-byte EQ snapshot changes,
`soundbridge_dsp_try_update_eq` recomputes the coefficients of every updated band
inline with the same `bandBiquadCoeffs`. Per band that is two `sin`, one `cos`,
one `pow` (`10^(gain/40)`), plus a `sqrt` for shelf types; a disabled band takes
the flat path with no trigonometry.

**Evidence.** `engine.cpp` `try_update_eq` (`:892`) loops `band_count` times over
`bandBiquadCoeffs`; `biquad.h` `calculateCoeffs` (`:251`) contains the calls.
Measured on the real entry point:

| measurement | value |
|---|---|
| `try_update_eq`, 10 bands, uncontended | 91 ns mean over 20 000 calls |
| `try_update_eq`, 1 band, uncontended | 21 ns mean over 20 000 calls |
| implied per-band arithmetic | ≈ 7.8 ns |
| share of the 10 666.7 µs callback budget (10 bands) | 0.0009 % |
| `num_bands` reported by `soundbridge_dsp_get_preset` | 10 / 1 (self-check that the rows differ) |

**Why it is acceptable.** Three orders of magnitude below the deadline, and it is
the smallest term in the change path. The dominant term is not the arithmetic:

| term | cost |
|---|---|
| coefficient arithmetic | 91 ns |
| 10 ms coefficient ramp that `apply_config` starts when the coefficients differ | +1.4 µs (whole-callback p50 delta) to +2.9 µs (isolated) |
| per-sample biquad work (10 bands, 512 frames) | 7.2 µs |
| whole steady callback | 7.1 µs |

**Decision.** No change. Precomputing the coefficients on the publishing side is
already what `apply_config` does for the preset and sample-rate paths; doing it
for the EQ snapshot would move ~91 ns off the render thread at the cost of a new
allocation or a second buffer in a path the DSP remediation deliberately froze.
The task's own rule applies: do not reopen the DSP architecture for a 0.0009 %
term.

**Worth stating in any future summary of the DSP remediation.** The sentence
"coefficient refresh is off the audio thread" is true for the full-configuration
refresh and false for the per-band one. The accurate form is: *the full-config
refresh is control-thread; a per-band refresh with the same trigonometry runs on
the render thread whenever the EQ snapshot changes, and the estimated incremental
per-band cost is approximately 7.8 ns, inferred from the difference between two
composite means under a linear-cost assumption.*

---

## F-HC-02 — The EQ seqlock reader gives up after four attempts

**Severity:** LOW.

**Statement.** `rf_load_eq_snapshot_safe` (`RFSharedAudio.h:1531`) tries four
times to take a consistent 48-byte copy; on the fifth it returns `false` and the
caller keeps the snapshot it already applied. The failure mode is fail-closed —
no torn read, no partial configuration, the previous EQ stays in force — so the
consequence of giving up is a one-block-late EQ change, not wrong audio.

**Evidence.** Reader with a writer spinning `rf_store_eq_snapshot` as fast as it
can, 200 000 reads: 117 give-ups in one run, 1 177 in another — **0.08 % to
0.59 %**, depending on how often the scheduler let the writer run. Mean read cost
1.4–1.7 ns. Reader with no writer: 0 give-ups in 200 000, 0.5–0.9 ns.

**Note on the numbers.** A give-up means four consecutive failed attempts, so
those rates correspond to roughly 470–4 700 failed attempts per 800 000. That is
the adversarial case by construction — a writer that never pauses — and it still
costs the reader under 2 ns on average, because a failed attempt is a load and a
compare.

**The rate is not stable across runs**, and that is the point: it is set by how
the writer is scheduled, not by anything the reader controls. Quoting a single
percentage would be false precision; what matters is that the fallback is the
previous configuration and the cost is one block of EQ latency underneath a 10 ms
ramp.

**Decision.** No change. Wiring an event to retry later would add a notification
path to a design that deliberately has none. A 10 ms ramp already smooths an EQ
change over 480 samples, so a block of latency is below the resolution of the
smoothing.

**Residual risk.** If a future change increases the snapshot size or the writer
rate, re-measure. What makes this finding LOW is not that the rate is small — it
moved by a factor of seven between two runs — but that the failure is fail-closed
and the recovery is the next block.

---

## F-HC-03 — `publish` is lock-free, not wait-free

**Severity:** LOW — a documentation constraint, not a defect.

**Statement.** `ConfigMailbox::publish` (`config_mailbox.h:190`) is a
compare-exchange loop: it is lock-free (some thread always makes progress) but a
given caller can be starved by a competing publisher, so it is not wait-free. The
consumer side is bounded: one acquire load, at most one compare-exchange, no loop.
`PublisherToken::tryLock` is a single exchange.

**Consequence for this report.** Anything describing the render path must say
"bounded in attempts", never "wait-free" and never "bounded wall-clock wait". The
DSP remediation report was corrected to exactly that wording (§2.2 of the task),
and the execution-path document uses the same language.

**Evidence from observed contention behavior.** Under a peer holding the token,
the refusal costs 23 ns (one failed exchange and return), against 112 ns for an
acceptance, with a 25.5 % refusal rate when the peer is spinning. The render path
never retries, so the loop in `publish` is never entered from the audio thread
with a contended token.

---

## F-HC-04 — Three `libm` calls per block

**Severity:** INFO.

`process_interleaved` calls `std::exp` twice per block regardless of the bypass
decision (peak decay :506/:575, CPU-load EMA :601). `VolumeTaper.gain` in the Host
uses `sqrtf` and `powf` per callback. All are constant per block, none is per
sample, and none is inside the coefficient loop. No action; recorded so a future
reader does not mistake the presence of `exp` in the block function for per-sample
transcendentals.

---

## F-HC-05 — No real CoreAudio device was driven

**Severity:** verification gap, not a defect.

**Statement.** Every number in the validation report comes from driving
`AudioRenderer.render(bufferList:frameCount:)` in-process with a real mapping, a
real `AudioBufferList` and a real DSP engine. There is no IO thread, no device, no
real-time priority and no thermal load. A hardware run is the one thing that would
turn "software integration verified" into a full pass, and it was not performed
because it requires rerouting this machine's system audio for the duration.

**What is already in place, so a hardware run is a thirty-minute job.**
The driver is installed (`/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver`),
the Core Audio driver process is running, onboarding is complete, and
`dist/SoundBridge.app` was rebuilt as a universal release bundle during Phase E.
`drainTiming()` already prints one line per window with p50/p95/p99/max,
over-budget count and over-budget excess, so no instrumentation is needed.

**Procedure.** See §10 of the validation report. In short: record the current
default output, route through SoundBridge, confirm the `com.soundbridge.host`
timing lines by **polling** `log show --last 12s` (`log stream` block-buffers
into a pipe and shows nothing while the Host is running — measured in A2–A4),
run for 30 minutes under load, compare
`overBudget` and the driver's underrun counters against §5 of the report, restore
the default output.

**Until then** the verdict is
`PASS — SOFTWARE INTEGRATION VERIFIED; HARDWARE REALTIME VALIDATION PENDING`, and
no statement in this validation should be read as a claim about a real IO thread.

---

## F-HC-06 — The measurement harness read a mapping it was not feeding

**Severity:** INFO — a defect in the harness, found and fixed. Recorded because it
produced credible-looking data.

**What happened.** The first Phase B run reported the steady state at 7.1 µs but
five other scenarios at 0.2–0.5 µs. The pattern was wrong: an EQ change cannot
make the callback *faster*.

**Root cause.** `SharedMemoryManager.refreshRenderMemory()` publishes exactly one
mapping for the render path, chosen as `preferredRenderUID ?? deviceMemory.values.first`.
A fixture that creates several mappings in one manager leaves the gate's choice
to dictionary ordering, so the renderer could enter a mapping nothing was feeding.
`rf_ring_read` returned zero frames, the `framesRead > 0` guard skipped the whole
DSP block, and the callback measured a few hundred nanoseconds of guard code.

**Fix.** One `SharedMemoryManager` per scenario, each naming its mapping as the
preferred render UID. The soak suite does the same.

**Lesson that generalises.** When a benchmark reports a *faster* number for a
*heavier* configuration, suspect that the work is not happening, and assert that
it happened (`dspFrames == (callbacks + warmup) × frames`, `num_bands` read back
from the engine) rather than inferring it from the timing.

---

## Disposition

Four findings closed (F-HC-01, 02, 04, 06), one is a standing wording constraint
(F-HC-03), one is an open verification gap that no amount of in-process testing
closes (F-HC-05). No production code was changed by this validation; the two
test-only additions are gap coverage for rows that had none, not fixes.
