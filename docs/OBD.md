# OBD-II

## Read-only policy

DriveLayer reads. It does not write.

The `OBDMode` enum contains only: current data (01), freeze frame (02), stored DTCs
(03), pending DTCs (07), vehicle information (09), permanent DTCs (0A). **Mode 04 —
clear diagnostic information — is deliberately absent**, along with any manufacturer
control routine.

This is enforced, not just intended. `Tools/swiftcheck.py` fails the build on:

- `writeValue(` outside `BluetoothOBDTransport.swift`
- `ATSH`, `ATCRA`, `ATCAF0` — raw CAN addressing
- a literal `"04"` command string
- identifiers matching `clearDTC`, `resetECU`, `flashECU`, `forceRegen`

DriveLayer will not clear a trouble code even when a driver asks. Clearing a code
erases the evidence a workshop needs and fixes nothing; the app says so where the
button would otherwise be.

## Connection model

```
OBDTransport (protocol)          connect / disconnect / send(String) -> String
   ├── BluetoothOBDTransport     CoreBluetooth, in the app target
   └── SimulatedOBDTransport     in the core, emits real ELM327 text

OBDSession (actor)               adapter setup, capability discovery, decoded reads
   └── OBDResponseParser         ELM327 text -> bytes
   └── OBDPIDCatalog             bytes -> values
   └── OBDCapabilityDiscovery    what this vehicle actually reports
```

The transport moves text; everything above it is testable. Adding Wi-Fi or a wired
adapter means one new conformance and nothing else.

### Adapter initialisation

`ATZ`, `ATE0`, `ATL0`, `ATH0`, `ATS1`, `ATAT1`, `ATSP0`.

Spaces are left **on** (`ATS1`) deliberately. The throughput saved by `ATS0` is not
worth the parsing ambiguity between a three-character CAN header and a run of data
bytes. The parser handles both anyway.

### Response parsing

`OBDResponseParser` handles, and is tested against:

- plain responses (`41 0C 1A F8`)
- an 11-bit CAN header (`7E8 04 41 0C 1A F8 00 00`) — header and ISO-TP length byte
  stripped, padding discarded
- spaces disabled (`410C1AF8`)
- ISO-TP multi-frame: a length header line plus indexed continuation lines
- multiple ECUs answering the same request — first taken, others counted
- `NO DATA`, `?`, `STOPPED`, `BUFFER FULL`, `UNABLE TO CONNECT`, `CAN ERROR`,
  `BUS INIT: ERROR`, `LV RESET`
- negative responses (`7F 01 12`)
- `SEARCHING...` chatter and command echo
- non-hex tokens, truncated frames, frames claiming more bytes than they carry

Any leading byte of `0x07` or less is treated as a protocol control byte, which is
unambiguous: every positive response starts at `0x41` or above, and a negative
response starts at `0x7F`.

## Supported PIDs

Only parameters whose scaling is part of the published SAE J1979 standard are
decoded. Nothing here is a guessed formula.

| PID | Parameter | Unit | Refresh |
|-----|-----------|------|---------|
| 01 | Monitor status (MIL, code count) | — | slow |
| 04 | Calculated engine load | % | fast |
| 05 | Engine coolant temperature | °C | medium |
| 0A | Fuel pressure | kPa | slow |
| 0B | Intake manifold pressure | kPa | fast |
| 0C | Engine speed | rpm | fast |
| 0D | Vehicle speed | km/h | fast |
| 0E | Timing advance | ° | medium |
| 0F | Intake air temperature | °C | medium |
| 10 | Mass air flow | g/s | fast |
| 11 | Throttle position | % | fast |
| 1F | Run time since engine start | s | medium |
| 21 | Distance with warning light on | km | rare |
| 2F | Fuel tank level | % | slow |
| 31 | Distance since codes cleared | km | rare |
| 33 | Barometric pressure | kPa | slow |
| 42 | Control module voltage | V | slow |
| 43 | Absolute load value | % | medium |
| 45 | Relative throttle position | % | medium |
| 46 | Ambient air temperature | °C | slow |
| 47 | Absolute throttle position B | % | medium |
| 4C | Commanded throttle actuator | % | medium |
| 51 | Fuel type | — | rare |
| 5A | Relative accelerator pedal position | % | fast |
| 5C | Engine oil temperature | °C | medium |
| 5E | Engine fuel rate | L/h | fast |
| 61 | Driver's demanded torque | % | medium |
| 62 | Actual engine torque | % | medium |
| 63 | Engine reference torque | N·m | rare |

Plus the supported-parameter bitmaps: 00, 20, 40, 60, 80, A0, C0.

Each parameter carries a **refresh class** — fast (1 s), medium (5 s), slow (30 s),
rare (300 s), each with a slower background interval. Polling coolant at 1 Hz for a
three-hour drive costs battery and bus bandwidth for nothing.

Each also carries a **plausibility band**. A value outside it decodes but is flagged,
and flagged readings never reach the UI or a baseline. 16,000 rpm is not a reading;
it is a dropped byte.

### Known but not decoded

These identifiers exist in the standard, and capability discovery will report them as
present, but DriveLayer has not verified their scaling and will not guess:

`78`, `79` (exhaust gas temperature), `7A`, `7B` (diesel particulate filter),
`7C` (DPF temperature), `83` (NOx), `9A`, `9D`, `9E`.

The Debug Center and the Telemetry screen list them under "reported but not
interpreted", which is the honest answer.

## Capability discovery

Discovery walks the supported-parameter bitmaps: request `0100`, and only request
`0120` if bit `0x20` came back set, and so on. Nothing is displayed unless it appears
in the result — DriveLayer never assumes a PID exists because a similar car has it.

Diagnostic mode support is **tri-state**. `NO DATA` on mode 03 is genuinely
ambiguous — it can mean "no stored codes" or "mode not supported" depending on the
ECU — so the report records `.unknown` rather than picking one and being wrong.

The session also learns during a drive: a PID that answers `NO DATA` or a negative
response is not asked again, and one that fails transiently five times is rested and
the connection marked degraded.

## Diagnostic trouble codes

Mode 03/07/0A responses are decoded into `P`/`C`/`B`/`U` codes. Some ECUs prefix the
code pairs with a count byte and some do not; an odd payload length can only be
explained by a leading count byte, so that is the signal used, and the count itself is
treated as advisory.

`DTCCatalog` holds plain-language explanations for eighteen common generic codes.
For anything else it explains what the code's *structure* guarantees — P04xx is
auxiliary emission controls, P03xx is ignition or misfire — and says plainly that it
does not hold a specific definition. Manufacturer-specific codes (P1xxx, P3xxx) are
identified as such and never guessed at.

Every explanation separates the standard definition from plain language, symptoms,
things worth checking, and driving guidance — and the UI repeats that **a code
describes what the vehicle observed, not which part has failed**.

## The simulator

Thirteen scenarios, a deterministic seeded model, and real ELM327 text:

1. Normal highway drive · 2. Cold start · 3. Hot weather city traffic ·
4. Long mountain climb · 5. Long descent · 6. Low battery voltage ·
7. High coolant temperature · 8. Sustained high engine load · 9. Fuel running low ·
10. DPF trouble code · 11. Sensors unavailable · 12. Adapter drops and reconnects ·
13. Invalid OBD responses

The model is first-order thermal lag, load from a speed profile, and fuel flow from
load and engine speed. It is not an engine simulator; it exists to exercise
DriveLayer's own logic. Every value it emits is encoded with the exact inverse of the
catalog's decoder, which is what makes a simulated drive a real test of the decoding
path.

Note what scenario 10 does **not** do: it stores `P2002` and turns on the warning
light, and simulates no soot-load telemetry — because DriveLayer cannot read that on
a real car either.

## Manufacturer-specific PID policy

DriveLayer ships **no** manufacturer-specific requests.

`ManufacturerCapability` exists as an extension point, with a `validation` field of
`unvalidated`, `observed` or `validated`. The type enforces its own rule: a
capability that is not `validated` cannot carry a request, whatever a caller passes
to its initialiser — there is a test for exactly that.

To add one, you need a real vehicle of that model, a reproducible read-only response,
a verified scaling, and evidence recorded in the profile. Until then the app shows
what enhanced support *would* add and says clearly that it is unavailable. That is
worse marketing and better engineering.
