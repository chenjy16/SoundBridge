# SoundBridge 1.2.1 — Release Notes

Published with the GitHub release for tag `v1.2.1`; the release page carries the date.
Release type: **maintenance release — unsigned and not notarized, same policy as 1.2.0**
Package version: `1.2.1` · App ↔ driver protocol: `0x00020200` (131584), **unchanged**

Written in English because this file is published as a release asset.

---

## 0. How to read this document

Every claim carries an evidence level. A feature can have several; only the strongest
one is what a sentence may rely on.

| Level | Meaning |
|---|---|
| **REAL_MACOS_VERIFIED** | Run on a real macOS machine with real build artifacts, following the user's path, with the output recorded |
| **TEST_VERIFIED** | Covered by an automated suite that passes |
| **SOURCE_VERIFIED** | Read from source, scripts or artifact structure; not run |
| **NOT_VERIFIED** | No evidence. Nothing in this document implies it works |

Numbers are measurements from one machine on one day. They are evidence that this
release works there, not a performance guarantee for other hardware, other sample
rates, or a longer session.

What 1.2.1 does **not** claim: that the audio path has been measured for frequency
response or phase, that every sample rate and buffer size has been exercised, or that
the app has been run on Intel Macs or on macOS 13/14. Section 5 lists the gaps
individually.

---

## 1. This release

1.2.1 is a maintenance release. It closes the three defects reported against 1.2.0
(OBS-1 – OBS-3), closes a twenty-finding audit of the DSP core, and makes the
shared-memory API refuse an invalid mapping instead of reporting it healthy. There
are no new features, no protocol change, and no change to the install layout.

It is also the first release that ships a license. 1.2.0 was published without one;
1.2.1 ships `LICENSE` (PolyForm Noncommercial 1.0.0) and `THIRD_PARTY_NOTICES.md`
inside the bundle — see §3.7.

**Install this over 1.2.0 with the PKG.** The preinstall gate compares bundle id,
then protocol, then version: the protocol is identical and `1.2.1 > 1.2.0`, so the
install is an in-place upgrade. The DMG cannot replace the driver and is not an
upgrade path.

---

## 2. Upgrade, downgrade, coexistence

### 2.1 From 1.2.0

Supported and tested as a path (`tools/test_installer_preinstall.sh` runs the
package's own preinstall against temporary roots with a 1.2.0 driver present).

1. Quit SoundBridge from the menu bar. A running Host keeps its old mapping after the
   driver is replaced, until it exits on its own.
2. Install `SoundBridge-1.2.1.pkg`.
3. Your EQ and volume settings are kept: 1.2.1 reads the four per-band keys 1.2.0
   wrote, migrates them into one dictionary per device, and re-sends the values to the
   DSP on launch instead of waiting for a slider to move.

### 2.2 From 1.1.x

Unchanged from 1.2.0: the PKG is mandatory. The shared-memory protocol moved to
`0x00020200` in 1.2.0, and an old driver paired with a new app produces no audio.

### 2.3 Downgrading to 1.2.0

`KNOWN` — 1.2.1 stores each device's EQ as one dictionary under
`eq_<deviceUID>_state` and no longer writes 1.2.0's four keys. A 1.2.0 app therefore
restores the last values **1.2.0** saved, not the ones you set in 1.2.1. Nothing is
destroyed — the 1.2.1 dictionary stays in preferences, and upgrading again restores
the newer values. Recorded as B-1 in
[Known limitations](risks/Known-Limitations.md).

Volume and mute survive a downgrade: they live in the shared-memory state block and
in `volume-state.json`, whose shape did not change.

---

## 3. What changed

### 3.1 Volume and mute commit without a playback session (OBS-1)

At 1.2.0 a volume or mute write could return success and still not be in effect. The
driver installs the volume control's committed value during `OnStartIO`, so a change
made while nothing was playing stayed in the HAL control and the next playback
handshake could adopt the older value; the UI had already moved.

- The Host now commits every accepted volume/mute change into the shared-memory
  volume state block unconditionally, instead of only while forwarding to a physical
  device that owns the default output. The value is therefore already in place when
  the driver next runs `OnStartIO`, and it survives a Host restart or a driver
  reconnection.
- The app writes the property and then reads it back. The menu bar moves only to what
  the device reports; a write that is accepted and dropped is logged as such and never
  displayed as applied.
- For the SoundBridge proxy the tolerance is one raw step of its 48-step taper, because
  the proxy quantises to its own steps. A third-party device keeps HAL-status
  semantics: it may quantise more coarsely, and refusing its valid changes would be a
  regression (B-3).

### 3.2 EQ settings persist, and are re-applied on launch (OBS-2)

At 1.2.0 the last position of a drag was never persisted: the only save sat behind the
change check in the 30 Hz sink, and releasing the slider advanced the cache first, so
the final value looked unchanged.

- The sink saves whether or not it detected a change; release and reset save
  explicitly.
- Each device's EQ is one dictionary (`{bass, mids, treble, enabled}`) under one key,
  written atomically, so a crash between two writes cannot mix one drag's gains with
  another's bypass flag.
- Restore validates field by field: an unusable field falls back to its default and the
  other three survive; a non-finite gain is discarded; a finite out-of-range gain is
  clamped to ±12 dB.
- Restored values are pushed to the DSP on launch.

### 3.3 Uninstall lifecycle (OBS-3)

At 1.2.0 the uninstaller removed the driver bundle and nothing else: a running Host
kept its mapping, runtime IPC files stayed in `/tmp`, and a single exit code could not
distinguish "removed a file" from "the driver was already gone".

- Four phases in a fixed order — identify, stop, release IPC, remove. No phase runs
  before identification succeeds: the bundle id must be `com.soundbridge.driver`, a
  symlink or a foreign bundle is refused.
- Only processes whose executable is this installation's Host **and** whose owner is
  you are signalled: `SIGTERM`, a bounded wait (default 5 s, `--timeout`), then
  `SIGKILL` against that same pid. `--keep-host` skips the phase; an unreadable process
  table is reported as "not verified", never as "nothing was running".
- `/tmp/soundbridge-<uid>-*` and the device control file are released. A file that
  cannot be removed is a failure, not a warning.
- Four states are reported separately — files removed from disk, driver unloaded from
  `coreaudiod`, the CoreAudio device gone, `coreaudiod` restarted. Only the first is
  performed. `coreaudiod` is never signalled, so the loaded copy stays resident until
  it is restarted or the machine reboots (B-2).
- The PKG receipt and the installer transaction logs are reported, never deleted. EQ
  settings, volume state, logs and the app are kept.
- Idempotent: a second run is a no-op, a machine with nothing installed exits 0, and a
  failure exits non-zero naming the step it could not complete.

### 3.4 DSP core: twenty audit findings closed

An audit of the DSP engine recorded twenty findings — two P1, seven P2, eleven P3 — and
1.2.1 closes all twenty. The two P1 findings were structural, and both were fixed by
changing the shape of the code rather than the symptom:

- **The test suite could not fail.** A header-scope `static TestStats` gave every
  translation unit its own counter, so a failing assertion incremented a copy the
  runner never read. There is now one function-local object, and a two-translation-unit
  failure-injection probe asserts that a failure is reported and that the process exits
  non-zero.
- **The setters advertised as queued, thread-safe and realtime-safe wrote biquad and
  smoother state that the audio thread was reading and writing per sample.** There is
  now a real queue: a bounded, lock-free, triple-buffered mailbox that publishes one
  complete immutable configuration.

The remaining eighteen findings are P2/P3 correctness, boundary and cleanup defects in
the same engine. No struct layout changed and the protocol version is unchanged, so a
1.2.1 driver and a 1.2.1 Host still interoperate with the 1.2.0 layout.

### 3.5 Shared-memory API fails closed on an invalid mapping

`rf_is_connection_healthy()` compared four non-zero words, so a stale, foreign or
uninitialised mapping could report healthy because four unrelated values happened to be
set. It now gates on header validation, which also covers a null pointer. The volume
state readers reject a null mapping instead of dereferencing it, and the legacy
`rf_load_eq_snapshot()` is documented as leaving the snapshot untouched on a failed
read — for a zeroed snapshot that means 0 dB on every band — with callers pointed at
the safe variant.

### 3.6 Tests and validation tooling

- **Host realtime suites**: in-process coverage for the render path — the callback's
  realtime contract across the mapping, the EQ change detector, the DSP update and the
  output buffer; the diagnostic counters and the callback histogram; and soak runs that
  keep churn and concurrency going long enough for a leak, a drift or a stuck state to
  appear. No device, driver or installed app is needed.
- **Hardware validation harness** (`tools/hardware-validation/`): out-of-process tools
  — device and format inventory, per-window callback timing, driver counters read from
  the live mapping through a read-only mmap, operator markers, and the result JSON and
  Markdown a run is reported from. The shipping code was not changed to produce
  evidence. See §4.2 for the one run that has been performed and what its own verdict
  was.
- **Release guard**: the shipped bundle is now checked for the license files in §3.7,
  so a bundle assembled by hand or by an older script fails verification instead of
  being published.
- Four one-off PoC probes under `tools/poc/` were deleted. Nothing referenced them; the
  measurements they produced live in the architecture, engineering and Known-Limitations
  documents, and `make protocol-check` still asserts the header layout on every build.

### 3.7 License, first time

1.2.0 was published without a license grant. From 1.2.1 the source **and the binaries
built from it** are licensed under the
[PolyForm Noncommercial License 1.0.0](../LICENSE): read, run, modify and share for any
noncommercial purpose; commercial use requires a separate written license. It is
source-available, not open source — the OSI definition forbids restricting field of use,
and this license does restrict it.

Every bundle now ships `LICENSE` and `THIRD_PARTY_NOTICES.md` in
`SoundBridge.app/Contents/Resources/`. The notices reproduce the license text of the
components that are linked into the artifacts: libASPL (MIT, plus the two Apple
sample-code licenses for the files it derives from) and Sparkle (MIT, with the external
licenses the project lists). The test-only dependencies are not linked into anything
that ships and are named as such.

Using 1.2.1 means accepting those terms. Releases up to and including 1.2.0 were
published without a grant and are not retroactively covered.

---

## 4. Verification

### 4.1 Automated

Run on the release commit, on the validation machine (macOS 27.2.1, arm64, SIP and
Gatekeeper both enabled). `make test` exited 0.

| Suite | Result |
|---|---|
| Host (XCTest) | 411 tests, 10 skipped, 0 failures |
| App (XCTest) | 298 tests, 0 failures |
| DSP (CTest) | 1 target, 100% passed |
| Driver (CTest) | 3 targets, 100% passed |
| Install transaction | 168 scenarios, 0 failed |
| Uninstall lifecycle (real script, sandbox root) | 99 assertions, 0 failed, 0 skipped |
| Unsigned release policy | 97 checks, 0 failures |
| Release payload (damage cases) | 244 assertions, 0 failed |

The uninstall suite executes `tools/uninstall_driver.sh` for real against a temporary
root, so removal, idempotence, refusals, the bounded Host stop with `SIGKILL`
escalation and the IPC scope are covered without touching the machine.

### 4.2 Hardware realtime run — one run, and it is not a pass

A single end-to-end observation on a real link was performed on 2026-11-23: default
output switched to the proxy device, real test tone played through it, 30 minutes of
per-window collection, a CPU-load window in the middle, then restore and quit.

| Field | Value |
|---|---|
| Device | `PHL 279M1RV (SoundBridge)`, 48 000 Hz / 512 frames, one format for the whole run |
| Windows | 180 × 10 s |
| Callbacks | 169 686; observed 93.7–93.8/s against an expected 93.75/s |
| Deadline | 10 666.7 µs per window; `overBudget` summed over all windows = 0 |
| Latency | p99 72–74 µs, max 322 µs |
| Underruns | driver underrun = 0, ring overrun = 0 (read-only mmap of the live mapping) |
| Load window | 4 × `yes` for 300 s, covering 31 windows / 29 531 callbacks; `overBudget` still 0 |

**The harness verdict for that run is `INCOMPLETE — REQUIRED HARDWARE EVIDENCE
MISSING`, and it must be quoted that way.** Two of its own criteria were never
exercised: host/device recovery (no hotplug or degraded event occurred, and the H8
scenario was not marked) and the in-run default-output restore marker. `p99.9` is not
observable at all: the timing snapshot exposes p50/p95/p99/max only. So this run
supports "no callback exceeded its deadline under this load, on this device, at this
format", and nothing beyond that.

Teardown was recorded separately after the run: the app quit normally, the Host exited
with it within ~3 s, both proxy devices disappeared (7 devices → 5, zero proxies), both
mappings and the device control file were removed by the app and Host themselves, the
default output was still the physical display (`PHL 279M1RV`, device id 124,
48000 Hz / 512 frames) and was re-verified by an independent read-back, and neither
`coreaudiod` (pid 48791) nor the driver process (pid 48806) restarted at any point. No
crash reports were written in the surrounding window.

The registration of this run, with the identical numbers, is §2C of
[Known limitations](risks/Known-Limitations.md).

### 4.3 The three fixes, on the validation machine

Each of the three defects in §3.1–§3.3 was reproduced against 1.2.0's behavior, then
checked with 1.2.1 built from this commit and run on the validation machine:

- **OBS-1** — with no I/O client and the proxy *not* the default output, a volume write
  of 0.55 (which the device quantises to 0.5625) advanced `state_revision` 2 → 3, left
  0.5625 in the shared-memory volume field and in `volume-state.json`, and was still
  0.5625 after an app restart. Mute in the same conditions set `mute_state` = 1 and
  advanced the revision 3 → 4.
- **OBS-2** — Bass 11.7 dB → 4.9 dB was stored as 4.913412 under the device's single
  dictionary key, and the panel still showed 4.9 dB after quitting and reopening the
  app.
- **OBS-3** — running `tools/uninstall_driver.sh` for real reported files removed, no
  Host running, zero IPC files left, receipt kept, and `coreaudiod` never signalled,
  exiting 0; neither the helper process nor `coreaudiod` restarted and audio was not
  interrupted. Reinstalling with the published 1.2.0 PKG then restored the driver, the
  proxy device and its volume.

These are observations from one machine, recorded by hand, not an automated suite.
The automated coverage that sits behind them is in §4.1.

---

## 5. Still unverified

Stated as gaps, not as "works but untested":

- **Sample rate and buffer size matrix** — 44.1 / 96 kHz and 128 / 256 / 1024 frames
  were never run. Everything in §4.2 is 48 kHz / 512 frames.
- **Device removal and re-enumeration while playing** (H8) — not executed. Same status
  as U-1 in [Known limitations](risks/Known-Limitations.md).
- **Audible symptoms under load** — no human listener confirmed absence of clicks or
  dropouts. The counters say the callbacks met their deadline; they do not say what it
  sounded like.
- **p99.9 latency** — not observable with the current timing snapshot.
- **Hot state and CPU readings** — no resolution: `pmset -g therm` recorded nothing and
  the CPU column reads 0.0%.
- **The double-click PKG path through the Gatekeeper approval dialog** — installation
  was driven from the `installer` command line; the dialog sequence is documented from
  Apple's instructions, not measured.
- **Intel Macs and macOS 13/14** — universal binaries are produced; only Apple silicon
  on macOS 27.2.1 has been run.
- **Multi-device concurrency** and sessions longer than 30 minutes.
- **Playback-time volume behavior with `driver_connected = 1`** — §4.3 covers the no-IO-
  client case, which was the defect; the ordinary case worked at 1.2.0 and is unchanged.
- **PKG/DMG byte reproducibility** — packaging is not reproducible even though the
  binaries are (OBS-4, unchanged).

---

## 6. Known limitations that carry over

Unchanged from 1.2.0 unless stated above; the full record is
[Known limitations](risks/Known-Limitations.md).

- The distribution is completely unsigned and not notarized. Gatekeeper rejects it by
  design; you approve it once per artifact in **System Settings → Privacy & Security**.
  There is no Developer ID and no auto-update channel: no EdDSA key, no appcast, and
  `SUPublicEDKey` is empty.
- The uninstaller does not delete the PKG receipt or installer state, and does not
  restart `coreaudiod` (B-2).
- The read-back tolerance of one raw step applies to the SoundBridge proxy only (B-3).
- Downgrading to 1.2.0 reads stale EQ values (B-1).

---

## 7. Install and uninstall

[INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md) covers download verification, install,
the one-time Gatekeeper approval, troubleshooting, uninstall and rollback.

Menu bar → **Uninstall Driver** runs the four-phase uninstaller described in §3.3.
`tools/uninstall_driver.sh --dry-run` prints the plan and changes nothing.

---

## 8. Release verdict

1.2.1 fixes the three defects it targets, and their fixes are covered by automated
suites and by hand on one machine. The DSP audit is closed. The known gaps are listed
in §5 and are the same class as 1.2.0's: interaction with hardware and formats that
have not been tried.

It is **not** a claim that the audio path has been measured, that every supported
format works, or that anything beyond one arm64 machine has been validated.
