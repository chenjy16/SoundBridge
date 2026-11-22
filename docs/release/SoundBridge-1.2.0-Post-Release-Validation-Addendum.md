# SoundBridge 1.2.0 — Post-Release Validation Addendum

**Status**: post-release record · **Date**: 2026-11-22 · **Applies to**: release `v1.2.0` (published 2026-11-21)

This document records what was verified **after** the 1.2.0 release assets were
published, by downloading those assets from GitHub and using them on a real
machine. It does not modify the released artifacts, and it does not rewrite the
results recorded in the
[Final Release Report](SoundBridge-1.2.0-Final-Release-Report.md). Where the two
differ, this addendum states the newer observation and says so explicitly.

Authority for hashes, log references and raw measurements is the Final Release
Report. This addendum is the short, quotable summary of its post-release half.

---

## 1. Why this addendum exists

At the moment 1.2.0 was built and published, two questions were still open in the
shipped documents:

| Question | Where it stood at release time |
|---|---|
| Will macOS load an **unsigned** HAL driver? | `NOT_VERIFIED` — `INSTALLATION_GUIDE.md` §5.3 and `RELEASE_NOTES.md` §5 said it had to be confirmed on the target machine |
| Does the **publicly downloadable** package install and produce audio? | `NOT_VERIFIED` — validated only on locally built artifacts |

Both were answered afterwards on the release validation machine. The answers are
recorded here, and the still-open questions are listed in §9 so that "verified"
is never read as "everything verified".

---

## 2. Validation environment

| Item | Value |
|---|---|
| Machine | Mac mini, Apple silicon (arm64) |
| macOS | 27.2.1 (build `26B131`) |
| SIP | **enabled** (`csrutil status` = enabled, never disabled during the run) |
| Gatekeeper | **enabled** (`spctl --status` = assessments enabled) |
| Developer ID signature | none |
| Ad-hoc signature | none produced by this project |
| Apple notarization | none |
| Install method | `installer` command line (see §9 for what that does *not* cover) |
| Toolchain | Apple clang 21.0.0, Apple Swift 6.4.2, Xcode 27.2, CMake 4.2.1 |

The only signature material present in the artifacts is the linker-written
CodeDirectory (`flags=0x20002(adhoc,linker-signed)`) that `ld64` adds to every
Mach-O, plus the upstream ad-hoc seals inside `Sparkle.framework`. Neither is a
Developer ID signature, and neither is evidence that Gatekeeper accepts the
software.

---

## 3. Public download integrity

The assets were downloaded from
`https://github.com/chenjy16/SoundBridge/releases/tag/v1.2.0` and hashed locally.
All four files matched the authoritative local hashes recorded in the Final
Release Report §3.

| Asset | Size (bytes) | SHA-256 | Result |
|---|---|---|---|
| `SoundBridge-1.2.0.pkg` | 14,362,287 | `2bf224605b4ecbcfbbf7253ba0bfc426fcaab96aee3e35623059dbdb86635a6f` | identical |
| `SoundBridge-1.2.0.dmg` | 14,943,486 | `2c78d502c54d20dc4764843e5e1fbfa3c64daab2ad07fdc4943dffca8df643e7` | identical |
| `SHA256SUMS.txt` | 176 | `539180fbe8aa1e7f2dcd94370281aebf3514b2dda746fbe419a32a4f08f3324f` | identical |
| `INSTALLATION_GUIDE.md` | 18,074 | `01ad029bedb299e548f266a99a901d251b1a9072502b0319f9194f6561b9a782` | identical |
| `RELEASE_NOTES.md` | 18,441 | `21d8105e54b5efd14be36516ae590ea76031895932dfb137488b121b7bebf34a` | identical |

`shasum -a 256 -c SHA256SUMS.txt` passed for every listed file. The GitHub API
reports the same digests for the uploaded assets, so download, storage and
publication agree.

---

## 4. Installation and payload integrity

The downloaded PKG was installed with the `installer` command. Two independent
comparisons were then made:

| Comparison | Method | Result |
|---|---|---|
| Installed app vs. package payload | file-by-file byte comparison | **109 / 109 files byte-identical** |
| Installed driver vs. driver embedded in the app | SHA-256 of the binary and the bundle contents | **identical** |

Installed locations:

- app: `/Applications/SoundBridge.app`
- driver: `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver`

No file outside those two paths was written by the installer apart from the
expected PKG receipt. Rollback was not triggered in this run.

---

## 5. Unsigned HAL driver loading

This is the result that changes a `NOT_VERIFIED` statement in the shipped
documents into a verified one — **on this machine only**.

After installation, `coreaudiod` was restarted to force a plug-in rescan
(`coreaudiod` PID 48791). Within 2 seconds it spawned:

```
HALS_RemotePlugInRegistrar.mm:423  Creating remote driver service ... pid: 48806
```

| Evidence | Observation |
|---|---|
| System log | `HALS_RemotePlugInRegistrar` created a remote driver service for `SoundBridgeDriver.driver` |
| Process table | `Core Audio Driver (SoundBridgeDriver.driver)` running as **PID 48806**, alive for the whole test |
| Driver log | `Mapped at … (size: 65856)`, `Connected on attempt 1`, `Volume state: adopted committed shared-memory value 0.8789 (rev 1)` |
| Heartbeat | driver-side heartbeat counter advanced continuously (1,952 → 176,398) |

Conclusion: with SIP and Gatekeeper both enabled, and with no Developer ID
signature, no ad-hoc signature of our own and no notarization, macOS 27.2.1 on
this arm64 machine **did** load the unsigned HAL driver.

**This does not generalise.** Unsigned plug-in loading is environment-dependent:
it has changed across macOS releases, it can be refused outright by
MDM-managed policies, and it has not been tested on any other macOS version, on
Intel hardware, or on a managed device. See §10.

---

## 6. Functional verification

### 6.1 Playback

| Item | Observation |
|---|---|
| Sustained frame rate | **47,996 frames/second** (≈47.8k), i.e. full 48 kHz throughput |
| Audible output | confirmed by the person running the test (human listening, not instrumentation) |
| Signal path | apps → proxy device → driver → shared-memory ring → Host → DSP → physical HDMI output |

### 6.2 Volume and mute

Volume was set through the system (`osascript set volume output volume N`), which
is what the user actually operates, and the value written into shared memory was
read back:

| Requested | Committed `volume_scalar` | Expected from taper `dB = 48·√s − 48` |
|---|---|---|
| 60 | 0.5942 | 0.5942 |
| 20 | 0.1914 | 0.1914 |
| 88 | 0.8789 | 0.8789 |

Mute and unmute were exercised in both directions through the same path and took
effect. One observation is recorded in `Known-Limitations.md` as **OBS-1**: when
no I/O client window is open, a volume or mute write may fail to commit; in both
occurrences, re-setting the value during playback worked. That is a write-commit
observation, **not** an inability to control volume.

### 6.3 Runtime EQ

| Item | Observation |
|---|---|
| Sequence counter | `eq_seq` advanced 0 → 2 → 4 → 6 → 8 → 10, monotonically, one step per UI change |
| Band gains | all ten bands matched the requested values (+8 dB / 0 dB / −8 dB) |
| Weighting | the three macro controls (Bass, Mids, Treble) produced the expected 3 × 10 weight distribution |

**Scope of this result**: EQ *adjustment at runtime* works. EQ *persistence* does
not — slider values set in a session are not stored, and after a restart the
sliders return to the previously stored value. This is recorded as **OBS-2** and
is a P1 fix item. Runtime behaviour must not be cited as evidence that
persistence works.

### 6.4 Host shutdown and restart recovery

| Scenario | Result |
|---|---|
| `SIGTERM` to the Host during playback | orderly shutdown: render loop stopped, output device released, shared memory unmapped, control file removed, no orphaned process |
| IPC resources | reclaimed; no leaked shared-memory file or lock |
| App quit → relaunch | a new session was created, the driver reconnected automatically on the **first** attempt (`Connected on attempt 1`), and playback resumed without reinstalling anything |
| `coreaudiod` restart | driver re-registered; the Host re-established the mapping |

---

## 7. Continuous playback stability (31 minutes)

One uninterrupted playback run, sampled every minute:

| Metric | Value |
|---|---|
| Duration | **31 min 01 s** (1,861 s) |
| Frames written | **89,320,455** (1,823,990 → 91,144,445), = 47,996 frames/s |
| Underruns | baseline 6,470 before playback → **constant 6,487** across 30 consecutive sample points (min 01 … min 30). **Zero growth during playback** |
| Overflow (ring `Drop New`) | **0** |
| Format mismatch | **0** |
| Render callbacks over budget | **0** of 198,286 (p50 32 µs, p95 68 µs, p99 74 µs, max 170 µs) |
| Host RSS | 18,640 KB → 15,616 KB — no growth |
| Driver helper | PID 48806 alive for the entire run |
| Audio dropouts heard | none reported by the tester |

Notes on reading these numbers:

- The 6,487 underrun baseline is an **artifact of the idle period before playback
  started** (a producer-only period with no consumer). The metric that matters is
  that it did not increase while audio was playing. After playback ended, the
  counter resumed growing during the idle period — also expected.
- These are measurements from one machine, one configuration, one 31-minute run.
  They are evidence that the release works; they are not a performance guarantee
  for other configurations, other buffer sizes, or longer runs.

---

## 8. What changed in the documentation as a result

| Document | Change |
|---|---|
| `INSTALLATION_GUIDE.md` §5.3 | **Not edited.** It is a published asset with a fixed digest; its "unsigned driver loading is unverified" statement was correct when written. Current status is recorded here and in `Known-Limitations.md` U-17 |
| `RELEASE_NOTES.md` §4.1 / §5 | **Not edited.** Same reason. Current status: this addendum + `Known-Limitations.md` §2A |
| `docs/risks/Known-Limitations.md` | U-17 moved from `NOT_VERIFIED` to `VERIFIED — single machine, limited environment`; §2A added with the six post-release items (OBS-1 … OBS-4, K5c, G-UI) |
| `docs/README.md` | §4 records the two frozen assets and points at the current status; §5 carries the layered verification table |
| `README.md` | "Verification status" section rewritten: verified vs. not yet verified, no compatibility promises |

---

## 9. Not tested in this round

Two scenarios were **not** exercised. They must not be reported as passing:

| ID | Scenario | Why it is untested | Consequence |
|---|---|---|---|
| **K5c** | Device removal and re-enumeration (unplugging HDMI/DP while audio is playing, then re-plugging) | Skipped by the tester in this round | Behaviour on hot-unplug is unknown: whether the Host falls back, whether the proxy device disappears and reappears, and whether the ring is re-created cleanly have not been observed |
| **G-UI** | Double-clicking the PKG through the Gatekeeper GUI approval dialog | The release was installed with the `installer` command line | The **package contents** and the install transaction are verified; the **GUI approval flow** (System Settings → Privacy & Security → Open Anyway, or right-click → Open) is not |

`installer` on the command line bypasses the Gatekeeper user-interaction path
entirely. That is a deliberate choice for a reproducible test, but it means the
experience of an ordinary user double-clicking the PKG remains unverified.

Additional untested areas, unchanged from the release:

- macOS versions other than 27.2.1, and any Intel Mac (the binaries are
  universal; only arm64 has been executed).
- Multi-display concurrency, buffer sizes below the default, and high-load
  conditions.
- Playback longer than 31 minutes.
- EQ persistence across restarts (known broken — OBS-2).

---

## 10. Limits of these results

1. **One machine, one day.** Every number here comes from a single Mac mini on
   macOS 27.2.1. Nothing in this addendum states or implies that another macOS
   version, another Mac model, or a managed device will behave the same way.
2. **Unsigned distribution is the intended state.** Gatekeeper rejecting the app
   and the package (`spctl` → `rejected / source=no usable signature`) is the
   expected verdict, not a defect. Users are not asked to disable Gatekeeper or
   SIP.
3. **Loading an unsigned HAL driver is environment-dependent.** A successful load
   here is an observation, not a compatibility claim. Organisational policy may
   forbid unsigned software entirely, in which case this release cannot be
   installed.
4. **"Verified" is scoped.** Where this document says verified, it means the
   listed check was performed on this machine and produced the stated result. It
   does not mean the feature is free of the issues recorded in
   `Known-Limitations.md`.
5. **No release asset was rebuilt or re-uploaded.** The hashes in §3 are of the
   artifacts published on 2026-11-21, unchanged.

---

## 11. References

| Document | Role |
|---|---|
| [SoundBridge-1.2.0-Final-Release-Report.md](SoundBridge-1.2.0-Final-Release-Report.md) | **Authoritative record**: hashes, log file names, raw measurements, final verdict |
| [SoundBridge-1.2.0-Release-Checklist.md](SoundBridge-1.2.0-Release-Checklist.md) | §10 release back-fill, §11 driver-load evidence ladder (L1–L7) |
| [../risks/Known-Limitations.md](../risks/Known-Limitations.md) | §2A post-release register (OBS-1 … OBS-4, K5c, G-UI), U-17 status, L-13 unsigned policy |
| [../INSTALLATION_GUIDE.md](../INSTALLATION_GUIDE.md) | Install / uninstall / rollback (frozen 1.2.0 asset) |
| [../RELEASE_NOTES.md](../RELEASE_NOTES.md) | 1.2.0 change list (frozen 1.2.0 asset) |
