# Roadmap

Maintained as work proceeds.

**CI is green.** All three jobs pass: static checks, `swift build` + `swift test`
(229 tests across 33 suites) on macOS, and an Xcode build of the app and widget
extension for the iOS Simulator. What remains unverified needs hardware — see
"Known gaps" at the end of this file.

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
- Tata Harrier 2.0 Kryotec profile at `experimental`, plus generic diesel and petrol.
- Garage with multiple vehicles, per-vehicle data isolation, and a delete that
  genuinely removes trips, baselines, fuel, maintenance, documents and telemetry.

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

## Phase 8 — Diesel Guardian · **Done**

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
| **Test execution** | 229 tests passing in CI. |
| **Device run** | Not performed. Needs hardware — sensors, a real adapter, a real car. |
| **CarPlay** | Code complete; needs Apple's entitlement plus two documented edits. |
| **WeatherKit** | Implemented; needs a paid capability, and reports "not configured" until then. |
| **Elevation provider** | Protocol plus an honest mock. No real elevation source is bundled, so terrain-ahead is only live with a provider configured. |
| **Route weather** | Analyser and waypoint builder are done and tested; nothing yet supplies a route, so it needs a destination or navigation integration to fire. |
| **Document scanning** | Field extraction is implemented and tested; the VisionKit capture UI is not wired up, so documents are typed in. |
| **Road impact events** | Detection implemented and tested; events are recorded locally and not yet surfaced in the UI or corroborated across drives. |
| **Live Activity range** | The field exists; the coordinator does not yet populate it. |
| **Trip weather** | `Trip.weather` is modelled but not captured during a drive. |
| **Widget deep links** | Widgets display; tapping one opens the app but not a specific screen. |
| **Notifications** | No local notifications yet for expiring documents or overdue service. |
| **Watch app** | Not started. |

## Next up (V1 completion)

1. ~~Build it.~~ **Done** — CI compiles everything and runs the suite.
2. ~~Local notifications for document expiry and overdue service.~~ **Done.**
3. ~~Populate Live Activity range and capture trip weather.~~ **Done.**
4. Wire the VisionKit capture flow to the existing, tested extractor.
5. Widget deep links.
6. Accessibility pass: Dynamic Type at the largest sizes, VoiceOver labels on every
   metric, contrast check on the status palette.
7. Run it on a device against a real adapter — the first thing that will find
   problems no amount of CI can.

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
