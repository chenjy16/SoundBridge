# SoundBridge — Product Roadmap and Specification

**Status:** Product direction proposal

**Baseline inspected:** repository `main`, HEAD `3101abc`; latest release tag `v1.2.1`

**Planning horizon:** release sequence is a hypothesis, without committed dates

> This document establishes a proposed product direction from the repository
> state inspected on 2026-11-24. Repository evidence, product decisions,
> hypotheses, and open questions are labelled separately. A capability listed as
> planned is not an implemented feature.

## 1. Executive Summary

SoundBridge should become **system-wide audio enhancement for macOS**, centered
on its own DSP Engine. Its product value should come from practical sound
improvement, personalization for a user's output devices, and easy switching
between listening profiles.

The product will retain the existing CoreAudio HAL Driver → Shared Memory / SPSC
Ring Buffer → Host → DSP Engine path. The current app and driver already provide
system-wide software volume for fixed-volume outputs, mute, device selection,
and a 10-band DSP engine presented through three tone controls. The product does
not yet expose the DSP Engine's full parameter surface or a user-facing preset
manager.

The roadmap is Free + Pro: essential system-wide processing stays in Free,
while advanced processing and personalization are Pro candidates. Pro packaging
remains undecided. The sequence is to stabilize and validate the current audio
path; make the DSP Engine's existing parametric EQ usable; evaluate further
DSP; add measurement-profile support only with clear data and licensing terms;
then build device and listening profiles. Features remain proposals until they
pass technical and user validation.

## 2. Vision and Positioning

### 2.1 Vision

Help Mac users get more predictable, comfortable sound from the headphones and
speakers they already own, across all system audio, through dependable DSP and
personalized profiles.

### 2.2 Positioning

**SoundBridge — System-wide Audio Enhancement for macOS.**

Suggested description:

> SoundBridge is a customizable audio processing engine for macOS that enhances
> system-wide sound through professional DSP, personalized audio profiles, and
> headphone and speaker calibration.

This is a proposed positioning statement, not a claim that all named features
are implemented today. The current shipped product is narrower: system-wide
volume/mute handling for fixed-volume outputs and a 10-band tone stage with a
basic menu-bar interface.

### 2.3 Product Principles

1. **Sound quality is the product center.** Every feature should make audio
   quality, personalization, or reliable everyday use better.
2. **Protect the working audio path.** Stability, compatibility, audio
   correctness, and real-time safety come before breadth.
3. **Preserve essential utility in Free.** System-wide processing, basic EQ,
   device selection, and core maintenance must not be artificially paywalled.
4. **Pro adds meaningful depth.** Paid features should offer capabilities users
   can understand and value, not restrictions on the existing product.
5. **Measure before claiming.** Distinguish DSP tests, build evidence, hardware
   measurements, listening feedback, and automatic calibration.
6. **Keep the experience approachable.** SoundBridge is not a DAW or studio
   mastering suite.
7. **Prefer maintainable capabilities.** Include external datasets, OS support,
   support load, licensing, and release friction in feature decisions.

## 3. Scope and Product Boundaries

### In scope

- System-wide audio enhancement through the existing Driver and Host path.
- Basic gain staging, EQ, and safe clipping protection.
- A progressively more configurable parametric EQ.
- Curated and user-created DSP presets.
- User-imported correction curves and output-device-specific DSP settings,
  subject to format, provenance, and licensing review.
- Music, Movie, Gaming, Voice/Meeting, and custom listening profiles, subject to
  demand and implementation evidence.
- Device-aware profile selection based on reliable output-device events.
- Audio diagnostics that explain processing state and measured behavior.

### Out of scope

- Per-application volume or mute.
- Per-application EQ, capture, processing, routing, or Process Tap management.
- Aggregate Device-based architecture migration.
- Migration to a Process Tap-based architecture.
- Replacing the existing audio topology to enable per-application features.
- A professional DAW, studio mastering workflow, or general-purpose virtual
  audio device manager.
- Measurement-based automatic calibration claims until the complete measurement
  workflow, supported hardware, validation method, and user experience exist.

These boundaries apply regardless of feature naming or Free/Pro tier. If a
future product strategy review changes one, the architecture and roadmap must
be reviewed explicitly before implementation is proposed.

## 4. Existing Architecture and Constraints

### 4.1 Verified architecture

```text
macOS system audio
       |
       v
CoreAudio HAL AudioServerPlugIn (SoundBridge Driver)
       |
       v
Shared Memory / SPSC Ring Buffer
       |
       v
SoundBridge Host
       |
       v
SoundBridge DSP Engine
       |
       v
Physical output device
```

The architecture uses the current user-space HAL Driver, Host process, shared
memory protocol, single-producer/single-consumer ring buffer, and in-tree DSP
Engine. The app manages device selection, volume/mute state, basic EQ controls,
onboarding, diagnostics, and persistence. See
[architecture documentation](../architecture/SoundBridge-1.2.0-Architecture.md),
[ring-buffer design](../engineering/RingBuffer-Design.md), and
[shared-memory lifecycle](../engineering/SharedMemory-Lifecycle.md).

This architecture is a product constraint and the foundation of the proposed
roadmap. The DSP Engine is a strategic product asset; replacing it with a
third-party engine is not planned.

### 4.2 Current engineering constraints

- Real-time callbacks must remain bounded and must not block, allocate, log
  synchronously, or perform file/network I/O.
- Control updates need safe publication from the control plane to the audio
  thread. The DSP Engine uses a bounded configuration mailbox and applies
  snapshots at block boundaries.
- The current DSP contract is stereo Float32, interleaved or planar in its API;
  the Host's canonical shared transport is stereo Float32 interleaved.
- The Driver currently converts supported HAL stream formats before writing to
  the ring. Float64 input is documented as fail-closed in the architecture and
  known-limitations records.
- DSP work must measure CPU cost, callback deadline headroom, latency, behavior
  at supported sample rates/buffer sizes, and numerical edge cases.
- The product currently ships unsigned, non-notarized builds with no automatic
  update channel; installation friction is a commercial and support constraint.

### 4.3 Repository inspection snapshot

The inspected checkout is on `main` at `3101abc`, with latest existing tag
`v1.2.1`. At inspection time, the working tree also had modified
`packages/driver/CMakeLists.txt`, modified `packages/driver/src/Plugin.cpp`,
and untracked `poc/` content. Those local changes were preserved and were not
treated as released or verified product capabilities. The release tag and
release notes are the baseline for shipped claims; current source and tests
inform implementation status. No live audio experiments or tests were run for
this document.

## 5. Existing Product Capability Audit

Evidence labels: `SOURCE_VERIFIED` means the code or repository docs show the
implementation; `TEST_VERIFIED` means an automated suite covers the claim;
`REAL_MACOS_VERIFIED` is limited to the recorded machine/configuration;
`NOT_VERIFIED` means no evidence was found. A test pass is not hardware proof.

| Capability | Current evidence-based state | Classification |
|---|---|---|
| System software volume for fixed-volume display outputs | Per-display proxy device and software volume path; 48 dB range in 1 dB steps. Hardware evidence is limited to recorded configurations. | EXISTING |
| System mute and reported-value UI | App writes and reads back the proxy value; 1.2.1 release notes record the idle write fix. Broader hardware matrix remains open. | EXISTING / IMPROVEMENT |
| Physical output selection | Menu-bar device list and explicit output switching; app does not take the default output on its own. Hot-plug matrix is incomplete. | EXISTING / IMPROVEMENT |
| System-wide EQ | In-tree 10-band parametric engine with seven filter types; current UI presents Bass/Mids/Treble macros and Reset. Settings persist per output device in app storage. | EXISTING |
| EQ engine preamp and limiter | DSP API supports preamp and optional soft limiter; engine processing and unit tests exist. Current app does not expose the full control surface; product-level activation/default behavior must be traced and validated before describing it as a user feature. | EXISTING engine / NEW user capability |
| User-facing EQ presets | No app workflow to create, save, list, or apply presets is documented; README explicitly says presets are not supported. DSP preset data/API is not a user preset manager. | NEW |
| Dynamic EQ, compressor, loudness compensation, bass enhancement | No implemented product capability identified in the inspected app/DSP feature surface. Treat each as a separate feasibility proposal. | NEW / EXPERIMENTAL |
| Headphone/speaker correction profiles | No user-facing profile library or correction import flow identified. | NEW |
| Output-device-specific basic EQ | Existing app persists EQ per output device. This is a foundation, not automatic calibration. | EXISTING |
| Listening profiles and automatic switching | No profile manager or scenario-based switching identified. Existing device selection events may provide a future trigger after reliability validation. | NEW |
| Audio analysis UI | DSP diagnostics include processing stats and peak data internally; no user-facing analyzer product identified. | NEW |
| Diagnostics and recovery | Logging, shared-memory probe, lifecycle reporting, and recovery controls exist; behavior and coverage have documented limitations. | EXISTING / IMPROVEMENT |

The current menu-bar UI is a compact, roughly 300-point-wide panel with device
header, conditional volume/mute control, Basic EQ, device list, reconnect/restart
actions, status, and footer. It is not yet the multi-section sound-customization
workspace proposed below. The existing UI should evolve in small steps, keeping
the current quick controls accessible.

### 5.1 Important open reliability gaps

The current [Known Limitations](../risks/Known-Limitations.md) register is the
source of truth. As recorded there, priority evidence gaps include real device
removal/re-enumeration while playing (U-1), broader sample-rate/buffer and long
run coverage (U-6/U-7), macOS-version and Intel hardware coverage (U-3/U-5),
Host crash/re-attach and `/tmp` cleanup scenarios (U-11/U-12), HAL sandbox file
access (U-13), and remaining Driver callback real-time violations (RT-1–RT-5).
OBS-1/OBS-2 were addressed in 1.2.1; their full hardware acceptance matrix is
still distinct from the code and automated test evidence.

## 6. Target Users and Use Cases

| User group | Pain point | Desired outcome | Highest-value first capability | Free-to-Pro hypothesis | Architecture fit |
|---|---|---|---|---|---|
| Everyday Mac listeners | Built-in controls do not provide a consistent way to shape all system audio. | A simple, reversible improvement in sound, without app-by-app setup. | Basic system EQ, a few useful presets, reliable bypass. | Advanced controls and profile library may justify Pro after user research. | Direct fit: one system-wide path. |
| Headphone enthusiasts | Different headphones have different tonal balance; settings are scattered or hard to tune. | Apply a known correction curve and adjust to personal preference. | Importable headphone correction and parametric editor. | Large curated/profile tools and advanced adjustments are plausible Pro candidates. | Fits as DSP configuration; profile data and UI are new. |
| Users switching headphones and speakers | One EQ does not suit every output. | Keep settings tied to output devices and switch reliably. | Device-specific profiles, building on existing per-device EQ persistence. | More saved profiles, profile compare, and correction tools may be Pro. | Device-change events already exist; automatic selection reliability must be proven. |
| Scenario-based listeners | Music, films, games, and calls benefit from different tonal settings. | Switch profiles quickly and understand which is active. | Manual named profiles first. | Advanced profile organization and custom curves may be Pro. | System-wide profile state; no app identification needed. |
| Users seeking more than macOS Sound settings | macOS controls do not expose a customizable DSP chain. | Transparent, low-friction sound controls and reliable setup. | Clear status, basic EQ, device controls, safe bypass. | More advanced DSP only after usefulness is demonstrated. | Fits the current virtual-device path. |

Do not target professional recording engineers or mastering workflows without
validated support for their monitoring, latency, routing, measurement, and
workflow requirements.

## 7. Product Pillars and Feature Classification

Priority: `P0` reliability prerequisite, `P1` first product expansion, `P2`
later candidate, `Research` feasibility/user validation required. Effort: `S/M/L/XL`
is a relative solo-developer estimate, not a schedule. Free/Pro labels are
candidate placement only. All acceptance criteria below are gates, not claims
of current support.

### Pillar A — Professional DSP

| Feature / classification | User problem and value | Current status and dependencies | Effort / RT risk | Priority / tier candidate | Acceptance criteria |
|---|---|---|---|---|---|
| Basic system gain and volume / EXISTING | Users need consistent level control on fixed-volume outputs. | System volume path exists; DSP preamp is separate and not currently a surfaced control. | S / Low for existing volume; DSP preamp adds parameter-state work. | P0 / Free | Existing volume path passes idle, playback, restart, device-switch, and hardware checks; any preamp control has bounded range, smoothing, persistence, and bypass. |
| Basic EQ / EXISTING | Adjust overall tonal balance without technical setup. | 10-band engine; UI exposes three macro controls and reset. | S / Low-medium | P0 / Free | Gain changes are smooth and repeatable, survive relaunch/device recovery, and match documented filter behavior; audio quality checked with test signals and listening. |
| User-facing EQ presets / NEW | Users want a starting point and a repeatable saved sound. | No user preset CRUD/apply workflow. DSP preset struct/API is not sufficient UX. | M / Medium | P1 / Free basic set | Create/apply/rename/delete/import-safe presets; defaults available offline; invalid data rejected; preset changes are atomic and persist. |
| Parametric EQ editor / NEW | Enthusiasts need frequency, gain, Q and filter type control. | Engine already supports ten bands and seven filter types; app model/UI and validation needed. | L / Medium | P1 / Pro candidate; keep meaningful basic EQ free | Edit frequency/gain/Q/type/enabled; enforce engine ranges; preview safely; bounded updates; verified frequency-response tests and responsive UI. |
| Limiter / EXISTING engine, NEW product control | EQ boosts can create peaks above full scale. | Optional soft limiter exists in DSP; app-level controls and whole-path clipping acceptance need confirmation. It is not look-ahead. | M / Medium | P0 protection / Free candidate | Document threshold and behavior; show/choose safe default; test overload, transients, non-finite values, and bypass. No claim of transparent peak limiting beyond evidence. |
| Bass enhancement / NEW | Users want more low-frequency body on small speakers/headphones. | No dedicated enhancement module identified; can begin as a documented low-shelf preset, not a new opaque algorithm. | S as EQ preset; M for dedicated DSP / Medium | P2 / Free preset or Pro control | Defined response and gain limits; no unbounded boost; validated against clipping and output device limitations. |
| Compressor / EXPERIMENTAL | Users want to manage dynamic range for quiet/variable content. | No compressor identified. Requires detector, attack/release, ratio/knee design, parameter publication, and latency/quality study. | L / Medium-high | Research / Pro candidate | Offline reference vectors, attack/release behavior, stability, CPU/deadline budget, and listening review pass before product commitment. |
| Dynamic EQ / EXPERIMENTAL | Users want frequency-selective correction that adapts to signal level. | No detector-linked EQ implementation identified; materially more complex than static EQ. | XL / High | Research / Pro candidate | A concrete target use case, stable detector behavior, bounded CPU, no pumping/zipper artifacts in defined scenarios, and comparative user value demonstrated. |
| Loudness compensation / EXPERIMENTAL | Tonal balance changes at low playback levels. | No loudness-compensation feature identified. Depends on volume reference, target curve, and safe coupling to output level. | L / Medium-high | Research / Pro candidate | Behavior defined against level, not app identity; user-adjustable or clearly bounded; equal-loudness/reference method documented; blind or structured listening review. |
| Channel balance / IMPROVEMENT candidate | Some users need left/right level correction. | DSP supports stereo processing but no dedicated balance UX identified. | M / Medium | P2 / Free or Pro after demand evidence | Center remains unchanged; range and channel mapping correct; no unintended phase or routing effects. |
| Stereo width/spatial enhancement / EXPERIMENTAL | Some users seek a wider image. | No validated algorithm identified; mono compatibility and localization risks. | L / High | Research / Pro candidate | Demonstrate benefit on representative content, mono fold-down safety, bounded width, and no channel inversion surprises. |
| Audio analyzer / NEW | Users cannot see processing level or clipping. | Internal DSP peak/CPU diagnostics exist; no user-facing analysis UI. | M / Low-medium | P2 / Pro candidate | Displays finite, correctly labelled pre/post levels and status; sampling does not add callback blocking or excessive CPU. |

### Pillar B — Headphone and Speaker Calibration

Calibration terminology is deliberately precise:

1. **Apply a predefined correction:** load an existing profile/curve and map it
   to the EQ engine. This is not SoundBridge measuring a device.
2. **Import a measurement-based curve:** accept a known external format and
   metadata; this still relies on someone else's measurement and target.
3. **Measure the user's device:** requires a measurement method and suitable
   microphone/fixture or other data source, repeatable environment, and error
   handling.
4. **Automatic calibration:** estimates correction from the user's own measured
   response and applies it. This is a separate product and engineering problem.

Only stages 1–2 are plausible within this roadmap's current architecture without
new measurement hardware. Stages 3–4 remain out of scope unless separately
approved after a designed and validated workflow.

| Feature / classification | User problem and value | Current status and dependencies | Effort / risk | Priority / tier candidate | Acceptance criteria |
|---|---|---|---|---|---|
| Output-device EQ persistence / EXISTING | A speaker and headphones should not share unsuitable settings. | EQ settings are persisted per output device; automatic matching quality and recovery need broader evidence. | S / Medium lifecycle risk | P0 / Free | Two or more output devices retain independent settings through switch, app relaunch, Host restart, and reconnect. |
| User-defined correction curve / NEW | User wants a known EQ curve applied to a chosen output. | No user correction-profile workflow. Depends on stable curve schema, mapping to ten bands, validation, and provenance. | M / Medium | P1 / Pro candidate; basic custom EQ remains Free | Curve conversion is deterministic, response error bounded and documented, invalid/unsupported curves rejected with explanation. |
| AutoEQ-compatible import / EXPERIMENTAL | Users want access to existing headphone measurements. | External dataset/format compatibility and licensing need investigation; no import implementation. The AutoEQ ecosystem is a candidate dependency, not an endorsement or license grant. | L / Medium | P2 / Pro candidate | Confirm source terms and attribution; support a documented subset; test representative files; display measurement/source and target metadata; no claim of calibration accuracy beyond source data. |
| Headphone model catalog / EXPERIMENTAL | Users want to find correction by device model. | Depends on a maintained, distributable data source, naming/variant matching, update approach, and licensing. | XL / Medium ongoing data cost | P2 / Pro candidate | Data rights confirmed; model/variant confidence surfaced; catalog can be updated without forcing a recurring service assumption. |
| Speaker correction profiles / EXPERIMENTAL | Users want output-specific correction for speakers. | Requires measured response sources or user-supplied curves; room response varies by placement/listening position. | L / Medium | P2 / Pro candidate | Clearly distinguish speaker model correction from room correction; source/target documented; no automatic room-calibration claim. |
| Custom target curve / NEW | Users want to choose their preferred tonal target. | EQ engine can represent filters; curve editor/conversion is new. | L / Medium | P2 / Pro candidate | Curve preview, safe bounds, deterministic conversion, and measured response error criteria defined. |
| Profile export/import/backup / NEW | Users want portability and recovery. | No general profile interchange format identified. Requires versioning, validation, and conflict policy. | M / Low-medium | P2 / Free export basics; advanced library tools Pro candidate | Round-trip preserves settings; schema versioned; malformed input cannot crash or alter unrelated preferences. |
| Automatic measurement/calibration / OUT_OF_SCOPE | User expects SoundBridge to measure and correct their actual setup. | No measurement workflow, hardware support, or validation program exists. | XL / High and external dependency | Excluded | Do not market or schedule until strategy review approves instrumentation, supported measurement setup, privacy, and accuracy criteria. |

### Pillar C — Intelligent Audio Profiles

Minimum viable management is named profiles containing a validated DSP state,
manual activation, active-profile indication, and persistence. Build this before
automation. Automatic selection may depend on output-device events only; never
on application identity.

| Feature / classification | User problem and value | Current status and dependencies | Effort / risk | Priority / tier candidate | Acceptance criteria |
|---|---|---|---|---|---|
| Music/Movie/Gaming/Voice starter profiles / NEW | Users want useful starting points for common listening situations. | No user preset/profile library; any bundled settings are new and require listening review. | M / Low-medium | P1 basic set / Free | Each profile has documented intent, safe output gain, clear names, one-click activation, and reset/bypass. Avoid promising genre-specific correctness. |
| Custom named profiles / NEW | Users want to save personal settings. | Requires profile schema, persistence, and import/export strategy. | M / Medium | P1 basic create/save / Free; advanced organization Pro candidate | Create, rename, duplicate, delete, apply; state is restored after relaunch; invalid values are rejected safely. |
| Quick profile switching / NEW | Users want low-friction use from the compact app. | Existing menu bar UI can host a small profile selector; state management is new. | S/M / Low | P1 / Free | Current profile visible; switching applies one coherent DSP snapshot; failed application leaves prior active state clear. |
| Output-device-specific profile mapping / IMPROVEMENT | Users need the right sound settings per output. | Per-device EQ persistence exists; mapping a profile to a device is new. | M / Medium lifecycle risk | P2 / Pro candidate | Mapping survives reconnect/rename where stable device identifiers permit; fallback is explicit; manual override wins predictably. |
| Automatic switch on output-device change / EXPERIMENTAL | Users do not want to select a profile each time they change outputs. | HAL/device-change infrastructure exists; real hot-plug and ordering reliability is incomplete. | M / Medium-high | P2 / Pro candidate | Only supported output-device events trigger; no oscillation; user override and failure fallback defined; full device matrix passes. |
| A/B profile compare / NEW | Users want to judge whether a correction helps. | No comparison UI or safe snapshot workflow. | M / Medium | P2 / Pro candidate | Fast level-matched compare; state always returns to a named profile; no audio gap or unsafe parameter churn. |
| App-triggered switching / OUT_OF_SCOPE | Some users want behavior tied to the foreground/playing app. | Requires application identification/control, explicitly outside product boundary. | — | Excluded | No implementation or proposal under another name. |

## 8. Free and Pro Strategy

### 8.1 SoundBridge Free — candidate definition

Free should remain useful for system-wide sound improvement and the existing
device-control use case. Candidate contents:

- Existing system-wide audio path, volume/mute, and basic output-device
  management.
- Basic EQ using a small, understandable control set.
- Safe clipping protection if whole-path behavior and defaults are validated.
- A small set of built-in profiles/presets.
- Basic manual profile switching and persistence.
- Bug fixes, stability, compatibility, installation, and recovery maintenance.

Essential audio output and the reliability fixes needed to keep it working remain
Free. No per-application capability is included in either tier.

### 8.2 SoundBridge Pro — candidate definition

Potential paid value: deeper sound shaping and personalization. Candidates include
full parametric EQ, advanced DSP effects, user correction profiles/import,
device-specific profile tools, expanded profile management, A/B comparison, and
audio analysis. These are not commitments. Each paid candidate must answer:

| Review question | Required evidence before commitment |
|---|---|
| What user problem warrants Pro? | A specific repeated need, supported by interviews or usability evidence. |
| Is the benefit meaningful? | Users can explain and successfully use the difference in a prototype. |
| Is the benefit distinct and clear? | It should solve a specific user problem through system-wide reliability, device-aware personalization, or a simpler workflow. |
| What ongoing cost does it create? | macOS compatibility, profile data rights/maintenance, support, licensing, packaging, and update costs. |
| Can current architecture support it? | Source review, DSP tests, performance measurements, and required hardware validation. |

Pro packaging and ongoing maintenance policy remain undecided. Set them after
the product scope and support obligations are clear.

## 9. Product UX and Navigation

The navigation below is a candidate information architecture, not a demand to
build every section at once:

```text
SoundBridge
├── Home
│   ├── Current output device
│   ├── Active audio profile
│   └── Processing / engine status
├── Equalizer
│   ├── Basic EQ
│   ├── Parametric EQ (Pro candidate)
│   └── Presets
├── Effects (only validated effects)
│   ├── Limiter / clipping protection
│   ├── Bass enhancement
│   └── Other effects after feasibility review
├── Headphone & Speaker Profiles
│   ├── Imported correction profiles
│   └── Custom profiles
├── Audio Profiles
│   ├── Music / Movie / Gaming / Voice
│   └── Custom
├── Analyzer (later candidate)
└── Settings
    ├── Audio engine and diagnostics
    ├── Devices
    └── Preferences / About
```

The existing menu-bar panel should continue to prioritize three tasks: understand
whether processing is healthy, see/select the output, and adjust volume/EQ or
the active profile quickly. Detailed editors can open in a native settings
window. Do not add a navigation level until a real user task requires it.

First-use flow should help a user: (1) install and select a working output,
(2) confirm processing is active, (3) choose a basic sound/profile, (4) hear and
compare the result, and (5) save personal settings. Failure messages need a
recovery step and must not imply the audio engine is processing when it is not.

## 10. Version-Based Roadmap Hypothesis

These version labels are planning hypotheses only. They do not change project
version numbers or create delivery commitments. Phase 0 gates new feature work.
Effort estimates assume one primary developer and use S/M/L/XL relative scale.

### Current release line — Stabilization and evidence (P0)

- **Objective:** make the existing system-wide path maintainable and supportable.
- **Audience:** all current users, especially fixed-volume HDMI/DisplayPort
  users.
- **Scope:** close or explicitly accept known Driver/Host lifecycle and RT
  issues; execute device removal/reconnection matrix; broaden format, buffer,
  macOS and hardware evidence; validate idle volume/mute and EQ persistence;
  improve error/recovery status; installation and upgrade clarity.
- **Exclusions:** new effect algorithms, commercial checkout, automatic
  calibration, and per-application features.
- **Dependencies/effort:** hardware access, macOS compatibility matrix, test
  harness and release evidence; L/XL aggregate effort.
- **Risks:** unsigned distribution, limited hardware coverage, RT violations,
  long-tail device behavior.
- **Acceptance / exit:** known critical defects resolved or documented with
  consequences; supported configuration matrix recorded; audio path survives
  device removal/reconnect and Host recovery scenarios; callback timing and
  processing quality baselines recorded; no unsupported broad compatibility
  claim.

### 1.3 — Professional Equalizer (P1; after stabilization gate)

- **Objective:** make the existing DSP Engine's differentiating EQ capability
  useful beyond three macro controls.
- **Audience:** everyday listeners first, headphone enthusiasts second.
- **Scope candidates:** user-facing presets; preamp/gain staging; parametric
  editor; improved EQ navigation; atomic persistence and safe bypass. A curated
  basic preset set belongs in Free; advanced controls remain a Pro candidate.
- **Exclusions:** dynamic EQ, app-level processing, measurement, and claims of
  automatic calibration.
- **Dependencies/effort:** DSP parameter model, UI, migrations, frequency
  response tests, real-time publication; L.
- **Risks:** UI complexity, boosts causing clipping, mapping controls to actual
  response, persisted settings causing unexpected sound.
- **Acceptance / exit:** filter response is measured for representative
  parameter sets; updates are smooth and bounded; clipping behavior documented;
  settings persist and recover across relaunch/Host restart/device switch; Free
  remains useful; hardware listening review completed.

### 1.4 — Advanced DSP evaluation and validated effects (P2)

- **Objective:** add only effects with demonstrated listening value and safe
  real-time cost.
- **Audience:** users who need dynamics or level-dependent tone control.
- **Scope candidates:** compressor, advanced limiter controls, loudness
  compensation, or dynamic EQ; select at most a narrow set after PoCs.
- **Exclusions:** “all effects” bundle, unvalidated stereo widening, DAW
  features.
- **Dependencies/effort:** individual algorithm PoCs, reference-vector tests,
  CPU/deadline measurement and quality review; L/XL per selected effect.
- **Risks:** pumping, latency, clipping, CPU spikes, hard-to-explain controls.
- **Acceptance / exit:** each shipped effect has documented parameters/defaults,
  offline regression vectors, finite/boundary tests, callback budget evidence,
  and user listening validation. No effect advances on implementation alone.

### 1.5 — Headphone and speaker personalization (P2)

- **Objective:** let users apply trusted correction curves and maintain
  output-specific sound.
- **Audience:** headphone enthusiasts and multi-output users.
- **Scope candidates:** correction import, profile metadata, custom target
  curves, device profile management, export/backup. Catalog inclusion is
  conditional on data rights and maintenance.
- **Exclusions:** SoundBridge-measured response and automatic room/headphone
  calibration absent a separately approved measurement project.
- **Dependencies/effort:** source licensing, format parser, curve-to-EQ mapping,
  profile schema, matching and support workflow; L/XL.
- **Risks:** profile mismatch/variants, data rights, measurement target
  disagreement, unsupported curves, ongoing catalog maintenance.
- **Acceptance / exit:** licensing/attribution confirmed; import subset
  documented; representative curves round-trip and meet response error bounds;
  profile provenance and limitations visible; device-specific settings recover
  correctly.

### 1.6 — Intelligent Audio Profiles (P2)

- **Objective:** make good sound convenient across devices and scenarios.
- **Audience:** everyday listeners who change activity or output device.
- **Scope candidates:** named built-in/custom profiles, quick switching,
  output-device mapping, then optional device-change auto-switching.
- **Exclusions:** app identification, app-triggered rules, broad automation
  engine.
- **Dependencies/effort:** stable configuration model and verified device
  events; M/L.
- **Risks:** unexpected profile changes, device identity changes, conflicting
  manual preferences.
- **Acceptance / exit:** manual MVP works before automation; active state is
  obvious; profile application is atomic; auto-switch only uses reliable device
  events, has override/fallback, and passes a hot-plug matrix.

### 2.0 — SoundBridge Pro (conditional launch)

- **Objective:** package the validated system-wide experience as a coherent
  Free/Pro product.
- **Audience:** users who have demonstrated demand for advanced DSP and
  personalization.
- **Scope candidates:** entitlement boundaries; advanced EQ/effects and
  personalization that passed prior gates; polished onboarding; trial/purchase
  and license flow only after distribution feasibility review.
- **Exclusions:** per-app control and new audio architecture.
- **Dependencies/effort:** user validation, licensing/distribution decision,
  support/update policy, legal review of profile data, packaging; L/XL.
- **Risks:** unsigned install friction, support burden, license/offline
  behavior, unclear user value, update expectations.
- **Acceptance / exit:** Free/Pro comparison reflects shipped functionality;
  buyers can try the product; licensing degrades gracefully offline if used;
  maintenance obligations and update policy are published; Pro adds value
  without degrading Free.

## 11. DSP Feasibility and Audio Quality Requirements

### 11.1 Current engine surface

Repository evidence shows an in-tree C/C++ DSP library with a C ABI and
Objective-C++ bridge. It supports up to ten stereo Float32 EQ bands, seven
filter types (peak, low/high shelf, low/high pass, notch, band pass), preamp,
optional soft limiting, smoothing, a DC blocker, processing statistics, and
configuration publication through a bounded mailbox. The documented engine
range is 8 kHz–384 kHz; EQ gains are −12 to +12 dB, frequency 20 Hz–20 kHz,
Q 0.1–10, and limiter threshold −6 to 0 dB. These are library limits, not
evidence that the full range is supported end-to-end by the shipped product.

The DSP README lists 33 automated tests, including frequency response and a THD
check. The latest release notes report a DSP audit and fixes. This is useful
foundation evidence, but it does not establish cross-device frequency response,
phase behavior, clipping perception, supported format coverage, or production
quality in every environment.

### 11.2 Processing and validation contract

Before an algorithm is committed, specify:

- Input/output sample format, channel layout, block sizes, sample-rate changes,
  and exact place in the current processing chain.
- Parameter ranges, defaults, state ownership, reset behavior, and control-to-RT
  publication semantics.
- Smoothing/interpolation and behavior during bypass or device reconfiguration.
- Numerical stability for NaN/Inf, denormals, extreme finite input, high-Q
  filters, and accumulated boosts.
- Added latency, CPU cost, worst-case callback execution, and deadline headroom.
- Offline test signals/reference vectors, measured frequency/phase response,
  overload/clipping behavior, regression tolerance, and structured listening
  protocol.

The release gate is no blocking, allocation/deallocation, synchronous logging,
I/O, or unbounded work in the callback; safe state publication/lifetime; bounded
processing; and measured performance on supported hardware. “It compiles” is not
an acceptance criterion.

## 12. Quality and Reliability Acceptance

| Area | Product requirement | Evidence required |
|---|---|---|
| Audio quality | No unexplained clipping; no channel imbalance; no audible discontinuity during supported parameter changes; predictable bypass and effect behavior. | Automated DSP vectors plus measured response/peak checks and documented listening review. |
| Reliability | Driver/Host lifecycle, shared-memory ownership, device changes, Host termination, and recovery must preserve or clearly restore system audio. | Unit/integration tests plus real macOS scenario matrix and recorded logs/counters. |
| Performance | Low, predictable added latency; bounded callbacks; reasonable CPU; no unbounded memory growth. | Baseline vs feature measurements, percentiles/max, CPU/memory under load, and matrix across supported formats/buffers. |
| Usability | User can see output, processing state, active profile, and recovery action; controls and tier boundaries are understandable. | Task-based usability tests with new users, including failure scenarios. |
| Compatibility | Support claims match tested OS, architecture, device, format, and security configurations. | Versioned hardware/software matrix; do not generalize one machine's result. |

Every feature status must distinguish: **implemented**, **build verified**,
**unit/integration-test verified**, **real-hardware verified**, and
**user-experience verified**. These are separate evidence states.

## 13. Product Metrics and Validation

The project has no telemetry/account system identified in the current baseline.
Do not silently add telemetry to measure adoption. Start with opt-in beta
feedback, local test records, and user-supplied reports. Any analytics proposal
needs an explicit privacy and product review.

| Metric | Definition / collection | Initial use |
|---|---|---|
| Successful audio setup | Share of observed onboarding sessions that reach confirmed system output and audible playback; collect in opt-in moderated tests or user report. | Find install/device setup failure points. |
| DSP activation and use | Share of beta participants who enable EQ/preset and keep using it after first session; opt-in diary/interview, not silent telemetry. | Test whether sound improvement is core value. |
| Preset/profile reuse | Whether users return to a saved preset/profile and understand the active state. | Validate profile model and UX. |
| Audio processing failure rate | Recorded underruns/recovery failures divided by measured playback time on a test rig; current counters do not normalize idle vs playback everywhere. | Reliability gate, not marketing metric. |
| Crash-free sessions | Only measurable if users opt into crash reporting or provide logs; no telemetry currently. | Decide if a privacy-preserving reporting mechanism is justified. |
| Support burden | Issue type and developer time per user/release, collected from support records. | Check support capacity for ongoing maintenance. |

### Lightweight independent-developer validation plan

1. **Positioning/landing-page test:** compare “system-wide audio enhancement,”
   “headphone personalization,” and “simple Mac EQ” messages with a small,
   transparently recruited audience. Measure qualified interest, not raw views.
2. **Early interviews:** ask target users how they currently adjust sound, what
   fails, what tools/data they trust, and what they would stop using. Avoid
   leading them with a feature list.
3. **Prototype usability:** observe first setup, profile selection, EQ changes,
   bypass, and device change. Record task success and confusion points.
4. **Beta feedback:** recruit a modest number of Mac users with varied outputs;
   gather system configuration, failure logs, and structured sound impressions
   only with consent.
5. **Feature preference:** compare concrete prototypes (parametric EQ,
   correction import, scenario profiles, analyzer) and ask users to rank by
   problem solved and expected frequency of use.

No large marketing budget, paid acquisition funnel, or enterprise sales motion
is assumed.

## 14. Risks and Open Questions

| Risk / question | Why it matters | Next evidence/action |
|---|---|---|
| Former roadmap conflicted with this strategy | Its historical plan promoted app-level volume as a paid MVP and Process Tap as future architecture. | This document is now the current product strategy; the former plan remains in Git history. |
| Audio path still has unclosed validation items | Reliability is a prerequisite for sound-quality claims. | Prioritize Known-Limitations U-1, U-3/U-5, U-6/U-7, U-11/U-13, and Driver RT findings. |
| DSP library capability exceeds current user-facing product | Users may infer supported controls or guarantees from the engine API. | Keep engine/API facts separate from app capability; trace and verify actual Host processing defaults before exposing controls. |
| EQ settings per device may not be enough for model correction | Device identity, variants, and target curves can be ambiguous. | Prototype schema and matching without committing to a catalog. |
| External headphone data rights and maintenance | Import/catalog value depends on reliable data and terms. | Review candidate dataset terms, attribution, update cadence, and redistribution permissions before implementation. |
| Unsigned distribution adds setup friction | Gatekeeper prompts may block otherwise interested users. | Test setup with target users; document the installation experience. |
| Future profile automation can surprise users | Device events and manual selection can conflict. | Ship manual profiles first; define clear override and fallback before automation. |
| Current telemetry is absent | Product adoption and crash-free metrics cannot be claimed. | Use opt-in qualitative research first; decide separately whether local/opt-in analytics is justified. |
| Solo-developer capacity | Broad DSP, data, UI, commerce, and compatibility work can exceed support capacity. | Limit each release to one primary user outcome and gate by prior phase evidence. |

## Appendix A — Baseline References

- [README](../../README.md) and [release notes](../RELEASE_NOTES.md)
- [1.2.1 product quality report](../release/SoundBridge-1.2.1-Product-Quality-Report.md)
- [Known limitations and evidence register](../risks/Known-Limitations.md)
- [1.2.0 architecture description](../architecture/SoundBridge-1.2.0-Architecture.md)
- [DSP library README](../../packages/dsp/README.md), public API, and tests
- [Menu bar UI](../../apps/mac/SoundBridgeApp/Sources/Views/MenuBarView.swift)
- [Basic EQ UI](../../apps/mac/SoundBridgeApp/Sources/Views/BasicEQView.swift)
