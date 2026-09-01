# Roadmap

Maintained as work proceeds.

**CI is green at `982cd52`.** All four jobs pass: static checks, `swift build` +
`swift test` (494 tests across 53 suites) on macOS, the app test target (40 tests
across 6 suites), and an Xcode build of the app and widget extension for the iOS
Simulator. What remains unverified needs hardware — see "Known gaps" at the end of
this file.

One number in that list is worth reading sceptically, and this is the second time this
paragraph has had to say so. `swift test` was green at `a597477` on a package that could
not build on a platform without `os`: `TelemetryJournal` called an `os`-only API, and
every job that compiles the core runs on macOS. The suite passing proves the code
compiles *for the runner it ran on*. See "H-1" in [AUDIT.md](AUDIT.md).

Counts are taken from the sources, because `swift test --parallel` prints no total on
the way past. A green claim here is only ever as fresh as the commit named beside it:
this paragraph still read "CI is green" while the three most recent runs on PR #5 were
failing, one of them on a switch that did not compile. Hence the commit is now named,
and the claim should be re-dated or deleted rather than left to drift.

The project is now scoped to **one vehicle**: a 2026 Tata Harrier with the 1.5-litre
Hyperion turbo GDI petrol engine. The architecture stays multi-vehicle — every part of
the intelligence layer reads its car through `VehicleProfile` — but the product does
not, and no development time goes into generic multi-brand UX. See
[AUDIT.md](AUDIT.md) for what was found when the repository was measured against that
brief, and "Harrier brief" below for what is being done about it.

---

## Phase 0 — Repository audit

**Done.**

The repository contained a `README.md` with one line and an MIT `LICENSE`. No source,
no project file, no tests, no CI. There was nothing to preserve, nothing to refactor,
and no existing architecture to work around — this is greenfield.

Environment findings that shaped everything after:

- **No Swift toolchain.** `download.swift.org` is blocked by the sandbox's egress
  policy; there is no macOS, Xcode or iOS SDK. Compilation is impossible here.
- **Response:** the product logic was made Foundation-only so it is testable with
  `swift test` on any machine, and `Tools/swiftcheck.py` was written to catch the
  class of errors a compiler would — bracket balance, unknown types, bad member
  references, import policy, banned APIs, project-file drift. It is run after every
  meaningful change and currently passes across 105 files.

---

## Phase 1 — Architecture and design system · **Done**

- Foundation-only `DriveLayerCore` with a checker-enforced import policy.
- `SemanticStatus` (normal / watch / attention / critical / unknown) with a distinct
  symbol per case, so status never depends on colour alone.
- `DataProvenance` and `Provenanced<Value>` as first-class model types.
- `LoadState` and `UnavailabilityReason` with per-condition copy.
- Design system: spacing, radius, type scale, semantic colour, status indicators,
  metric views that render absent values as a dash and a reason, evidence rows,
  sparkline, and the full set of state views.

## Phase 2 — Vehicle profile and garage · **Done**

- `VehicleProfile` with per-value `SpecSource`, engine-condition-scoped operating
  ranges, three validation tiers, and manufacturer capabilities that cannot carry a
  request unless validated.
- Tata Harrier 1.5 TGDi Hyperion petrol profile at `experimental`, plus generic diesel and petrol.
- Garage scoped to one vehicle for now, with per-vehicle data isolation intact
  underneath and a delete that genuinely removes trips, baselines, fuel,
  maintenance, documents and telemetry.

## Phase 3 — Today dashboard · **Done**

Health with explanation, range and fuel, last drive, weather, insights, next service.
Four-tab navigation with the lower-frequency areas behind the Vehicle tab.

## Phase 4 — Trip recording · **Done**

- `TripRecorder`: a pure value-type state machine (idle → arming → recording →
  stopping), with duplicate-start rejection, engine-off detection, long-silence
  recovery that does not invent the missing time, and discard of drives too short to
  matter.
- `TripBuilder`: distance with implausible-jump rejection, elevation with hysteresis,
  idle accounting, event detection, and fuel as a `Provenanced` value with three
  tiers and an honest "unavailable".
- Trip list, detail with six sections, and repeated-route comparison worded as
  association.

## Phase 5 — OBD subsystem and simulator · **Done**

- Read-only mode set; ELM327 parser covering CAN headers, ISO-TP multi-frame, adapter
  errors, negative responses and corrupt frames; SAE J1979 catalog with standard
  scalings only, plausibility bands and refresh classes; capability discovery with
  tri-state DTC support; DTC decoder and catalog; session actor that learns what a
  vehicle refuses.
- CoreBluetooth transport confined to one file behind `OBDTransport`.
- Thirteen simulator scenarios on a deterministic model, emitting real ELM327 text.

## Phase 6 — Vehicle health · **Done**

Six systems with statuses, headlines, evidence and per-system detail. Unassessable
systems read `unknown` with an actionable reason.

## Phase 7 — Baselines and insight engine · **Done**

- Daily-aggregate baselines keyed by `(metric, driving context)`, with outlier
  rejection and an OLS trend.
- Eleven insight rules, pure functions of an explicit context. Engine deduplicates by
  stable id, carries forward valid findings, expires stale ones, and cuts to three
  while driving. Confidence capped by the weakest provenance.

## Phase 8 — Diesel Guardian · **Done, and now superseded**

> Built for the 2.0 Kryotec diesel that used to be the reference car. It switches
> itself off through `fuelType`, so it is invisible on the petrol Harrier, and the
> copilot already answers particulate-filter questions with "this vehicle isn't a
> diesel". The subsystem architecture is sound and worth generalising rather than
> deleting; the *product concept* is being replaced by Hyperion Guardian. Tracked
> under the Harrier brief below, not yet done.

Short-trip fraction and warm-up completion as measurements where coolant is
available and inference where it is not; `DPFTelemetry` with no path that fills a
value from a guess; guidance that points at the owner's manual.

## Phase 9 — Fuel and maintenance · **Done**

Full-to-full economy with partial fills handled, range excluding the unusable bottom
of the tank, journey reachability, maintenance due by distance/date/either, service
records, and the digital glovebox with expiry escalation.

## Phase 10 — Location and terrain · **Done**

Geo maths that reject bad fixes, a gradient calculator fitted across its window with
confidence that collapses at the noise floor, elevation hysteresis, terrain feature
detection, and road impact detection that deliberately has no "pothole" case.

## Phase 11 — Weather · **Done**

`WeatherProviding` with a WeatherKit implementation gated behind an Info.plist flag,
an honest mock, and a route analyser that reports *changes* — at most two while
driving — rather than a card every few kilometres.

## Phase 12 — Drive Mode · **Done**

One large number, four supporting ones, at most three pieces of context, and a
telemetry sheet one level down.

## Phase 13 — CarPlay · **Done (code), gated (entitlement)**

Root list with urgency-ordered status and four pre-computed questions, using
driving-task-appropriate templates. Isolated so the app builds and runs identically
without the entitlement. Enabling it is two documented steps — see
[CARPLAY.md](CARPLAY.md).

## Phase 14 — Widgets and Live Activities · **Done**

Four widgets plus a Live Activity, reading a snapshot published to a shared app group
so widgets render rather than reason. Timeline reloads only on meaningful change;
Live Activity updates throttled to twenty seconds.

## Phase 15 — Copilot · **Done**

On-device deterministic intent matcher over a summarised snapshot that by
construction excludes raw telemetry, routes, coordinates, VIN and registration. Every
sentence badged fact / estimate / inference / general information. Siri support
through three App Intents.

## Phase 16 — Testing, polish, performance, privacy · **Partially done**

- 229 tests across 33 suites, weighted towards failure cases. **Passing in CI.**
- Performance decisions made where they matter: per-metric refresh classes, sampling
  deadbands, the compact telemetry codec, split drive/analysis rates, location
  fidelity tied to what the user is doing, throttled widget and Live Activity updates.
- Privacy: local-only storage, file protection, retention controls, export, delete-all,
  redacting logger, snapshot boundary for the copilot.
- **Not done:** profiling on a device, a full accessibility audit, localisation.

---

## Known gaps

Honest list of what is scaffolding rather than working software.

| Area | State |
|---|---|
| **Compilation** | Green in CI: core, tests, app and widget extension all compile. |
| **Test execution** | 534 tests passing in CI at `982cd52`: 494 via `swift test`, 40 in the app target. |
| **Device run** | Not performed. Needs hardware — sensors, a real adapter, a real car. |
| **CarPlay** | Code complete; needs Apple's entitlement plus two documented edits. |
| **WeatherKit** | Implemented; needs a paid capability, and reports "not configured" until then. |
| **Elevation provider** | Protocol plus an honest mock. No real elevation source is bundled, so terrain-ahead is only live with a provider configured. |
| **Route weather** | Working end to end. A driver sets a destination in Drive Mode, MapKit supplies the road, and the forecast is read at 10 km intervals for the hour the driver is expected at each. Needs WeatherKit configured to return anything. |
| **Document scanning** | Capture and on-device recognition are wired to the tested extractor. Compiled in CI; not yet exercised against a real document on hardware. |
| **Road impact events** | Detected, persisted per vehicle, and shown on the drive they happened on. Not corroborated across drives or drivers, so they are never called potholes and never escalate past `watch`. |
| **Widget deep links** | Every widget and the Live Activity open the screen they describe, the last-drive widget included — it links to "my last drive" rather than an identifier, so the app resolves which drive that is as it opens. |
| **Accessibility on device** | Contrast is enforced by tests and every metric has a spoken label, but nothing has been driven with VoiceOver or at the largest text sizes on real hardware. |
| **Other vehicles** | Deliberately not offered. The catalog, the profile system and per-vehicle isolation are all built and tested; `SupportedVehicles.offeredProfileIDs` lists the one car a driver may pick, because it is the only one anything has been checked against. |
| **Driver-reported hazards** | Unreachable, and re-confirmed at `982cd52`: `RoadConditionProviding` and `LocalRoadReportStore` in `RoadIntelligence/RoadReports.swift` are referenced from nowhere — not the app, not the widgets, not even a test. Deliberately left alone this pass rather than wired: hazard reporting is a V2 feature and needs UI, whereas the same pattern in `SensorGate` was a reliability defect because unreachable code there *claimed* to be protecting live data. This scaffolding claims nothing. Still either wire it or delete it. |
| **Watch app** | Not started. |

## Harrier brief

The seven phases requested for the Harrier-only pivot, in the order they were given.
Nothing below is marked done unless CI has compiled and tested it.

### Phase 1 — Critical reliability · **Done**

Every item was confirmed against the code first; see [AUDIT.md](AUDIT.md) for the call
sites that proved each one.

| Item | Status | Note |
|---|---|---|
| Active-trip persistence | **Done** | Checkpointed on start, every 20 s, and on backgrounding |
| Telemetry journaling | **Done** | `TelemetryJournal`, append-only chunks, compaction last |
| Crash recovery | **Done** | `recoverInterruptedTrips()` was dead code; it now has drives to find |
| DTC unknown-capability bug | **Done** | Two independent permanent blocks, both removed |
| BLE reconnect | **Done** | Supervised 1/2/5/10/30 s ladder, drive untouched |
| Privacy deletion | **Done** | `PrivacyDeletion` orchestrates storage, widgets, reminders, Live Activity |
| Retention correctness | **Done** | Now prunes raw telemetry; baselines kept and reset separately |
| Widget cleanup | **Done** | `WidgetSnapshotStore.clear()` existed nowhere before |
| Notification cleanup | **Done** | Cancelled on vehicle and all-data deletion |
| Auto-recording permissions | **Done** | Requests, verifies, and reports what iOS actually said |
| DTC event-driven refresh | **Not done** | Needs monitor-status PID 0x01 decoded structurally, not as display text |

### Phase 2 — Integration quality · **Partly done**

| Item | Status | Note |
|---|---|---|
| Altitude fusion | **Done** | Was re-anchoring to GPS every second; barometer contributed nothing |
| Road-impact setting | **Done** | Gated persistence only; 20 Hz processing ran regardless |
| Location lifecycle | **Partly** | `start()` no longer asks for driving accuracy when detection is off; full lifecycle audit outstanding |
| Adapter reconnect | **Done** | Includes wiring `noteAdapterConnectionChange`, which had no callers |
| BLE discovery validation | **Not done** | Every notify+write peripheral is still treated as a candidate |
| BLE state restoration | **Not done** | Needs `CBCentralManager` restoration and a device to verify against |
| App-level integration tests | **Not done** | See below — this is the structural blocker |

**The structural blocker.** `Package.swift` declares only the core library and its test
target; the app target exists solely in `project.yml`. So all 326 tests exercise
`DriveLayerCore` and the app target has **none** — and almost every bug in this phase
lived there. The approach taken so far has been to move the awkward logic *into* the
core where `swift test` reaches it: `TelemetryJournal`, `AltitudeFusion`,
`ReconnectPolicy`, `AutomaticDetectionStatus`. That is genuine coverage of the
behaviour, but it is not coverage of the call sites. A real app test target, run via
`xcodebuild test` on the macOS runner, was still needed — it landed in `c0c88c1` as the
`app-tests` job, and now carries 21 tests across 3 suites.

### Phase 3 — Hyperion pivot · **Data layer started, nothing wired**

The profile is already correct in substance: Tata Harrier, petrol, Hyperion TGDi 1.5,
turbocharged, `.experimental` tier, no invented power or torque figures, and an empty
manufacturer-specific PID table. The model year was 2025 in the profile and 2026 in its
own id; reconciled to 2026.

Landed so far, under `Sources/DriveLayerCore/Hyperion/`: the warm-up model
(`EngineThermalModel`), a sensor-plausibility gate (`SensorGate`), heat-soak
intelligence (`HeatSoakAnalyser`), and `InsightConfidence` as the qualitative rung
above the numeric confidence `DriveInsight` already ranks by.

All four are covered by tests and **none of them has a caller.** Nothing in the app
target, the coordinator, the view models, the widgets or CarPlay consumes them, and
`EngineTemperatureRule` in `InsightRules.swift` still does its own coolant
thresholding independently of `EngineThermalModel`. This is tested library code that
no driver can currently reach, so the next step is wiring rather than more analysers.

What remains: renaming and generalising `Diesel/` into an aftertreatment abstraction
plus a petrol-focused Hyperion Guardian, turbo/air intelligence from MAP − BARO
clearly labelled as an estimate, fuel-trim baselines, GDI fuel-rail data where
standardised, and battery/start intelligence.

### Phase 4 — Route intelligence · **Mostly done, earlier**

Destination search, `MKDirections` routing, route weather and the elevation hooks
landed in PR #3. Missing: a unified Context Ahead engine and fuel-to-destination.

### Phases 5–7 — Product UX, CarPlay, polish · **Not started**

Today/Hyperion/Drive/Trips restructure, the Hyperion screen, CarPlay simplification and
Ask Harrier, then the accessibility, battery and long-drive soak work.

## Next up

The first two items here were "wire the Hyperion analysers to something a driver can
see" and "decode monitor-status PID 0x01 structurally". Both are done —
`DriveSessionCoordinator:475` calls `HyperionGuardian.assess`, and `MonitorStatus` is a
structured type — so they are removed rather than left to look outstanding.

1. **Units as data.** `SensorQuality` now travels with every telemetry entry, but units
   are still implicit in metric names (`coolantTemperatureC`, `vehicleSpeedKmh`). The
   convention holds today; it is a convention rather than a guarantee. Recorded as
   PARTIAL under "H-5" in [AUDIT.md](AUDIT.md) rather than counted as complete.
2. **`RoadReports.swift`: wire it or delete it.** Still referenced from nowhere. See
   "Driver-reported hazards" in Known gaps for why it was left alone this pass.
3. Begin the Hyperion Guardian rename, as one coherent change rather than a
   half-migration.
4. **Validate the adapter before storing it.** `P0-7c` remains half-done: the pairing
   screen filters and the classifier is tested, but nothing performs an `ATZ`/`ATI`
   handshake *before* an adapter is remembered. It is now at least never remembered
   before the session reports a usable link (see "H-4"), so a non-adapter no longer
   becomes the permanent reconnect target — but a real handshake is still the check
   that belongs there.
5. Run it on a device against a real adapter — still the thing that will find what no
   amount of CI can. Two items now depend specifically on hardware CI cannot fake: the
   parking-lot case in "H-3" needs a second adapter present, and the sensor gate's
   staleness path needs an ECU that genuinely stops answering.

## V2

Richer CarPlay once the entitlement lands · route weather driven by a destination ·
a model-backed copilot behind `CopilotProviding` · road hazard reporting · surfacing
impact events · sharper fuel intelligence using terrain · Apple Watch · deeper
maintenance · anomaly detection beyond thresholds · validated Harrier-specific PIDs
if and when they can be verified.

## V3

Crowdsourced road quality with real corroboration · camera-assisted road
intelligence · multiple vehicle intelligence packs · optional cloud sync (opt-in,
encrypted, never a requirement) · fleet and family garage · broader manufacturer
integrations where they can be done legitimately.

---

# Hyperion Alpha

The target for this pass. Audited at `115e7ef`; findings and their classifications are in
[AUDIT.md](AUDIT.md) under "Hyperion Alpha audit — P0 pass".

Statuses here are deliberately narrow. **IMPLEMENTED** means production code calls it,
data reaches it, a user-facing surface shows its result, and tests cover the logic.
Anything short of that is **PARTIAL**, **MOCK ONLY**, **BLOCKED ON HARDWARE** or
**BLOCKED ON ENTITLEMENT**. A type existing and being unit-tested is not implemented —
that mistake is what left four Hyperion analysers with no callers.

## P0 — reliability and truthfulness

| # | Item | Status |
|---|---|---|
| P0-1 | Logging abstraction | NOT APPLICABLE — iOS and macOS both ship `os`; no Linux target |
| P0-2 | Confirmed telemetry persistence | IMPLEMENTED — writes report their result, samples retained on failure |
| P0-3 | Chunk numbering | IMPLEMENTED — highest sequence + 1, regression tested |
| P0-4 | Journal reconciliation, orphan handling | IMPLEMENTED — orphans collected at launch, live drives protected |
| P0-5 | Location requested-vs-actual state | IMPLEMENTED — replay needs a device, see V-3 |
| P0-6 | GPS freshness before auto-start | IMPLEMENTED — a stale fix cannot start a drive |
| P0-7 | Reconnect on any unexpected drop | IMPLEMENTED — BLOCKED ON HARDWARE to verify, see V-2 |
| P0-7b | Wait for `isNotifying` before ready | IMPLEMENTED — BLOCKED ON HARDWARE to verify, see V-1 |
| P0-7c | Filter the pairing screen | IMPLEMENTED — classifier tested; ELM handshake before storing still outstanding |
| P0-8 | SensorGate must never yield to impossible values | IMPLEMENTED — yielding gated by reason |
| P0-9 | Payload versioning and migration | IMPLEMENTED — versioned envelope, unreadable rows kept |
| P0-10 | Simulator isolation | IMPLEMENTED — separate provenance, barred from baselines and from release builds |

P0 is complete: nine fixed, one not applicable. Every fix is green across the four CI
jobs. Three carry a caveat that CI cannot remove, and they are written up as procedures in
[REAL_CAR_VALIDATION.md](REAL_CAR_VALIDATION.md) rather than quietly called done:

- **P0-5** — the tests cover intent surviving a refused start. CoreLocation in a test
  bundle reports `.notDetermined` and grants nothing, so the replay when permission
  arrives needs a device (V-3).
- **P0-7 / P0-7b** — a disconnect with nothing in flight, and a notification subscription
  confirming late, both need a real peripheral (V-1, V-2).
- **P0-7c** — the pairing screen now filters, and the classifier is tested. Validating an
  adapter with an `ATZ`/`ATI` handshake *before* storing it is not done; today a
  non-adapter is still caught only as a timeout one layer up.

Two follow-ups fall out of this pass rather than being in the brief:

- `Trip.isSimulated`, so a simulated drive is distinguishable in history rather than only
  in its telemetry provenance. Deliberately deferred: it is a payload shape change, and it
  needs the version-2 migration that P0-9 has now made possible. Adding it before P0-9
  would have silently deleted every stored drive, which is exactly the bug P0-9 fixes.
- A directly asserted test for the coordinator retaining samples when a write fails. The
  seam exists and the store contract is tested on both outcomes, but driving the
  coordinator's own retain branch needs the simulator-driven soak harness from P3.

Two P0 findings are worth calling out because they are worse than the brief assumed.

**P0-5** is not only about losing a high-fidelity mode. The first call at launch is
`start(fidelity: .idle)`, so if permission is granted after launch, nothing starts at all
and no drive can ever be detected — while `automaticDetectionStatus` still reports
"Active", because it reads the settings flag and authorization and never asks whether
tracking is actually running.

**P0-7** means the reconnect supervisor landed in `ddc7dcc` is, in practice, unreachable
for the ordinary disconnect. The poll loop idles 250 ms between reads, so a drop usually
happens with no request in flight, and the resulting `.notConnected` fails the
`.connectionLost` guard that is the only thing that starts a reconnect.

## P1 — Hyperion intelligence

| # | Item | Status |
|---|---|---|
| P1-11 | Remove diesel product logic | ALREADY FIXED — unreachable on a petrol profile; see below |
| P1-12 | Wire `HyperionGuardian` end to end | IMPLEMENTED — 2 of 6 areas assessed |
| P1-13 | Structured fuel system status (`01 03`) | IMPLEMENTED — PID was absent entirely |
| P1-14 | Fuel trim intelligence | Not started · BLOCKED ON HARDWARE for the PIDs (V-4) |
| P1-15 | Turbo and air, estimated boost | Not started · BLOCKED ON HARDWARE (V-6) |
| P1-16 | Warm-up intelligence and history | PARTIAL — model wired, per-drive history not stored |
| P1-17 | Heat soak | IMPLEMENTED — live through `HyperionGuardian` |
| P1-18 | Battery trends | IMPLEMENTED — logic shared with the health view |
| P1-19 | MIL and DTC events | IMPLEMENTED — a lamp change now reads the codes |
| P1-20 | Aftertreatment | IMPLEMENTED — readiness only, by design |
| P1-21 | Expanded contextual baselines | Not started |

**All six Hyperion areas are now assessable**, and each still states why when it cannot be.
The two rules the roll-up follows are tested, because both look right and read as broken if
got wrong: an area nobody has built yet does not count towards the engine headline, and
neither does an area that looked and could not tell. An emissions self-test still running is
an absence of evidence, not a finding, so it neither drags the headline to unknown nor
appears in the "worth a look" line.

Aftertreatment reports self-test readiness and nothing else, deliberately. Readiness is what
standard OBD-II exposes about a catalyst and a GPF; direct filter loading is not a standard
PID. It is named in the evidence and marked unavailable rather than omitted, so the absence
is a statement rather than a gap.

Three of the four items built in this pass needed no vehicle, which was the sequencing
intent: P1-14 and P1-15 rest on PIDs the Harrier may or may not answer, and building
intelligence on an unconfirmed foundation is the thing this brief warns against.

**P1-11 was verified rather than assumed, and the brief's premise did not hold.** No
diesel content can reach a Harrier owner: `DieselGuardian.assess` guards on
`profile.fuelType.isDiesel` and returns `.notApplicable` for petrol, and all three
consumers gate on `isApplicable` — `DieselUsageRule` returns nothing,
`VehicleHealthEvaluator.dieselUsage` returns nil so no "Diesel usage" system is built, and
the CarPlay row was never appended. It is dead code for this product rather than a
user-facing defect, so it was left in place rather than half-migrated: renaming `Diesel/`
into an aftertreatment abstraction is the coherent change the brief itself asks for, and
doing it in passing is how a half-migration happens. The one dead diesel surface removed
was the CarPlay row, because Hyperion now occupies that line.

**P1-12 closed the finding this whole pass opened with.** `EngineThermalModel`,
`HeatSoakAnalyser`, `SensorGate` and `InsightConfidence` were tested and called by nothing.
`HyperionGuardian` assembles them, the coordinator publishes an assessment each analysis
pass, and CarPlay reads it.

Two areas of six are assessed — engine state and air/turbo. The other four are present and
each carries the reason it is not assessed yet, which is deliberate: an unbuilt area that
says so is more useful than an absent one, and unassessed areas are excluded from the
overall status because `unknown` outranks `normal` in a roll-up and would otherwise report
the whole engine as unknown while every reading says it is fine.

Air and turbo is the intake-versus-ambient story only. Estimated boost from MAP minus
barometric pressure joins it when V-5 confirms those PIDs on the real car, and not before.

## P2 — trip and route quality

Not started: phone-only trip statistics, fused trip elevation, a production route terrain
provider, Context Ahead, the trip event timeline, repeated-route comparison, the fuel
journal.

Route terrain is **MOCK ONLY**: `MockElevationProvider` is the sole conformer of
`ElevationProviding` anywhere in the tree, so terrain-ahead has no live data source.

## P3 — surfaces and scale

Not started: CarPlay cleanup, Ask Harrier, the real-car capability scan, PID Lab, Debug
Center expansion, performance and soak testing, UI polish.

CarPlay is **BLOCKED ON ENTITLEMENT** and stays that way: the code is complete and needs
Apple's driving-task entitlement plus the two edits documented in
[CARPLAY.md](CARPLAY.md). Whether the templates it currently uses are permitted for that
entitlement is unverified, so "complete" here means "compiles and is wired", not
"validated".

## What still needs the actual car

Unchanged from the first audit and not reducible by more code: a device run against a
real adapter is the only way to learn what the 2026 Hyperion ECU actually exposes. Until
then every PID beyond the standard set is a hypothesis. Test procedures belong in
`docs/REAL_CAR_VALIDATION.md` as each hardware-dependent feature lands.
