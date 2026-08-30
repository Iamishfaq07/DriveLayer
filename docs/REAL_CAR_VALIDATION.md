# Real-car validation

What cannot be verified without the actual vehicle, and exactly how to verify it once the
car and a validated adapter are in front of you.

This file exists because the development environment has no Swift toolchain and no
hardware: no macOS, no Xcode, no iOS SDK, no adapter, no Harrier. CI compiles and runs the
test suite, which is a real check of logic and no check at all of behaviour against an
ECU. Everything below is therefore **BLOCKED ON HARDWARE** until someone runs it.

Record results in this file as they are obtained. A procedure with no recorded result has
not been run, and a feature whose procedure has not been run is not finished, whatever the
tests say.

**Vehicle:** 2026 Tata Harrier, 1.5 L Hyperion turbo GDI petrol.
**Adapter:** a BLE ELM327-class adapter, validated per V-1 before anything else is trusted.

DriveLayer is read-only. None of these procedures write to the vehicle, clear codes, or
change any ECU behaviour. If a step appears to require that, stop — the step is wrong.

---

## V-1 — Adapter validation and GATT readiness

Covers P0-7b. `didUpdateNotificationStateFor` is now implemented and readiness waits for
`characteristic.isNotifying`, which cannot be exercised without a real BLE peripheral.

1. Plug the adapter in; ignition on, engine off.
2. Settings → Adapter. Confirm the adapter appears under nearby adapters, and confirm
   **your phone's other Bluetooth devices do not** (P0-7c). Note anything wrongly listed
   or wrongly hidden, with its advertised name.
3. Connect. Time from tap to a live reading.
4. Confirm the **first** request does not time out. This is the specific failure the
   readiness gate fixes: previously the transport declared itself ready the instant
   `setNotifyValue(true)` was called, so on a slower clone the first reply arrived as a
   notification iOS was not yet delivering.
5. Repeat five times, including once with the phone's Bluetooth toggled off and on.

**Record:** adapter make, advertised name, firmware string from `ATI`, connect time,
first-request outcome, anything mis-listed at step 2.

## V-2 — Unexpected disconnect and supervised reconnect

Covers P0-7, the highest-value P0 fix and the one least provable in CI.

The bug: a drop with no request in flight left only `isReady = false`, so the next `send`
reported `.notConnected`, which failed the `.connectionLost` guard that is the sole
reconnect trigger. The poll loop sleeps 250 ms between reads, so this is the *ordinary*
case, not an edge case.

1. Start a drive with the adapter connected. Confirm live telemetry.
2. Unplug the adapter mid-drive, during the gap between polls rather than during a burst.
3. Confirm **all** of the following:
   - the drive does **not** end;
   - recording continues on GPS alone;
   - an adapter-disconnected event appears on the drive;
   - reconnect attempts begin, at roughly 1, 2, 5, 10, then 30 s;
   - the UI stops claiming a live link.
4. Plug the adapter back in. Confirm the same trip ID continues, an adapter-reconnected
   event is recorded, capabilities are rediscovered, and polling resumes.
5. Repeat with the ignition cycled off and on instead of unplugging.

**Record:** whether reconnect began without user action, time to recovery, trip ID
continuity, and the events written to the drive.

## V-3 — Location permission granted after launch

Covers P0-5. The tests cover the reachable half; CoreLocation in a test bundle reports
`.notDetermined` and grants nothing, so the replay itself needs a device.

1. Delete and reinstall the app, so location permission is undecided.
2. Launch. Do **not** grant permission yet. The first thing the app does is request
   `.idle` fidelity, which will be refused.
3. Grant "Always" from the onboarding prompt.
4. Confirm significant-change monitoring starts **without relaunching** — previously the
   request was forgotten and nothing started until the next launch, while Settings
   reported automatic detection as "Active".
5. Confirm Settings shows "Active" and not "Not running".
6. Repeat granting only "While Using the App" and confirm the honest downgrade wording.
7. Revoke permission in iOS Settings mid-session and confirm the app stops claiming to
   be tracking.

**Record:** whether monitoring started without a relaunch, and what Settings said at
each step.

## V-4 — Fuel system status and fuel trims

Blocked on hardware and on P1. Nothing here is implemented yet; the procedure is written
now so the data is captured on the first drive rather than the third.

1. Connect a validated adapter. Engine cold — ideally after an overnight stand.
2. Read PID `01 03` and record the raw bytes. Confirm the decoded loop state says open
   loop while cold.
3. Drive gently and watch for the transition to closed loop. Record the coolant
   temperature and elapsed time at which it happens.
4. Once in closed loop, record PID `01 06` and `01 07` raw bytes alongside the decoded
   percentages, at warm idle and at steady cruise.
5. Record fifteen minutes of steady driving.
6. Export the capability report.
7. Confirm no sensor-default value (a flat 0, a flat −40) has been accepted as a real
   reading.

**Record:** raw bytes against decoded values for `01 03`, `01 06`, `01 07`; the coolant
temperature at closed-loop entry; whether trims are reported at all on this ECU.

## V-5 — Which PIDs the Hyperion ECU actually exposes

The point of the whole exercise, and the thing that turns every P1 hypothesis into a fact.

1. Connect a validated adapter, engine running and warm.
2. Run the capability scan.
3. Record the supported Mode 01 PID bitmap verbatim, and which diagnostic modes answer.
4. For each PID DriveLayer wants, record: supported or not, the raw bytes, the decoded
   value, and whether it looks physically plausible for the conditions.
5. Note per-PID response latency and anything that destabilises polling.
6. Export sanitised, and attach the export here.

Of particular interest, because P1 currently assumes them: `01 03` fuel system status,
`01 06`/`01 07` fuel trims, `01 0B` MAP, `01 33` barometric pressure, `01 0E` timing
advance, `01 10` MAF, `01 5C` oil temperature, `01 5E` fuel rate, `01 61`/`01 62`/`01 63`
torque, catalyst temperature, and `01 52` ethanol.

**Record:** the bitmap, then a row per PID. Anything unsupported is not a bug — it is the
answer, and DriveLayer must show it as unavailable rather than invent it.

## V-6 — Estimated boost from MAP minus barometric pressure

Blocked on V-5 confirming both PIDs answer.

1. With the engine off and ignition on, record MAP and BARO. They should agree closely;
   a large disagreement means one of them is not what it claims.
2. At warm idle, record both. Manifold pressure should sit below ambient.
3. Under steady load, record both.
4. Confirm DriveLayer labels the difference as estimated everywhere it appears, and never
   as a boost sensor reading.

**Record:** paired MAP/BARO readings at each state, and the engine-off delta, which is
the calibration check.

## V-7 — Long drive soak

1. A drive of at least two hours with the adapter connected and the app backgrounded for
   most of it.
2. Confirm afterwards: one trip and not several; telemetry continuous with no gap beyond
   a recorded disconnect; no orphan journal directories; memory stable; battery drain
   acceptable.
3. Confirm the pending-sample count in the Debug Center returns to zero after each
   checkpoint. A count that stops falling means writes are failing — which the app now
   survives, retaining samples rather than discarding them, but which still needs
   explaining.

**Record:** duration, trip count, telemetry sample count, peak memory, battery used.

---

## Results

None yet. No procedure in this file has been run: there is no vehicle and no adapter in
the development environment.
