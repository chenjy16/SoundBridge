# Host + CoreAudio — Realtime Execution Path

Status: Phase A deliverable of *SoundBridge — Host + CoreAudio End-to-End Realtime Integration Validation*.

Baseline this document was produced against: branch `main`, commit `eb45303`, working tree with 24 modified and 12 untracked paths (the pre-existing state, unmodified by this phase). No source file was changed to produce this document.

Scope: what actually executes between CoreAudio's `AURenderCallback` and the bytes handed back to the IO thread, classified operation by operation. The document is deliberately literal: a function being called from the existing render callback is **not** treated as evidence that it is realtime-safe. Each entry below is either backed by the code it names or marked UNKNOWN and handed to Phase B for measurement.

---

## 1. Method

1. Read the render entry point and every function it reaches, transitively, from Swift into C and C++.
2. For each operation record: what it does, where it lives, its cost shape (constant / proportional to frames / proportional to bands / unbounded), and whether it can wait on another thread.
3. Classify SAFE / CONDITIONAL / UNSAFE / UNKNOWN. CONDITIONAL means "bounded, but the bound is a measurement question rather than a structural guarantee" — Phase B measures those, this document does not assume them.
4. Record what is **absent** from the path as carefully as what is present, because the absence claims are what the realtime contract actually rests on.

Classification legend:

| Class | Meaning |
|---|---|
| **SAFE** | Bounded work with no dependency on another thread making progress. No allocation, no lock, no syscall, no I/O. |
| **CONDITIONAL** | Bounded in operation count, but not structurally proven realtime-safe: it may call into libc/libm, or it may retry a bounded number of times, or its cost is proportional to a runtime value (band count, frame count). Phase B measures it. |
| **UNSAFE** | May block on another thread for an unbounded time, allocate, log, or perform I/O. Must not appear on this path. |
| **UNKNOWN** | Reached by the path, cost or blocking behaviour not established. |

---

## 2. The execution path

### 2.1 Callback entry

| # | Operation | Location | Class | Notes |
|---|---|---|---|---|
| 1 | CoreAudio invokes the block set by `AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback)` | `AudioRenderer.createRenderCallback()` — `AudioRenderer.swift:538-556` | SAFE | Captured `AURenderCallback`; `Unmanaged.takeUnretainedValue()` is a pointer read, no retain/release |
| 2 | Nil `ioData` early return | `:547-549` | SAFE | |
| 3 | `render(bufferList:frameCount:)` | `AudioRenderer.swift:563` | — | The whole path below |
| 4 | `mach_absolute_time()` — start stamp | `:567` | SAFE | One register read |
| 5 | `defer { recordCallbackDuration(...) }` | `:568` | SAFE | Non-escaping `defer`; no allocation |
| 6 | `UnsafeMutableAudioBufferListPointer(bufferList)` | `:570` | SAFE | Struct wrapper over the pointer; no allocation |
| 7 | First-pass record (once, then a local `Bool`) | `:579-582` → `RenderDiagnostics.recordFirstPass` `:105-124` | SAFE | Stack tuple + rebound pointer; `rf_rt_counters_record_first_pass` is relaxed atomic stores |

`recordCallbackDuration` (`:379-392`) runs in the `defer`, i.e. on **every** return path including the three refusals:

| # | Operation | Location | Class | Notes |
|---|---|---|---|---|
| 8 | `mach_absolute_time()` — end stamp, integer ns conversion | `:380-387` | SAFE | Integer multiply/divide; no floating point |
| 9 | Budget computation `frames * 1e9 / rate` | `:389-390` | SAFE | Integer; `rate` is a Swift field, not a locked config read |
| 10 | `rf_rt_hist_observe` | `RFRealtimeTelemetry.c:74-84` | SAFE | One bucket index computation, then 1–3 relaxed `atomic_fetch_add`. Branch on over-budget only increments counters |

### 2.2 Refusal guards

| # | Operation | Location | Class | Notes |
|---|---|---|---|---|
| 11 | Capacity guard (`frameCount <= capacity`, `channels <= capacity`) | `:587-593` | SAFE | Two compares; refusal writes zeros via `outputSilence` (`:833-841`), a bounded loop |
| 12 | `memoryManager.enterRenderMemory()` → `rf_rt_gate_enter(renderGate)` | `SharedMemoryManager.swift:453-456` | SAFE | `atomic_fetch_add(seq_cst)` on the lease counter, then one acquire load of the published pointer. No lock, no allocation. A NULL result withdraws the lease |
| 13 | `defer { memoryManager.exitRenderMemory() }` | `:603` → `rf_rt_gate_exit` | SAFE | One `atomic_fetch_sub` |

Note the gate's purpose: the lease is what allows the control thread to defer a mapping swap instead of freeing memory under a running callback. It is a publisher-side mechanism; the render side only increments and decrements.

### 2.3 Mapping header, layout guards, ring read

| # | Operation | Location | Class | Notes |
|---|---|---|---|---|
| 14 | `mem.pointee.sample_rate` load | `:607-608` | SAFE | Plain load from the mapping; used to size the per-callback budget |
| 15 | Ring channel count vs. presented channel count | `:613-619` | SAFE | Compare + two counter increments |
| 16 | `renderBuffer.update(repeating: 0, count: needed)` | `:622` | SAFE | Writes at most `capacityFrames * capacityChannels` floats into the pre-allocated buffer; no growth, no allocation |
| 17 | `rf_ring_read` | `:648` | CONDITIONAL | Bounded copy of at most `num_frames * channels` floats. Reads `write_index` with acquire, `read_index` with relaxed; two relaxed additions on the consumer side. Underrun path increments `underrun_count` and zero-fills. Cost is proportional to frames — measured in Phase B |
| 18 | `diagnostics.noteUnderrun` / `noteSilenceFallback` | `:649-657` | SAFE | Relaxed atomic `fetch_add` |

### 2.4 EQ snapshot read and change detection

| # | Operation | Location | Class | Notes |
|---|---|---|---|---|
| 19 | `RFEQSnapshot()` — 48-byte stack value | `:665` | SAFE | Stack only (`RFSharedAudio.h:376` pins the size) |
| 20 | `rf_load_eq_snapshot_safe(mem, &eqSnapshot)` | `RFSharedAudio.h:1531-1542` | CONDITIONAL | A SeqLock read with a **bounded retry loop of 4 attempts**: acquire-load sequence, `memcpy` 48 bytes, acquire-load sequence again, compare. Cost per attempt is one 48-byte copy plus two acquire loads. It cannot spin indefinitely (4 attempts then `false`), but it *is* a retry loop, so it is not wait-free. On `false` the caller skips the update and keeps the last applied configuration — the correctness fallback makes the bounded retry acceptable, but the retry count is a realtime property to state, not to assume |
| 21 | `memcmp` of new vs. `lastEQSnapshot`, 48 bytes | `:673-677` | SAFE | Two fixed-size `withUnsafeBytes` scopes and one `memcmp` over 48 bytes. Not proportional to band count or frames |

### 2.5 EQ publication (only when the 48-byte snapshot changed)

| # | Operation | Location | Class | Notes |
|---|---|---|---|---|
| 22 | `soundbridge_dsp_try_update_eq(engine, bands, preamp)` | `:686-690` → `engine.cpp:892-935` | CONDITIONAL | See 2.5.1 |
| 23 | `soundbridge_dsp_set_bypass(engine, eqSnapshot.bypass)` | `:694` → `engine.cpp:828-832` | SAFE | One relaxed atomic store. Deliberately outside the token: bypass is an emergency passthrough and must not be refused |
| 24 | `lastEQSnapshot = eqSnapshot` on success only | `:698-700` | SAFE | 48-byte struct assignment; the refusal path leaves the applied baseline untouched so the snapshot is retried next block |

#### 2.5.1 Inside `soundbridge_dsp_try_update_eq`

| # | Operation | Location | Class | Notes |
|---|---|---|---|---|
| 22a | `PublisherTryLock` → `PublisherToken::tryLock()` | `config_mailbox.h:341-358`, `309-311` | SAFE | **One** `exchange(acquire)`, no loop. A refusal returns `false` immediately and nothing is written |
| 22b | Per band `isfinite` check + clamp to ±12 dB | `engine.cpp:911-916` | SAFE | Constant work per band |
| 22c | `bandBiquadCoeffs(band, sample_rate)` | `engine.cpp:917-918` → `biquad.h:415-423` → `calculateCoeffs` `:251-379` | CONDITIONAL | **Real work on the render thread.** Per enabled band: `cos(w0)`, `sin(w0)`, a second `sin(w0)` for the warp factor, `pow(10, gain/40)`, and for shelf types a `sqrt(A)`. With 10 bands that is up to 20 `sin`, 10 `cos`, 10 `pow`, ~6 `sqrt` calls in one callback. Disabled bands short-circuit to `flatBiquadCoeffs()` with no trig |
| 22d | `shadow.set_smooth(i)` per band | `engine.cpp:923` | SAFE | Bit set in a `uint32_t` |
| 22e | `mailbox.publish(shadow)` | `engine.cpp:933` → `config_mailbox.h:190-213` | CONDITIONAL | **A `compare_exchange_weak` retry loop: lock-free, not wait-free.** One ~500-byte POD copy into the back slot, then `compare_exchange_weak(acq_rel, acquire)` inside `for(;;)`. The loop retries when the consumer exchanged the state word in between, and a weak compare-exchange may also fail spuriously. Producers are serialised by the publisher token, which is why the loop is not expected to spin, but it *is* a loop and no wall-clock bound is claimed for it |
| 22f | `PublisherTryLock` destructor | `config_mailbox.h:346-348` | SAFE | One `store(release)` when the token was taken |

**Does `refresh_config_coeffs()` run on the render thread?** No. `refresh_config_coeffs` (`engine.cpp:287-292`) is called from exactly two places: `soundbridge_dsp_set_sample_rate` (`:462`) and `soundbridge_dsp_apply_preset` (`:791`). Both are control-thread entry points and both take the blocking `PublisherLock`.

**But the equivalent computation does run on the render thread.** `try_update_eq` recomputes the coefficients of every updated band inline at step 22c, using the same `bandBiquadCoeffs` that `refresh_config_coeffs` uses. The difference is scope, not kind: `refresh_config_coeffs` recomputes all 10 slots, `try_update_eq` recomputes `shadow.preset.num_bands` of them and only for bands whose snapshot value changed. So the honest statement is:

> The full-configuration coefficient refresh is off the render thread. A per-band coefficient refresh, with the same trigonometry, is on the render thread whenever the 48-byte EQ snapshot changes. Phase B measures it against the callback deadline; whether it is acceptable is a measurement question, not a design assumption.

This is exactly the case the task brief calls out, and the finding is recorded as **F-HC-01 (CONDITIONAL, measurement pending)** rather than pre-judged either way.

### 2.6 DSP block processing

`soundbridge_dsp_process_interleaved` — `engine.cpp:472-608`.

| # | Operation | Location | Class | Notes |
|---|---|---|---|---|
| 25 | `enable_denormal_suppression()` | `:487` | SAFE | Two FPU control-register writes. Intentionally per-block: FTZ/DAZ are per-thread architectural state and the engine is created on the control thread. A `thread_local` guard would trade this for a TLS lookup, which on first access inside a dylib may take a lock |
| 26 | `std::chrono::high_resolution_clock::now()` (start) | `:490` | CONDITIONAL | On Darwin this is `clock_gettime(CLOCK_UPTIME_RAW)`-class work: no syscall, but a libc call. Classified CONDITIONAL rather than assumed SAFE; Phase B's whole-callback histogram includes it |
| 27 | `sync_config(engine)` | `:494` → `:366-396` | CONDITIONAL | `mailbox.consume` is one acquire load plus **at most one** `compare_exchange_strong` — no loop on the consumer side (`config_mailbox.h:227-264`). When it succeeds, `apply_config` (`:300-356`) walks `band_count` bands calling `setCoeffsInstant` or `rampCoeffsTo`: constant work per band, no trig, no allocation. When it fails, the block keeps its previous configuration. Bounded |
| 28 | Reset-request check | `:381-395` | SAFE | One acquire load; on a change, `resetHistory()` per band and a DC-blocker reset — constant work, no allocation |
| 29 | `bypass` load | `:497` | SAFE | Relaxed atomic load |
| 30 | Bypass branch: `memcpy` + 4 meter decays with `std::exp` | `:499-513` | CONDITIONAL | `memcpy` of `frames * 2` floats; one `std::exp`. Only on the bypass path |
| 31 | Per-sample loop: deinterleave, preamp, up to 10 biquads, DC blocker, peaks, limiter, interleave | `:531-569` | CONDITIONAL | Cost proportional to `frames × enabled_bands`. `Biquad::processSampleMono` (`biquad.h:210-241`) has a `transition_remaining_` branch that is not taken when stable, and a per-sample `isfinite` guard on the output. The limiter and DC blocker are similarly branch-bounded. No allocation anywhere in the loop. This is the dominant cost and Phase B measures it per scenario |
| 32 | Peak decay `std::exp` | `:575` | CONDITIONAL | One libm call per block |
| 33 | `update_peak_meter` × 4 | `:579-586` | SAFE | Relaxed atomic load/store pairs |
| 34 | `std::chrono::high_resolution_clock::now()` (end) + CPU load maths | `:589-604` | CONDITIONAL | One more clock read; then `std::exp` for the EMA alpha and one relaxed atomic store |
| 35 | `frames_processed.fetch_add` | `:607` | SAFE | Relaxed atomic |

### 2.7 Gain stage

| # | Operation | Location | Class | Notes |
|---|---|---|---|---|
| 36 | `rf_load_volume_scalar`, `rf_load_mute_state` | `:713-714` | SAFE | Atomic loads from the mapping's volume block |
| 37 | `VolumeTaper.sanitize` | `:713` → `VolumeTaper.swift:85-95` | SAFE | Finite checks and clamps |
| 38 | `VolumeTaper.gain(forScalar:)` | `:719` → `VolumeTaper.swift:47-49` | CONDITIONAL | `sqrtf` + `powf(10, x/20)` — two libm calls, **once per callback**, not per sample. Skipped entirely on the mute/zero-volume path |
| 39 | Smoothing loop / mute zero-fill / unity passthrough | `:726-743` | SAFE | One multiply-add and a clamp per frame, or a bounded zero-fill |

### 2.8 Output

| # | Operation | Location | Class | Notes |
|---|---|---|---|---|
| 40 | `deinterleave(source:bufferList:framesRead:totalFrames:)` | `:746-751`, `:843-874` | SAFE | Per channel: a bounded copy of `min(framesRead, capacity)` floats and a bounded zero-fill of the remainder. Clamps both ends before forming ranges, so a short `AudioBuffer` cannot trap |

---

## 3. Operations the path does **not** contain

These absences are load-bearing; each was checked in the code rather than inferred from a comment.

| Claim | Evidence |
|---|---|
| No heap allocation | No `malloc`/`calloc`/`new`/`Array(...)` on the path. Buffers are allocated in `AudioRenderer.init` (`:272`) and `RenderDiagnostics.init` (`:87`); the first-pass record uses a stack tuple explicitly to avoid a `Swift Array` (`:115-123`) |
| No `os_unfair_lock`, `pthread_mutex`, or `NSLock` | The gate, the counters (`RFRealtimeTelemetry.c`), the ring and the mailbox are all C11 atomics. The two `os_unfair_lock` uses in `SharedMemoryManager` (`:467-470`, `:481-483`) are control-thread functions (`drainDeferredRenderPublication`, `reclaimRenderMappingsIfIdle`), not reachable from `render()` |
| No `std::this_thread::yield()` | `yield()` appears only in `PublisherToken::lock()` (`config_mailbox.h:295-301`). The render path uses `tryLock()` (`:309-311`), which never yields. `PublisherLock` (the blocking form) is used only by control-thread entry points: `set_sample_rate`, `apply_preset`, `get_preset`, `update_band_gain`, `update_preamp`, `update_band_frequency`, `update_band_q` |
| No logging, formatting, or string interpolation | `String(format:)` and `logger.notice` appear only in `drainTiming()` (`:480-498`); `print` only in `drainDiagnostics()` (`:347-349`) and `updateSampleRate` (`:531`, `:533`). All three are control-thread |
| No file-system access, no IPC | Not present in `render()` |
| No ObjC message sends / no ARC traffic | `AudioRenderer` is a plain Swift class; the callback retrieves it with `Unmanaged.takeUnretainedValue()` (no retain). `RenderDiagnostics` and `DSPDiagnostics` are structs |
| No DSP construction | `soundbridge_dsp_create` runs in `init` (`:288`); `applyInitialPreset` also in `init` (`:292`). `updateSampleRate` (`:521-536`) waits for the render path to be idle before calling `set_sample_rate` |
| No unbounded wait | Every wait-capable primitive reachable from `render()` is one of three shapes: a single **atomic exchange** (`PublisherToken::tryLock`, `busy_.exchange(true, acquire)`), a single `compare_exchange_strong` (`ConfigMailbox::consume` / `try_consume`), or a fixed 4-attempt loop (`rf_load_eq_snapshot_safe`). The one loop on the render thread is `ConfigMailbox::publish` — a `compare_exchange_weak` retry loop reached from `try_update_eq` only after `tryLock` succeeded. It is **lock-free, not wait-free**, and no wall-clock bound is claimed for it; in the uncontended case it returns on the first exchange. Nothing on this path blocks on another thread's completion |

---

## 4. Answers to the specific questions

| Question | Answer |
|---|---|
| Does `refresh_config_coeffs()` execute on the render thread when `try_update_eq()` runs? | No. But the same per-band coefficient maths runs there inline, for up to `num_bands` bands, whenever the 48-byte EQ snapshot changes. See 2.5.1 and F-HC-01 |
| Is there trigonometry on the render thread? | Yes, conditionally: 2 `sin` + 1 `cos` + 1 `pow` (+ 1 `sqrt` for shelving types) per updated band, only on blocks where the EQ snapshot changed. Also `sqrtf`+`powf` once per callback in the volume taper, and 3 `std::exp` per block in the DSP block-level maths |
| Are there copies on the render thread? | Yes, all bounded: 48-byte snapshot copy (up to 4×), 48-byte `memcmp`, ~500-byte config copy on publish, `frames * channels` float copies in the ring read and deinterleave, `frames * 2` float `memcpy` on the DSP bypass path |
| Are there atomics / CAS that can fail? | Yes, and they are not all CAS. `PublisherToken::tryLock` is one **atomic exchange** (`exchange(true, acquire)`) — it does not fail, it reports that the token was already held. `ConfigMailbox::consume` / `try_consume` is one `compare_exchange_strong(acq_rel, acquire)` with no loop, which fails only if the state word moved; a failure leaves the publication pending for the next block. `ConfigMailbox::publish` is a `compare_exchange_weak` inside `for(;;)`, which may retry both on interference and on a spurious weak-CAS failure. Every failure on the render path is handled the same way — keep the current configuration, publish again next block — and the render thread never retries a refused `tryLock`. `publish` is a loop, so it is lock-free rather than wait-free; no wall-clock bound is claimed for it |
| Does anything call `std::this_thread::yield()`? | Not reachable from `render()`. Only `PublisherToken::lock()`, control threads only |
| Is there logging / formatting / ObjC / Swift allocation on the path? | No |
| How is shared memory synchronised? | SeqLock for the 48-byte EQ snapshot (`eq_sequence` odd/even), acquire/release pair for ring indices, relaxed atomics for telemetry counters and volume scalars, seq_cst for the render-gate lease. No lock in any of them |
| Any indirect locking? | None found. The one place worth naming is `rf_load_eq_snapshot_safe`'s bounded retry: it is a stale-read guard, not a lock, and it cannot block on another thread — it can only fail after 4 attempts |

---

## 5. Findings raised by this phase

| ID | Severity | Class | Statement |
|---|---|---|---|
| F-HC-01 | MEDIUM (measurement pending) | CONDITIONAL | Up to 10 bands of biquad coefficient trigonometry run on the render thread whenever the EQ snapshot changes, inside `try_update_eq`. Whether that is acceptable depends on its cost relative to the callback deadline. Phase B measures it; if the measured cost is a material fraction of the deadline, the minimal fix is to move the per-band coefficient computation off the render thread (for example by publishing precomputed coefficients), not to change the mailbox |
| F-HC-02 | LOW (measurement pending) | CONDITIONAL | `rf_load_eq_snapshot_safe` retries up to 4 times. Bounded, and it fails closed, but the retry path should be observed rather than assumed rare |
| F-HC-03 | LOW (documentation) | CONDITIONAL | `ConfigMailbox::publish` is a `compare_exchange_weak` retry loop, not a single attempt: it is lock-free but not wait-free, and a weak compare-exchange may also fail spuriously. Any realtime claim about the producer side must say "bounded in attempts; lock-free, not wait-free" — never "wait-free", and never a wall-clock bound, which has not been proved. The consumer side is one acquire load plus at most one `compare_exchange_strong`, and `PublisherToken::tryLock` is a single `exchange` |
| F-HC-04 | INFO | SAFE | The three libm-heavy spots — volume taper (`powf`/`sqrtf`), DSP peak decay and CPU EMA (`std::exp`) — are constant-per-block, not per-sample, and are included in the whole-callback histogram that Phase B reads |

None of these is a BLOCKER or HIGH: no unbounded wait on another thread's
completion, no allocation, no lock, no logging, and no tearing path was found in
the render callback. Every finding above is a *cost* question whose answer lives in
Phase B's measurements.

**Code changes in Phase A: none.** The task brief requires measuring `refresh_config_coeffs`-class work before deciding whether to move it, and the existing code already has the telemetry needed to measure it without new production instrumentation. Moving work off the render thread before measuring would be the redesign the brief explicitly forbids.

---

## 6. Hand-off to Phase B

Phase B must measure, using the unmodified production path wherever possible:

| What to measure | Why |
|---|---|
| Whole-callback duration distribution per scenario | The production histogram (`rf_rt_hist_*`, 2 µs buckets, 8192 buckets, 16.384 ms overflow floor) already records it on every callback. `takeTimingSnapshot()` exposes p50/p95/p99/max plus `overBudget`, and `AudioRenderer` already computes the budget as `frames / sample_rate` from the mapping's own rate (`:389-390`) |
| Per-band coefficient refresh cost | Isolate `try_update_eq` in a micro-benchmark with the same inputs the callback passes, so F-HC-01 gets a number instead of an adjective |
| Publish vs. refusal cost | Same micro-benchmark, with and without a control-thread publisher holding the token |
| `rf_load_eq_snapshot_safe` failure rate | F-HC-02: observe the 4-attempt give-up path |
| Real CoreAudio callback timing | Distinguish it from synthetic in-process replay. A synthetic burst proves work and cost shape; only a real IO thread proves scheduling |

The classification in this document is the input to Phase B, not a substitute for it. No scenario in Phase B may conclude "safe" from the class recorded here; it must conclude from the measurement.

---

## 7. What the measurements said

This section was added after Phase B/C/D ran, so the classes above can be read
against their results. Detail is in
`SoundBridge-Host-CoreAudio-Realtime-Validation-Report.md`; findings are in
`SoundBridge-Host-CoreAudio-Integration-Findings.md`.

| Question this document left open | Answer |
|---|---|
| F-HC-01: what does the per-band coefficient refresh cost? | 91 ns is the mean of a **complete accepted ten-band `try_update_eq()` call**, end to end — coefficient calculation for every band plus the mailbox publish — not an isolated coefficient calculation. `(91 − 21) / 9 ≈ 7.8 ns` is an **estimated incremental per-band cost** derived from two such means, and is not a measured coefficient-calculation duration. 0.0009 % of the 512-frame deadline. Neither pure coefficient calculation nor an isolated successful publish was measured on its own. The dominant change-path cost is the 10 ms coefficient ramp (1.4–2.9 µs), not the trigonometry |
| F-HC-02: how often does the seqlock reader give up? | 117–1 177 of 200 000 reads (0.08 %–0.59 % across two runs) against a writer that never pauses; fail-closed, mean read under 2 ns |
| F-HC-03: is the publish path bounded? | Bounded in attempts, not wait-free, and no wall-clock bound is claimed. `publish` is a `compare_exchange_weak` loop; the render path's `tryLock` and `consume` are single-attempt (an exchange and a strong compare-exchange respectively). A refusal costs 23 ns against 112 ns for an acceptance, and the render path never retries a refused token |
| F-HC-04: are the `libm` calls per block? | Yes, three per block; per-sample cost is zero |
| Is the path safe under contention? | 25.5 % refusal rate against a spinning peer, 0 refusals and 0 short blocks over 400 path restarts, 150 device-removal/reappearance cycles at the Host API layer, and a 200 000-callback soak that covers 35.6 minutes of simulated audio-frame coverage in about five seconds of wall clock |

No class recorded above changed as a result: nothing in the render callback is
UNSAFE, and the two CONDITIONAL items are both measured and both within budget.
