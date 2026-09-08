# DriveLayer release validation

This checklist is release evidence, not a feature list. A row is complete only when its date, device, vehicle, adapter, app build, result, and evidence link are recorded. Simulator success cannot replace physical hardware.

## Required equipment

- Physical iPhone running the release candidate
- Tata Harrier 2026 Adventure X+ with the 1.5L Hyperion Turbo GDI petrol engine
- The production BLE OBD adapter
- A real CarPlay head unit
- Apple CarPlay Simulator on the same SDK used for the archive

## Vehicle capability record

Export the sanitised capability report from DriveLayer. Record the ELM identity, negotiated protocol, supported standard PID bitmap, every decoded PID that returned a plausible real value, transient `NO DATA` responses, diagnostic mode outcomes, and recovery after ignition changes. Do not add manufacturer PIDs without a source, request, addressing, raw response, formula, unit, expected range, real result, independent sanity check, and repeated-drive evidence.

| Scenario | Required evidence | Status |
|---|---|---|
| Cold start | Plausible coolant start, one warm-up record, no stale prior values | UNTESTED |
| Warm start | No false cold claim or duplicate warm-up | UNTESTED |
| City | BLE stability, trip distance, fuel inputs, trim gating | UNTESTED |
| Highway | Sustained polling, cruise baselines, range and CarPlay ranking | UNTESTED |
| Climb | Load/thermal behavior and terrain only from route evidence | UNTESTED |
| Long drive | Three-hour BLE, storage, background, thermal and memory behavior | UNTESTED |
| Phone locked/background | Connection, recording, checkpoints and recovery | UNTESTED |
| Phone call/navigation active | Audio interruption and CarPlay recovery | UNTESTED |
| BLE interruption | Gap recorded, bounded retry, same adapter only | UNTESTED |
| Adapter unplug/replug | Honest disconnect and recovery | UNTESTED |
| Ignition cycle | Mode 01 `NO DATA` cooldown and recovery | UNTESTED |
| CarPlay reconnect | Now/Drive/Ahead/Ask restore with current drive | UNTESTED |
| No network | Route/weather unavailable without fabrication | UNTESTED |
| Location denied | Honest permission and unavailable states | UNTESTED |
| WeatherKit unavailable | No forecast substitute appears | UNTESTED |
| Database recovery | Existing data opens or recovery is offered | UNTESTED |

## Diagnostic truth cases

- A successful zero-code scan says no codes were found only for supported modes that completed.
- Timeout, `NO DATA`, disconnect, unsupported mode, and partial scan never become “no faults.”
- A code appearing after an earlier `NO DATA` response is found by a later scan.
- MIL and readiness stay unavailable unless their structured request succeeds.

## CarPlay validation

Run the native templates in CarPlay Simulator and on the real head unit. Validate light/dark glanceability, urgent bypass, de-escalation hysteresis, current-drive priority, unavailable Ahead data, and Listening → Understanding → Answering. Exercise microphone denied, timeout, model unavailable, interruption, cancel, and disconnect.

## Release decision

Release remains **NO-GO** until production-critical rows have recorded evidence and archive signing confirms the driving-task CarPlay entitlement.
