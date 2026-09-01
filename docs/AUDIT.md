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

---

# Hyperion Alpha audit — P0 pass

A second audit, carried out at `115e7ef` against the Hyperion Alpha brief. Every item
below was checked against the code before anything was changed, and each records how it
was verified. Where the brief's premise turned out to be wrong, that is recorded too.

Same verification environment as the first audit, and it has not improved: Windows, no
Swift toolchain, no Xcode, no iOS SDK. Nothing here was compiled locally. CI is the only
compiler this project has, so "verified" below means `swiftcheck` locally plus the four
CI jobs on push. A green `swiftcheck` is still not a green build.

## Summary

| # | Item | Classification |
|---|---|---|
| P0-1 | Logging abstraction / cross-platform compile | **NOT APPLICABLE** |
| P0-2 | Telemetry flush is fire-and-forget | **CONFIRMED** |
| P0-3 | Chunk numbering overwrites existing chunks | **CONFIRMED** |
| P0-4 | Journal / open-trip reconciliation | **CONFIRMED** |
| P0-5 | LocationService state model | **CONFIRMED** |
| P0-6 | Automatic detection reuses a stale GPS fix | **CONFIRMED** |
| P0-7 | Unexpected BLE disconnect never reconnects | **CONFIRMED** |
| — | Reconnect mechanics once triggered | **ALREADY FIXED** (`ddc7dcc`) |
| P0-7b | Transport ready before notifications confirmed | **CONFIRMED** |
| P0-7c | Pairing screen lists every BLE device | **CONFIRMED** |
| P0-8 | SensorGate accepts impossible values | **CONFIRMED** |
| P0-9 | Persistence versioning | **CONFIRMED** |
| P0-10 | Simulator contaminates real data | **CONFIRMED** |

Nine confirmed, one not applicable, one already fixed.

> **Superseded in part by the third audit below.** P0-1 was classified NOT APPLICABLE
> here on the grounds that no shipped platform lacks `os`. That reasoning was sound for
> the *app* and wrong for the *package*, which is what `swift test` builds — see
> "H-1 · logging" in the third audit. P0-8 was confirmed and fixed here, but only the
> half that was looked at: the gate's yield logic. That the gate had no callers at all
> was not noticed. See "H-2 · sensor gate".

## P0-1 — Logging abstraction · NOT APPLICABLE

The brief said to treat the repository as broken and not to proceed. It is not broken:
CI is green on all four jobs at `115e7ef`.

`PrivacyLog.logger(_:)` is declared inside `#if canImport(os)`
(`Core/PrivacyLog.swift:16-20`) and its 13 call sites are unguarded, so on a platform
without `os` this would be a compile error rather than a silent no-op. But
`Package.swift` declares only `.iOS(.v17)` and `.macOS(.v13)`, both of which ship `os`,
and CI has no Linux job. This is a portability gap against a platform the product does
not target, not a live defect.

Two related claims in the brief were checked and hold up: no privacy-sensitive value is
logged (identifiers go through `redactedIdentifier`, document numbers through
`redactedDocumentNumber`, coordinates through `coarse` at roughly 1 km), and logging is
not noisy — every call sits in an error branch, never in the 1 Hz sample loop.

Deferred deliberately. A faithful no-op shim has to reimplement the `privacy:` string
interpolation from `os` to keep call sites unchanged, which is real work in service of a
platform nobody ships. Recorded here so the decision is visible rather than forgotten.

## P0-2 — Telemetry flush is fire-and-forget · CONFIRMED

`DriveSessionCoordinator.checkpoint(force:now:)` clears the buffer on the line after it
queues the write:

```
455  TelemetryFileStore.shared.appendChunk(samples: pendingSamples, ...)
458  pendingSamples.removeAll()
```

`TelemetryFileStore.appendChunk` (`Persistence/FileStores.swift:60-63`) returns `Void`
and drops the journal's `Bool` on the floor across a `queue.async` hop, so the caller
cannot learn that a write failed. `queue.async` only enqueues, so at line 458 the write
has not necessarily started. `flushTelemetry(for:)` (`:462-469`) has the same shape via
`finalise`.

Consequence: a failed write, or termination in the window between enqueue and execution,
loses the samples with no copy retained anywhere.

Flush triggers today are the 1 Hz drive loop gated to 20 s, scene phase leaving
`.active`, and trip end. There is no flush on OBD connection change and none on memory
warning.

## P0-3 — Chunk numbering · CONFIRMED · fixed in this pass

`appendChunk` named files from `contentsOfDirectory(atPath:).count + 1`. Those agree
only while the sequence has no gaps, and a gap is what a removed or unreadable chunk
leaves behind. With `chunk-000001` and `chunk-000003` on disk the count is two, the next
name is `chunk-000003`, and `write(to:options:[.atomic])` replaces it.

The comment above the line claimed a repeat was harmless. That is true of read ordering
— `journalledSamples` merges by timestamp — and says nothing about the overwrite.

Now one past the highest sequence present. Compaction was checked and does not depend on
contiguous numbering: `finalise` reads through `journalledSamples` and `merge`, which
sort by timestamp. Filename order only breaks ties between samples sharing a timestamp,
so zero-padded sortable names are retained rather than moving to UUIDs.

## P0-4 — Journal / open-trip reconciliation · CONFIRMED

Of the three cases the brief names, two are handled and the third is not.

- Open trip + journal — handled. `recoverInterruptedTrips()` finalises and compacts.
- Open trip + no journal — handled, degrades cleanly to an empty recovery.
- Journal + no open trip — **unhandled.** Nothing enumerates journal directories and
  diffs them against known trip IDs, so orphans accumulate for the life of the install.

Two aggravating details. `TelemetryFileStore.interruptedTrips()` already exists and its
doc comment says it is read at launch alongside the interrupted drives in the database —
it has zero production call sites and is reached only by tests. And
`recoverInterruptedTrips()` runs only for the *selected* vehicle, so recovery for any
other vehicle waits until that vehicle is selected.

Retention will never clean orphans up: `deleteCompacted(olderThan:)` filters
`pathExtension == "dlts"` on the compacted layer and documents that it leaves journalled
chunks alone by design.

Salvage is mechanically easy and worth doing rather than deleting blind: journal
directories are named `<vehicleUUID>-<tripUUID>` and `parseIdentifiers` recovers both
IDs from the path alone.

## P0-5 — LocationService state model · CONFIRMED, and worse than described

`beginUpdates(fidelity:)` guards on `authorization.allowsTracking` and returns before
assigning `fidelity` or `isTracking`, so a request made while `.notDetermined` leaves no
trace. `locationManagerDidChangeAuthorization` then replays only when `isTracking` is
already true — which it never is, because the guard is what prevented it being set. The
request is lost permanently.

Worse than the brief assumed: the first call at launch is `start(fidelity: .idle)`, so
when permission is granted after launch, even significant-change monitoring never
starts, `location.latest` stays `nil`, and no drive can be detected at all.

`isTracking` is one Boolean doing duty as both "tracking was wanted" and "tracking is
running", and `fidelity` is only assigned on the success path, so it does not reliably
record what was requested either.

`.notDetermined`, `.denied` and `.restricted` are handled identically — silent early
return, no stored intent.

Separately, `automaticDetectionStatus` is computed from the settings flag and
authorization only, never from `isTracking`, so the UI reports automatic detection as
"Active" in exactly the state where it cannot operate.

There are no tests for this state machine.

## P0-6 — Stale GPS fix · CONFIRMED

`resolvedSpeedKmh` is asymmetric: the OBD branch checks
`telemetry?.value(.vehicleSpeedKmh, freshWithin: 6, now: now)`, and the GPS branch checks
only `isUsableForRouting`, which inspects horizontal accuracy and never the timestamp.

`LocationService.latest` is replaced only when `didUpdateLocations` fires, while the
drive loop ticks at a fixed 1 Hz. The arming check is
`now.timeIntervalSince(since) >= startSustainSeconds` — wall clock, evaluated per tick.
So one stale fix with an elevated speed, re-read for twelve consecutive ticks, promotes
`.arming` to `.recording` because time passed, not because movement continued.

Adapter presence and engine-running are not used to raise confidence. `engineRunning`
acts only as a veto when explicitly `false`; when `nil`, auto-start proceeds on GPS
speed alone. Motion data is not passed to `TripRecorder` at all.

Existing tests always build a fresh `GeoPoint` whose timestamp equals `now`, so the
missing freshness check is untested.

## P0-7 — Unexpected BLE disconnect · CONFIRMED

`didDisconnectPeripheral` fails a *pending* request with `.connectionLost`, but the poll
loop sleeps 250 ms between reads, so the ordinary drop happens with nothing in flight.
Then `failPendingRequest` and `completeConnection` are both no-ops and the only durable
effect is `isReady = false`.

The next `send()` fails its `isReady` guard and throws `.notConnected`.
`OBDSession.sendRaw` updates `state` only for `.connectionLost`, so the session keeps
reporting `.ready`. And the single reconnect trigger,
`OBDConnectionManager.swift:222`, is gated on `.connectionLost` too.

Net effect: for the most likely kind of disconnect, supervised reconnect never starts.
The app re-fails every 250 ms forever, logging, while the UI still claims a live link.

There is no transport-level connection-state event stream — `OBDTransport` exposes only
`connect`, `disconnect`, `send`, and everything above it infers liveness from request
outcomes.

### Reconnect mechanics · ALREADY FIXED (`ddc7dcc`)

Once triggered, the existing machinery is sound and was left alone: the drive continues
phone-only, disconnect and reconnect are recorded as trip events, the trip ID survives,
the adapter is reinitialised and capabilities rediscovered rather than reused, polling
resumes, overlapping reconnect loops are guarded, and backoff is 1, 2, 5, 10, 30 seconds
holding at 30 indefinitely. Its correctness is entirely conditional on P0-7, because
today it is never reached for an idle drop.

## P0-7b — Ready before notifications confirmed · CONFIRMED

`adopt(characteristics:)` calls `setNotifyValue(true, for:)` and then, in the same
function, sets `isReady = true` and resolves the connect continuation.
`didUpdateNotificationStateFor` is not implemented anywhere in the repository, so
nothing ever checks `characteristic.isNotifying`. A command can therefore be written
before the subscription is active, and the reply arrives as a notification the OS is not
yet delivering — a silent stall until the 2 s timeout.

## P0-7c — Pairing screen lists every BLE device · CONFIRMED

`BluetoothAdapterScanner.centralManager(_:didDiscover:...)` appends every advertising
peripheral to `discoveries`, sorted by signal strength, with no filter at all. The
`looksLikeAdapter` heuristic does exist but is a `private static func` on
`BluetoothOBDTransport`, used only by that type's own auto-connect path and structurally
unreachable from the scanner. `candidateServiceUUIDs` is declared and never referenced by
anything — scanning passes `withServices: nil`.

`adopt` accepts any peripheral exposing one notify-or-indicate and one
write-or-writeWithoutResponse characteristic on any service. No service UUID check, no
name check, and no ELM handshake before the transport reports success; `ATZ` validation
happens a layer up in `OBDSession.start()`, after the transport has already declared
itself ready, so a non-adapter is caught only as a generic timeout.

## P0-8 — SensorGate accepts impossible values · CONFIRMED

`SensorGate.offer` increments `consecutiveRejections` for every rejection and then
yields once it reaches three **without consulting the reason**:

```
192  consecutiveRejections += 1
194  guard consecutiveRejections >= rejectionsBeforeYielding else { return nil }
196  lastAccepted = (value, timestamp)
```

Traced concretely: coolant with a plausible range of -40...215, offered 500 three times,
is accepted on the third call and thereafter reported as a measured 500 with no rejection
note. Every subsequent 500 is accepted outright, because its rate of change against the
previous 500 is zero.

The same path accepts a known sensor default — three reports of 0 rpm while running
become a believed measurement of an engine turning at zero.

Only an impossible rate of change has any business yielding; that is the case the design
comment and the existing tests actually justify. An out-of-range value and a sensor
default must never yield, and no existing test drives either past the third offer, so the
bug is entirely uncovered.

Verified separately, against the code rather than the test that asserts it: the gate
never substitutes zero for a rejected reading.

Metadata gap behind the bug: a gated value is a `Provenanced<Double>` carrying value,
provenance, timestamp and a free-text `basis`. There is no unit and no quality enum, so
there is no structured way to mark a value as suspect — once accepted it is
indistinguishable from a clean reading.

## P0-9 — Persistence versioning · CONFIRMED

Nine `@Model` types each store a `payload: Data` produced by `StoredCoding`
(`Persistence/StoredModels.swift:231-243`), a bare `JSONEncoder`/`JSONDecoder` pair.
There is no version of any kind: `payloadVersion`, `schemaVersion`, `VersionedSchema`
and `SchemaMigrationPlan` return zero hits across `App/` and `Sources/`.

Eight load sites discard failures with `compactMap { try? $0.value() }`
(`GarageStore.swift:44, 118, 151, 170, 190, 201, 223, 305`). A decode failure does not
throw, log, or quarantine — the row silently stops existing.

`DriveLayerSchema.models` carries the comment "bump the version and add a migration
stage rather than editing an existing record shape". There is no version to bump. The
comment describes a discipline that was never implemented.

Consequence: rename one field on `Trip`, ship it, and every user's history disappears on
next launch with nothing surfaced.

## P0-10 — Simulator contaminates real data · CONFIRMED

`DataProvenance` has no `.simulated` case, so simulated readings are stamped as measured
exactly like a real adapter's.

The path is unguarded end to end. `OBDConnectionManager` builds `SimulatedOBDTransport`
and wraps it in the same `OBDSession`; `Source.isSimulated` exists but is used only for
display and never consulted by `pollDueParameters`.
`DriveSessionCoordinator.tick()` takes telemetry on connection state alone,
`collectTelemetry` accumulates baseline aggregates with no source check, and
`flushPending()` merges them into the persisted store through the same
`store.merge(aggregates:vehicleID:)` used for real drives.

Trips recorded under the simulator go through the same `store.save(trip:)` and carry no
flag — `Trip` has no `isSimulated` field — so they are later read back mixed
indistinguishably with real drives.

The toggle ships in Release. The simulator `Toggle` in `AdapterSetupView` has no
`#if DEBUG` and is reachable from Settings, Vehicle and Onboarding; the Debug Center
scenario picker is equally ungated.

Existing scenarios: `normalHighway`, `coldStart`, `hotCityTraffic`, `mountainClimb`,
`longDescent`, `lowBattery`, `highCoolantTemperature`, `highEngineLoad`,
`fuelRunningLow`, `dpfWarning`, `sensorUnavailable`, `linkDropAndRecover`,
`invalidResponses`. Note that `dpfWarning` is diesel product logic and is in scope for
removal under P1.

---

# Hyperion Alpha audit — third pass

Carried out at `6e563c7`, re-verifying the brief against current source before changing
anything. Same environment, and it still has not improved: Windows, no Swift toolchain,
no Xcode, no iOS SDK. CI remains the only compiler this project has.

Two of the findings below were classified in the second audit and are being revised, not
re-reported. Both revisions have the same shape: **a type existing and being tested was
mistaken for the product using it.**

## Summary

| # | Item | Classification |
|---|---|---|
| H-1 | Logging blocks cross-platform `swift test` | **CONFIRMED** — revises P0-1 · fixed |
| H-2 | SensorGate is not in the production path | **CONFIRMED** — extends P0-8 · fixed |
| H-3 | Reconnect can bind to another car's adapter | **CONFIRMED** · fixed |
| H-4 | An adapter is remembered before it validates | **CONFIRMED** · fixed |
| H-5 | Sensor quality/freshness model | **PARTIAL** · quality added, units not |

## H-1 · logging — CONFIRMED, revising P0-1's NOT APPLICABLE

The previous classification reasoned that `Package.swift` targets only iOS and macOS,
both of which ship `os`, so an `os`-only API was a portability gap rather than a defect.

The premise is right and the conclusion does not follow. `swift test` builds the
*package*, not the app, and `DriveLayerCore` is Foundation-only by design precisely so it
can be built and tested without an SDK — that is the stated reason the core exists as a
separate module. `TelemetryJournal` is core product logic, and it called
`PrivacyLog.logger(.persistence).error(...)` at four sites while `logger(_:)` was declared
inside `#if canImport(os)`.

So on any platform without `os` the core did not compile, and the cross-platform build
the package advertises was broken. CI could not show it: every job that compiles the core
runs on macOS.

Verified by the compiler, not by inspection. The fix moved the call sites to a
level-based API that exists unconditionally, and the CI build then failed on
`App/Shared/WidgetSnapshot.swift:102` — a tenth call site my own `findstr` search had
missed, because `App\*.swift` does not recurse into subdirectories. Nine more were found
the same way once the search was rewritten to walk the tree.

Worth recording as a method note: the search tool was wrong, and the compiler was the
thing that said so.

## H-2 · sensor gate — CONFIRMED, extending P0-8

P0-8 found that `SensorGate.offer` yielded after three rejections without consulting the
reason, and fixed it. That fix is present and correct at `SensorSanity.swift:218`.

What was not asked is whether anything called `SensorGate`. Nothing did:

```
Sources/.../Hyperion/HyperionGuardian.swift:94   (a comment)
Sources/.../Hyperion/SensorSanity.swift:167      (the declaration)
Sources/.../Hyperion/SensorSanity.swift:187      (its own ==)
```

`HyperionGuardian:94` even observes that `HeatSoakAnalyser` and `SensorGate` "existed,
were tested, and were reachable from no production code" — the guardian was wired up, the
gate was not.

The live path ran one check: `OBDReading.isPlausible`, a stateless range test computed at
decode time, which `VehicleTelemetry.apply` used to drop a reading. Traced concretely at
`OBDConnectionManager.swift:223`, the only call site. So the range half of the promise
held and nothing else did — a value inside the band could jump 80 °C in one second, sit
byte-identical for minutes after the ECU stopped answering, or be the value a sensor
sends when it has nothing, and each was stored as `measured` and passed to the baselines,
the trip, the insight rules and the screen.

This is why the P0-8 fix did not help in practice: it corrected the yield logic of a
component the product never invoked. The gate now lives inside `VehicleTelemetry.apply`,
the single point where a reading is admitted, so it cannot be bypassed by a later caller.

Tests for it start at raw OBD bytes and run through the real catalog decoder, because
tests written against `SensorGate` directly would have passed before this change too.

## H-3 · adapter selection — CONFIRMED

`BluetoothOBDTransport.didDiscover` checked only whether a peripheral's name looked like
an adapter. It never compared the identifier against the saved target.

Unreachable while iOS has the peripheral cached, because `retrievePeripherals` returns it
and the scan never starts. Reachable exactly when the adapter is powered down, out of
range, or uncached after a reboot: `beginConnectionIfPowered` falls through to a scan, and
the first peripheral advertising an OBD-ish name wins.

In a driveway that is invisible. In a car park it is another car, and DriveLayer would
attribute a stranger's engine to the driver's Harrier — including into the learned
baselines, which is the one thing P0-10 was written to prevent for simulated data.

## H-4 · adapter persistence — CONFIRMED

`connect(toAdapter:name:)` wrote `settings.lastAdapterIdentifier` and `lastAdapterName`
as its first act, before attempting the connection. Those two values are what
`connectIfPossible()` reconnects to on every launch.

So anything tapped on the pairing screen became "the driver's adapter" permanently,
regardless of outcome — headphones whose name passed the heuristic, or an adapter that
connected over BLE but never completed its ELM handshake. Nothing cleared it.

`rememberConnectedAdapter()` already guarded on `isConnected`, so the durable store was
right while the settings pair driving auto-reconnect was not. Two mechanisms recording
the same fact, disagreeing.

## H-5 · sensor quality model — PARTIAL

P0-8 noted the metadata gap: a gated value had value, provenance, timestamp and free-text
`basis`, but no structured way to mark a reading suspect.

`SensorQuality` now covers `good`/`suspect`/`stale`/`invalid`/`unavailable`, and
`VehicleTelemetry.Entry` carries it with the rejection reason. A refused reading holds the
last good value as `suspect` with its reason, or stays absent — never zero.

**Not done:** units are still implicit in metric names (`coolantTemperatureC`,
`vehicleSpeedKmh`) rather than carried as data. That is a wider change than this pass, and
the naming convention makes the current state safe rather than merely lucky. Recorded so
it is visible instead of assumed complete.

---

# Product surface audit — after the first device install

The first TestFlight build reached a phone, and the verdict was "looks cheap, no
animations, no graphics". That is a finding, and it was checked before being acted on.

| # | Finding | Classification |
|---|---|---|
| S-1 | Hyperion had no screen on the phone | **CONFIRMED** · fixed |
| S-2 | Ask Harrier did not read the Hyperion assessment | **CONFIRMED** · fixed |
| S-3 | One animation in the entire app | **CONFIRMED** · fixed |
| S-4 | Trip polylines stored, never rendered | **CONFIRMED** · fixed |
| S-5 | Telemetry formatter mis-rendered trims and pressures | **CONFIRMED** · fixed |
| S-6 | Simulator controls exposed in Release | **NOT APPLICABLE** — already gated |
| S-7 | CI push trigger skipped `feature/**` | **CONFIRMED** · fixed |

## S-1 · Hyperion — CONFIRMED

`grep hyperion App/` found two lines, both in `CarPlayPresenter.swift`: a single
`CPListItem` showing the overall label. `HyperionAssessment` - six areas, each with a
status, headline, detail, baseline comparison, confidence and evidence - was computed on
every analysis pass and shown to a phone user nowhere. The P1-12 entry in ROADMAP read
"IMPLEMENTED — 2 of 6 areas assessed", which was true of the analysis and silent about
the surface. It now has a tab.

## S-2 · Ask Harrier — CONFIRMED

`engineStatus` answered from `snapshot.health.systems["Engine"]`: one word. The
`VehicleContextSnapshot` had a `DieselSummary` and no Hyperion section at all, on a
petrol-only product. So the Hyperion screen could say "intake running warm, low
confidence" and the copilot, asked the same second, said "normal". A `HyperionSummary`
now travels in the snapshot, built from the same assessment, and four intents answer
from it.

One invention caught in my own first draft of the faults answer, and worth recording
because it is the failure class this product is most about: with no codes and no
diagnostics area it said "the warning light is off". Nobody had read the lamp. It now
says the lamp is unread, and a test pins that.

## S-3 · Motion — CONFIRMED

`grep` for `withAnimation`, `.animation(`, `.transition(`, `sensoryFeedback`,
`symbolEffect` and `matchedGeometryEffect` across the app returned one hit: the speed
number on Drive Mode. Every card was a flat fill; every screen popped into existence
fully formed. The design system's own comment described "a calm instrument panel".

The fix is one material and one spring applied everywhere, which is what stops a
redesign producing six different-looking screens. Reduce Motion drops every translation
and scale and keeps every fade; that was checked per component, not assumed.

## S-6 · Simulator in Release — NOT APPLICABLE

The brief asked for `#if DEBUG` around the simulator toggle. It was already there, one
level up: `AppSettings.isSimulatorAvailable` is `#if DEBUG`, the toggle's section is
behind it, and the stored `useSimulator` flag is ANDed with it on load - so a debug build
that left the flag on cannot make a release build simulate. Left as is; scattering
`#if DEBUG` through the views would be worse than the single gate.

## What CI cannot verify here

Every screen in this pass compiles and its tests pass, on real Xcode. None of it has
been rendered: there is no simulator or device in this environment. Shadow intensity in
light mode, the panel highlight, and whether the cascade feels quick or slow are all
things the next TestFlight install will show before I see them. That is stated in the
PR rather than left to be discovered.
