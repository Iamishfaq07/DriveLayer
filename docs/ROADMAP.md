# Roadmap

Maintained as work proceeds.

**CI is green at `a2a0399`.** All four jobs pass: static checks, `swift build` +
`swift test` (397 tests across 46 suites) on macOS, the app test target (21 tests
across 3 suites), and an Xcode build of the app and widget extension for the iOS
Simulator. What remains unverified needs hardware — see "Known gaps" at the end of
this file.

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
| **Test execution** | 418 tests passing in CI at `062386e`: 397 via `swift test`, 21 in the app target. |
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
| **Driver-reported hazards** | Unreachable. `RoadConditionProviding` and `LocalRoadReportStore` in `RoadIntelligence/RoadReports.swift` are referenced from nowhere — not the app, not the widgets, not even a test. Either wire them or delete them; leaving them reads as a feature that exists. |
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

1. Wire the Hyperion analysers to something a driver can see. `DriveSessionCoordinator`
   already calls the sibling `DieselGuardian.assess`, and `InsightEngine.standardRules`
   is how every other per-metric assessment reaches the driver — those are the two
   established seams, and neither is used yet.
2. Decode monitor-status PID 0x01 structurally (MIL state, DTC count) to finish the
   event-driven diagnostics refresh.
3. Begin the Hyperion Guardian rename, as one coherent change rather than a
   half-migration.
4. Run it on a device against a real adapter — still the thing that will find what no
   amount of CI can.

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
