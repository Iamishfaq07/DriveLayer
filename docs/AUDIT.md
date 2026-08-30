# Audit

An audit of DriveLayer against the Harrier-only product brief, carried out at
`f1c0489`. Every finding below was checked against the code rather than taken on
trust, and each one records how it was verified.

## Verification environment — read this first

The audit and the fixes were done on a Windows machine with **no Swift toolchain**:
no macOS, no Xcode, no iOS SDK, and `swift.org` blocked by egress policy. Nothing was
compiled or run locally.

That means the instruction "build all targets, run all tests" could not be carried out
here. It was carried out in CI instead, which is the only compiler this project has
access to. The loop for every change is:

```
edit -> python3 Tools/swiftcheck.py (local, not a compiler) -> push -> CI compiles and tests
```

CI at the audit baseline: **263 tests across 35 suites pass**, app and widget extension
build for the iOS Simulator, static checks clean.

`swiftcheck` catches bracket balance, unknown types, member references, import policy
and banned write APIs. It does **not** check switch exhaustiveness, type inference,
actor isolation or `Sendable` — all of which have broken CI on this project before.
A green `swiftcheck` is not a green build.

### What the 263 tests do and do not prove

The brief warns against assuming a passing core suite means the integration layer is
correct. That warning is justified, and the numbers show why:

| Target | Reachable by `swift test` | Test files |
|---|---|---|
| `Sources/DriveLayerCore` | yes | 9 |
| `App/DriveLayerApp` | **no** | 0 |
| `App/DriveLayerWidgets` | **no** | 0 |

Every one of the 263 tests exercises `DriveLayerCore`. The app target — the
coordinator, the stores, the OBD connection manager, the location and motion services,
persistence, widgets, notifications — has **zero** automated coverage. `Package.swift`
declares only the core library and its test target; the app target exists solely in
`project.yml` for XcodeGen and is compiled, never tested.

Almost every confirmed bug below lives in that untested layer. That is not a
coincidence, and it is the single most important structural finding of this audit.

**Addressed after this audit.** `c0c88c1` added a `DriveLayerAppTests` target and an
`app-tests` CI job; it now carries 21 tests across 3 suites over the coordinator, the
stores and the recovery paths. The table above is the state at `f1c0489` and is left
standing as the record, but "Test files: 0" and "compiled, never tested" no longer
describe the app target. `swift test` still cannot reach it — that part holds.

---

## Confirmed bugs

### P0-1 — Active trips are never persisted, so crash recovery cannot work

**Status: confirmed.**

`GarageStore.save(trip:)` has exactly two callers:
`DriveSessionCoordinator.swift:294`, inside `case let .ended(trip)`, and
`DriveSessionCoordinator.swift:144`, inside `recoverInterruptedTrips()`.

`.started` and `.updated` never persist anything. The live trip exists only as
`recorder.currentTrip` in memory.

The recovery machinery is already written and correct-looking —
`GarageStore.openTrips(vehicleID:)` filters `!isComplete`, and
`recoverInterruptedTrips()` calls `TripRecovery.finalise` on each. But nothing ever
writes an incomplete trip, so `openTrips` can only ever return an empty array.

**`recoverInterruptedTrips()` is unreachable code guarding against a case that cannot
occur, because the thing that would create that case was never implemented.** A two
hour drive terminated by iOS is lost in full.

### P0-2 — Telemetry accumulates in memory until the trip ends

**Status: confirmed.**

`DriveSessionCoordinator.swift:53` declares `pendingSamples: [TelemetrySample]`.
`collectTelemetry` appends to it (line 329). The only write to disk is
`flushTelemetry(for:)` (line 349), called once, from `case let .ended(trip)`.

`TelemetryFileStore.write(samples:vehicleID:tripID:)` writes **one blob per trip**,
atomically, at the end. There is no chunking and no periodic flush.

Two consequences: an unbounded array grows for the length of the drive, and
termination loses every sample. On a long drive both get worse together.

### P0-3 — `.unknown` DTC capability is treated as unsupported, permanently

**Status: confirmed. This is the most severe finding in the audit.**

The capability model is right. `OBDCapabilityDiscovery` classifies a `NO DATA` reply
to mode 03 as `.unknown`, with an accurate comment explaining that `NO DATA` is
ambiguous — it means either "no stored codes" or "mode not supported".

The consumer then throws that distinction away.
`OBDCapabilityReport.supports(_:)` (`OBDCapabilityDiscovery.swift:73`):

```swift
case .storedDTCs: return storedDTCSupport == .supported
```

`.unknown` returns `false`. And `OBDSession.request` (line 102):

```swift
if let capabilities, !capabilities.supports(pid) { throw OBDError.pidNotSupported(pid) }
```

then `readDiagnosticCodes` swallows it:

```swift
if case .pidNotSupported = error { continue }
```

The failure path in full:

1. Connect to a **healthy** car — no stored codes, which is the normal case.
2. Mode 03 answers `NO DATA`, correctly recorded as `.unknown`.
3. `supports(.storedDTCs)` is now permanently `false`.
4. Every later DTC read is rejected locally, without a command reaching the adapter.
5. A P0301 that appears an hour later is never seen, for the rest of the session.

So DTC reading is disabled precisely because the car was healthy when it connected.
The mode is never retried, and the UI shows "no codes" rather than "not checked".

`supports(_:)` also hard-codes `case .vehicleInformation: return false`, so mode 09
(VIN, calibration ID) can never be read at all.

### P0-4 — Deleting a vehicle leaves scanned documents on disk

**Status: confirmed.**

`GarageStore.delete(vehicleID:)` (line 88) deletes eight SwiftData model types and
calls `TelemetryFileStore.shared.deleteAll(forVehicle:)`. It never touches
`DocumentFileStore`.

`StoredDocument` rows go; the underlying insurance policy, registration certificate
and PUC scans stay in application storage forever, now unreferenced and so
unreachable by any later cleanup.

Single-document deletion is fine — `delete(documentID:)` (line 207) does call
`DocumentFileStore.shared.delete(documentID:)`. Only the vehicle-level path is wrong.

The doc comment above it reads "it must genuinely leave nothing behind."

### P0-5 — "Delete all data" leaves the widget, notifications and live state intact

**Status: confirmed.**

`GarageStore.deleteEverything()` is thorough about storage: nine model types, plus
`TelemetryFileStore.deleteEverything()` and `DocumentFileStore.deleteEverything()`.

What it does not do, and nothing else does either:

- `WidgetSnapshotStore` has `write` and `read` and **no `clear`**. The snapshot JSON in
  the shared app group survives, so widgets keep showing the deleted vehicle's name,
  health and range.
- `WidgetCenter.reloadAllTimelines()` appears once in the whole app, in
  `WidgetSnapshotPublisher`, on publish. It is not called on deletion.
- No scheduled notification is cancelled. `ReminderScheduler` only cancels its own
  requests when rescheduling.
- The Live Activity is not ended.
- The active drive is not stopped, the selected vehicle is not reset, and sensors are
  not wound down.

### P0-6 — The retention setting prunes the wrong thing

**Status: confirmed, and the behaviour is the exact inverse of the intent.**

Settings shows `Picker("Keep engine history for", ...)` over
`AppSettings.retentionChoices = [30, 90, 180, 365]`, default 180.

`AppEnvironment.applyRetentionPolicy()` in full:

```swift
let days = settings.telemetryRetentionDays
guard let cutoff = ... else { return }
store.pruneBaselines(olderThan: cutoff)
```

The setting is named `telemetryRetentionDays`, is described to the user as engine
history, and deletes **learned baselines** — while raw telemetry `.dlts` files are
never pruned by anything.

So choosing a shorter window destroys the lightweight intelligence model that took
months to learn, and leaves every raw byte on disk. That is backwards in both
directions at once.

### P0-7 — Automatic drive detection is a setting that requests no permission

**Status: confirmed.**

`SettingsView.swift:27` is a bare binding:

```swift
Toggle("Record drives automatically", isOn: $settings.automaticTripDetection)
```

`LocationService.requestAlwaysAuthorization()` exists (line 43) and **has no callers**.
Nothing checks the resulting authorisation, and nothing tells the driver when iOS has
denied what the toggle claims to have enabled.

Related, in `DriveSessionCoordinator.swift:155`:

```swift
location.start(fidelity: settings.automaticTripDetection ? .idle : .driving)
```

With automatic detection **off**, the app requests full driving accuracy — the
opposite of the intended power behaviour, and exactly what the brief calls out.

---

## Confirmed P1 bugs

### P1-1 — Barometric altitude is re-anchored to GPS every second

**Status: confirmed.**

`DriveSessionCoordinator.tick()` line 198, comment included:

```swift
// Give the barometer an absolute reference the first time GPS altitude is good.
if let point, let altitude = point.altitudeMetres, (point.verticalAccuracyMetres ?? 99) < 15 {
    motion.anchorAltitude(toGPS: altitude)
}
```

There is no first-time guard. `tick()` runs at 1 Hz, so the anchor is recomputed every
second that vertical accuracy is under 15 m, and `anchorAltitude` recalculates from
scratch each time:

```swift
anchorAltitude = altitude - relativeAtAnchor
```

The comment describes the intended behaviour. The code does not implement it. The
barometer's sub-metre smoothness is continuously overwritten with GPS altitude noise
worth about ten metres — destroying the one property it was chosen for.

`AltitudeSample` does carry provenance (`.barometricRelative` / `.fused`), so the
plumbing for honest labelling exists.

### P1-2 — Road impact detection ignores its own setting

**Status: confirmed.**

`MotionService` contains no reference to `roadImpactDetectionEnabled`. It sets
`motion.deviceMotionUpdateInterval = 1.0 / 20.0` and detects unconditionally.

The setting is only consulted in `DriveSessionCoordinator.collectRoadImpacts`, which
gates **persistence**. So switching it off still runs 20 Hz device-motion processing
and impact classification for the whole drive, and only discards the result.

### P1-3 — No automatic OBD reconnection

**Status: confirmed.**

`OBDConnectionManager.reconnect()` exists and its only caller is
`AppEnvironment.select(vehicleID:)` — a manual vehicle switch.

On `connectionLost` the manager sets `state = .failed(.connectionLost)` (line 145) and
stops. Nothing supervises recovery, so a momentary BLE drop in a tunnel ends live data
for the remainder of the drive. There is no backoff, and the trip's
adapter-connection event methods are not wired to reconnection.

---

## Not applicable / already correct

- **Trip weather capture at drive end** — already correct, and deliberately so:
  captured with the drive rather than looked up later.
- **Provenance model** — `Provenance` and `Provenanced<T>` already exist in the core
  and are used. The brief's `DataProvenance` request is largely already met; it needs
  extending to new metrics, not building.
- **Unavailable is not zero** — `OBDSession.read` throws rather than returning a
  placeholder, and `UnavailabilityReason` has honest per-case copy. The principle is
  established; the gap is coverage, not architecture.
- **Read-only OBD command set** — verified: no mode 04, no clearing, no control
  routines, and `swiftcheck` enforces it. No change needed.
- **Route weather / destination pipeline** — completed and merged in PR #3, including a
  MapKit route provider, so the brief's "no production route source" item is already
  addressed. Distances are re-measured against the driver's position each tick.
- **Road impact persistence** — wired in PR #3; events are persisted and attached to
  the drive. The remaining gap is the setting gate (P1-2), not the storage.

---

## Newly discovered during this audit

1. **The app target has no tests at all.** Stated above; repeated here because it is
   the root cause rather than an item. Every confirmed P0 lives in it.
2. **`recoverInterruptedTrips()` is dead code.** Not merely incomplete — it is a
   correct implementation of a recovery path that can never trigger, which reads as
   working crash recovery on inspection. This is worse than no recovery code, because
   it looks like the box is ticked.
3. **Mode 09 is unreachable.** `supports(_:)` returns a hard-coded `false` for
   `.vehicleInformation`, so VIN and calibration ID can never be read even where the
   ECU offers them.
4. **`TelemetryFileStore.deleteEverything()` removes the directory itself**, not just
   its contents. Subsequent writes depend on `ProtectedDirectory.url(named:)`
   recreating it; that path is `lazy var root`, already resolved, so after a delete-all
   the process may hold a URL to a directory that no longer exists.
5. **`AppSettings.retentionChoices` has no "forever" option** while the comment claims
   retention is deliberately finite. That is a defensible product choice, but the brief
   asks for it, and the setting does not currently do what it says regardless.

---

## Known limitations and hardware-dependent features

These are real constraints, not gaps to be closed. Documenting them accurately is the
point.

| Area | Status | Why |
|---|---|---|
| Device run, real adapter, real car | **unverified** | No hardware available |
| CarPlay | **unverified** | Needs Apple's driving-task entitlement |
| WeatherKit | **unverified** | Needs a paid capability |
| VoiceOver, largest Dynamic Type | **unverified** | Needs a device |
| Elevation provider | **not implemented** | iOS ships no first-party elevation API. A web service breaks the local-first promise; a bundled dataset is very large. Left as a product decision rather than invented. |
| Turbo actuator position | **unavailable** | Not exposed by standard OBD-II |
| GPF soot loading | **unavailable** | Not exposed by standard OBD-II. A specification is not a sensor reading. |
| Oil temperature, fuel rail pressure | **unknown until captured** | Standardised PIDs exist; whether the Hyperion ECU answers them is unknown without the car |
| Arbitrary CAN access via CarPlay | **impossible** | Apple does not provide it |

## Harrier-specific assumptions

Recorded so they can be checked against the real car later.

- The reference vehicle is a **2026 Tata Harrier, 1.5 L Hyperion Turbo GDI petrol**.
- `SupportedVehicles.offeredProfileIDs` is the single list deciding what a driver may
  choose. Widening it restores the multi-vehicle pickers; nothing else in the app
  decides how many cars exist.
- Generic diesel and petrol profiles remain in the catalogue, unoffered. The
  architecture stays multi-vehicle; the product does not.
- **No manufacturer-specific PID has been validated.** The Tata-specific PID table is
  intentionally empty. Nothing may be added to it without a real capture from the car.
- Nothing in the intelligence layer is hard-coded to this vehicle: every part reads its
  car through `VehicleProfile`.

## Implementation status

Every P0 and three P1s are fixed and verified by CI: compiled for the iOS Simulator,
with 326 tests across 41 suites passing. The reasoning for each fix is in its commit
message; `ROADMAP.md` tracks what remains.

| Finding | Status | Verified by |
|---|---|---|
| P0-1 active trips not persisted | Fixed | Core tests + app build |
| P0-2 telemetry held in memory until trip end | Fixed | 29 `TelemetryJournal` tests |
| P0-3 unknown DTC capability read as unsupported | Fixed | 11 tests, incl. the brief's exact scenario |
| P0-4 vehicle deletion leaves scanned files | Fixed | App build only — call site is app-target |
| P0-5 delete-all leaves widgets, reminders, live state | Fixed | App build only — call site is app-target |
| P0-6 retention prunes baselines, not telemetry | Fixed | `deleteCompacted` retention tests |
| P0-7 automatic detection requests no permission | Fixed | 7 `AutomaticDetectionStatus` tests |
| P1-1 barometric altitude re-anchored every second | Fixed | 14 `AltitudeFusion` tests |
| P1-2 road-impact setting gated only persistence | Fixed | App build only — sensor gate is app-target |
| P1-3 no automatic OBD reconnection | Fixed | 9 `ReconnectPolicy` tests |
| Mode 09 unreachable | Fixed | Covered in the capability tests |
| `deleteEverything` removed its own directory | Fixed | `TelemetryJournal` tests |
| Relative altitude displayed as absolute | Fixed | Covered by the fusion tests |

Four of these are covered only by "it compiles", because their call sites are in the
app target. In each case the logic underneath was moved into the core and tested
there — `TelemetryJournal`, `AltitudeFusion`, `ReconnectPolicy`,
`AutomaticDetectionStatus` — which is real coverage of the behaviour but not of the
wiring. An app test target remains the outstanding structural item, and it is the
first thing in "Next up".

### Still open from this audit

- **DTC event-driven refresh.** Codes are only read on connect and on demand. Monitor
  status (PID 0x01) is decoded as display text rather than a structured MIL state and
  DTC count, so there is nothing to trigger a refresh from.
- **BLE discovery validation.** Any peripheral with a notify and a write characteristic
  is still offered as a possible adapter.
- **BLE state restoration.** Not implemented; needs a device to verify against.
- **Full location lifecycle audit.** The worst case is fixed. The complete set of
  states in the brief — armed, foreground, recording, route analysis — has not been
  walked through against real iOS behaviour.
- **Phase 3 onwards.** The Hyperion pivot proper, product UX, CarPlay and polish.
