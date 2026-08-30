# DriveLayer

**AI intelligence for the car you already own.**

DriveLayer reads your vehicle, the road, the weather and your own driving history,
and tells you what actually matters. It is not a speedometer, an OBD scanner with a
nicer skin, or a wall of gauges.

```
RPM 2140 · Coolant 96 °C · Load 71% · 62 km/h
```

is data. This is the product:

```
LONG CLIMB
8.4 km uphill remaining
Engine temperature normal for a climb of this intensity
Engine load slightly higher than your usual drives
Heavy rain expected about 14 km ahead
```

---

## Verification status — read this first

The development environment for this work had **no Swift toolchain**: `swift.org` is
blocked by the sandbox's egress policy, and there is no macOS, no Xcode, and no iOS
SDK. Nothing could be compiled locally.

So compilation was moved to CI instead. `.github/workflows/ci.yml` runs three jobs —
static checks on Ubuntu, `swift build` + `swift test` on macOS, and an Xcode build of
the app and widget for the simulator. Check the badge and the Actions tab for the
current state; the honest summary is that the core reached the compiler on its first
CI run and is being driven to green from there.

| What | Where it happens |
|---|---|
| `Tools/swiftcheck.py` static checks | Locally and in CI, on every change |
| Swift compilation of the core | CI (`macos-14`), not locally |
| `swift test` (229 tests) | CI (`macos-14`) |
| Xcode build of app + widget | CI (`macos-15`) |
| Device run, CarPlay, real adapter | Not performed — needs hardware |

`Tools/swiftcheck.py` is a static consistency checker written for this project. It is
not a compiler and does not pretend to be one, but it catches a real class of
mistakes: bracket balance (comment- and string-aware), duplicate type declarations,
references to types that are declared nowhere, `Type.member` references against the
members that type actually declares, import policy violations, banned write/control
APIs, and missing paths in `project.yml`. It found real errors during development.

It also has a known blind spot the first CI run exposed: it cannot resolve
leading-dot member references like `.engineOff`, because those need type inference.
That is exactly how a real bug survived to CI — `BaselineContext` had no `engineOff`
case, so the battery trend insight could never have fired. The compiler caught it;
the checker could not have.

Three genuine logic bugs have been found and fixed so far: document reference-number
extraction matching dates once separators were stripped, a gradient calculation that
systematically understated slope, and the battery baseline context above. The first
two came from writing tests, the third from CI.

## Getting started

```bash
# Run the logic tests — no Xcode, no car, no phone required
swift test          # 229 tests

# Generate the Xcode project and open it
brew install xcodegen
xcodegen generate
open DriveLayer.xcodeproj

# Static checks (no toolchain needed)
python3 Tools/swiftcheck.py Sources Tests App
```

You do not need a car to develop DriveLayer. Turn on the simulator in
**Settings → Adapter → Use the simulator** and pick one of thirteen scenarios: a
motorway cruise, a cold start, hot city traffic, a mountain climb, a long descent, a
tired battery, an overheating engine, sustained high load, a tank running low, a
stored DPF code, missing sensors, a dropping Bluetooth link, or an adapter returning
garbage. The simulator speaks real ELM327 text, so simulated drives run through the
production parser, decoders and session — not around them.

## What it does

**Level 1 — phone only.** Trip recording, terrain and gradient from GPS and the
barometer, weather context, fuel logging and economy, maintenance schedules, the
digital glovebox, driving analytics.

**Level 2 — with a Bluetooth OBD-II adapter.** Live engine data, coolant, load,
battery voltage, fuel level and rate, trouble codes with plain-language
explanations, health trends, and baselines learned from your own car.

**Level 3 — enhanced vehicle profile.** Manufacturer-specific read-only data, for
models where it has been verified. **No vehicle offers this today**, and DriveLayer
does not ship guessed manufacturer requests to pretend otherwise.

## Principles

**We listen to your car. We don't control it.** The OBD command set contains no
mode 04, no clearing of trouble codes, no configuration, no control routines. The
static checker enforces this.

**Unknown is not zero.** Every value carries provenance — measured, estimated,
inferred, or unavailable — as part of the data model, not as a UI decoration. A
vehicle that does not report fuel level shows a dash and an explanation, never `0%`.

**Say what you can't know.** Ask the copilot when your particulate filter last
regenerated and it will tell you it cannot know, explain why standard OBD-II does not
report it, and then tell you what it *can* see about your driving pattern.

**Correlation is not cause.** Trip comparisons say "associated with", never
"because".

**Nothing leaves the device.** No account, no sync, no upload, no analytics. See
[docs/PRIVACY.md](docs/PRIVACY.md).

## Repository layout

```
Sources/DriveLayerCore/    Foundation-only product logic — no UIKit, SwiftUI,
                           CoreBluetooth, CoreLocation or SwiftData, so all of it
                           is testable with `swift test`
  Core/                    Status vocabulary, provenance, statistics, load states
  Vehicle/                 Vehicle profiles, capability levels, the profile catalog
  OBD/                     Protocol, PID catalog, decoders, DTCs, session, simulator
  Telemetry/               Sampling policy and the compact series codec
  Trips/                   Trip model, recorder state machine, analytics, comparison
  Location/                Geo maths, gradient, elevation
  RoadIntelligence/        Terrain features, road impact detection, reports
  Weather/                 Weather models and the route-change analyser
  Intelligence/            Baselines, insight rules, insight engine
  Diesel/                  Diesel Guardian and DPF extension points
  Fuel/  Maintenance/  Health/  Copilot/

App/DriveLayerApp/         The iOS app: design system, services, persistence, screens
App/DriveLayerWidgets/     WidgetKit extension and the Live Activity
App/Shared/                Types shared between app and extension
Tests/DriveLayerCoreTests/ 217 tests, weighted towards failure cases
Tools/swiftcheck.py        Static consistency checker
docs/                      Architecture, product, OBD, CarPlay, profiles, privacy, roadmap
```

## Documentation

- [ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the pieces fit and why
- [PRODUCT.md](docs/PRODUCT.md) — what each screen is for
- [OBD.md](docs/OBD.md) — supported PIDs, the read-only policy, the simulator
- [VEHICLE_PROFILES.md](docs/VEHICLE_PROFILES.md) — validated vs experimental vs generic
- [CARPLAY.md](docs/CARPLAY.md) — the CarPlay surface and how to enable it
- [PRIVACY.md](docs/PRIVACY.md) — what is stored, where, and for how long
- [ROADMAP.md](docs/ROADMAP.md) — what is done, what is next

## Reference vehicle

Development is calibrated around a **Tata Harrier, 2.0 Kryotec diesel**, but nothing
is hard-coded to it: it is one entry in a profile catalog, and the generic diesel and
petrol profiles work with any OBD-II vehicle. See
[VEHICLE_PROFILES.md](docs/VEHICLE_PROFILES.md) for how to add another.

## Licence

See [LICENSE](LICENSE).
