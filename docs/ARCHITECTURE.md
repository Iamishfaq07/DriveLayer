# Architecture

## The one decision everything follows from

`Sources/DriveLayerCore` imports Foundation and nothing else. No SwiftUI, no UIKit,
no CoreBluetooth, no CoreLocation, no CoreMotion, no WeatherKit, no SwiftData. The
static checker enforces it.

That single rule buys most of the qualities the product needs:

- **Everything testable without a car.** OBD decoding, baselines, trip maths, fuel,
  maintenance, insight rules — all of it runs under `swift test` on any machine.
- **Device frameworks confined.** CoreBluetooth appears in exactly one file, behind
  `OBDTransport`. CoreLocation appears in one. Bluetooth code cannot leak into trip
  logic because trip logic cannot see Bluetooth.
- **The simulator exercises production code.** It implements the same transport
  protocol and emits real ELM327 text, so a simulated drive runs through the real
  parser, decoders, capability discovery and session — not around them.
- **No `public` noise.** The app and widget compile the core sources directly, so
  the core is written in plain internal Swift. The test target uses the Swift package,
  where `@testable import` grants the same access.

```
┌──────────────────────────────────────────────────────────────┐
│  App/DriveLayerApp        SwiftUI · SwiftData · CoreBluetooth │
│                           CoreLocation · CoreMotion · WeatherKit│
│                           CarPlay · ActivityKit · AppIntents   │
│         ▲ implements protocols          ▲ reads models         │
├─────────┼───────────────────────────────┼─────────────────────┤
│  Sources/DriveLayerCore                 │      Foundation only │
│                                                                │
│  OBDTransport ◄── BluetoothOBDTransport (app)                 │
│                ◄── SimulatedOBDTransport (core, 13 scenarios)  │
│  LocationProviding ◄── LocationService (app)                   │
│  AltitudeProviding ◄── MotionService (app)                     │
│  WeatherProviding  ◄── WeatherKitProvider (app) / Mock (core)  │
│  ElevationProviding · RoadConditionProviding · CopilotProviding│
└──────────────────────────────────────────────────────────────┘
```

## Data flow during a drive

`DriveSessionCoordinator` is the only place the live pieces meet. Everything else
knows nothing about the others.

```
  CoreLocation ─┐
  CoreMotion   ─┼─► DriveSessionCoordinator ──► TripRecorder ──► TripBuilder
  OBDSession   ─┘        │  1 Hz                                      │
                         │                                            ▼
                         │  every 5 s                            Trip + events
                         ▼
                InsightContext ──► InsightEngine ──► [DriveInsight]
                       │      └──► VehicleHealthEvaluator ──► report
                       │      └──► CopilotContextBuilder ──► snapshot
                       ▼
              baselines · fuel · diesel · maintenance
```

Two rates, deliberately. The drive loop runs at 1 Hz, which is enough to record a
trip accurately. Analysis runs every five seconds, because re-deriving the whole
picture at 1 Hz would burn battery to tell the driver the same thing sixty times a
minute. Weather is fetched at most every fifteen minutes.

## Provenance is a type, not a label

```swift
enum DataProvenance { case measured, estimated, inferred, unavailable }
struct Provenanced<Value> { var value: Value?; var provenance: DataProvenance; var basis: String? }
```

`Provenanced` enforces its own invariant: a `nil` value is always `.unavailable`, and
a present value never is. Fuel used on a drive is `.estimated` when integrated from a
reported fuel rate, `.estimated` with a different basis when derived from tank level,
and `.unavailable` — with an explanation — on a phone-only drive. The UI renders
those three differently, and `MetricView` renders a missing value as a dash and a
reason. Insight confidence is capped by the weakest provenance behind it.

## Storage

Two stores, because one shape does not fit both kinds of data.

**SwiftData** holds the entities queries sort and filter on: vehicles, trips, fuel
entries, maintenance items, service records, documents, baseline aggregates,
adapters, road events. Each record keeps the query columns as real properties and the
rest of the domain value as an encoded payload, so the domain models stay plain
`Codable` structs in the core. Adding a model means bumping the schema, not editing a
record shape in place.

**Files** hold telemetry. A drive at one sample a second for three hours is ten
thousand rows; a month of driving is a database that gets slower every day. Instead
`TelemetrySeriesCodec` packs a drive into one blob — a fixed header, then per sample
a millisecond offset, a 32-bit presence bitmask, and 16-bit quantised values for the
metrics actually present. That is about 8 bytes plus 2 per present metric per sample,
and a metric the vehicle never reports costs nothing. Telemetry files are excluded
from iCloud backup; documents get complete file protection.

Before anything is written, `TelemetryDownsampler` applies a per-metric interval and
deadband: coolant is kept when it moves 1.5 °C or a minute passes, engine speed when
it moves 250 rpm or ten seconds pass.

## Baselines

Baselines are learned from **daily aggregates**, not raw samples: a month is thirty
rows rather than millions, and daily granularity is what the insights actually speak
in ("trending below your baseline for three weeks").

They are keyed by `(metric, context)` where context is idle, cruising, climbing, cold
engine, or warmed up — so a coolant reading from a climb is never compared with one
from a motorway cruise. That conditioning is what lets DriveLayer say "normal for a
climb of this intensity" instead of raising a false alarm.

The statistics are deliberately explainable: median, percentiles, standard deviation,
ordinary least squares trend, with median-absolute-deviation outlier rejection before
anything is computed. No machine learning, because every number shown to a driver has
to be defensible in one sentence.

## The insight engine

A rule is a pure function of `InsightContext` — a struct assembled explicitly rather
than a bag of services — so each rule is a unit test. The engine's job is as much
suppression as generation: it deduplicates by stable id, carries forward findings
that are still valid, drops expired ones, sorts by severity then confidence, and cuts
the list to three while driving.

Insights have stable ids like `battery.declining-trend`, so re-running the engine
updates a finding rather than stacking duplicates.

## Concurrency

- `OBDSession` is an actor: the adapter is strictly one request at a time, and the
  session is shared by the drive screen, CarPlay, the trip recorder and the Debug
  Center.
- The UI-facing services are `@MainActor @Observable` classes.
- `BluetoothOBDTransport` is `@unchecked Sendable` with all state confined to its own
  dispatch queue, which is where CoreBluetooth delivers callbacks.
- The core's value types are `Sendable`. `TripRecorder` is a value-type state machine
  driven by explicit `update(…)` calls, with no timers of its own — which is why
  duplicate starts, dropped adapters and app kills are all reachable in tests.

## Navigation and deep links

`DeepLink` is a plain enum in the core with a URL on one side and a case on the
other, so the rules for what `drivelayer://maintenance` means are unit tested
without a UI. It parses strictly: an unrecognised destination returns `nil` rather
than falling back to a home screen, because opening a screen the caller did not ask
for is worse than ignoring the link.

The app layer adds one extension mapping each link to a tab and a path, and one view
resolving a link to a screen. `RootView` owns the navigation paths — not each tab —
because a widget tap has to set them from outside. Rows inside the app use
`NavigationLink(value: DeepLink…)` against the same table, so tapping "Glovebox" and
following a widget arrive by the same route.

Widgets link to what they are actually showing: the fuel widget to fuel, the service
widget to maintenance, the status widget to the insight it is displaying or to the
vehicle screen when there is none, and the last-drive widget to the drive itself.

That last one names an intent — `drivelayer://last-drive` — rather than carrying a
trip identifier, and the app resolves which drive that is as it opens. A UUID in the
URL could point at a drive the driver has since deleted, or at a stale one when a
newer drive finished after the widget last refreshed. Naming the intent has neither
failure mode.

## Deployment target

iOS 17. Chosen for `@Observable`, SwiftData, and the ActivityKit and WidgetKit APIs
actually used — not for novelty. Anything newer is behind an availability check, and
optional frameworks (`WeatherKit`, `ActivityKit`, `CarPlay`) are behind `canImport`
so the app builds and runs without them.
