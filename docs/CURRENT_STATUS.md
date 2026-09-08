# DriveLayer current status

Updated 2026-09-08. This document supersedes readiness claims in historical audit and roadmap files.

## Release decision: NO-GO

The only selectable production profile is Tata Harrier 2026 Adventure X+ with the 1.5L Hyperion Turbo GDI petrol engine. The profile name is configuration, not proof of hardware validation. No Tata manufacturer PID is enabled.

## Status

- **IMPLEMENTED:** read-only standard OBD polling and discovery; partial diagnostic snapshots; provenance-preserving telemetry and evidence; sensor availability; honest health coverage; trip recording; fuel log; maintenance and documents; widgets and Live Activity; deterministic adaptive CarPlay Now/Drive/Ahead/Ask; native voice phases; Mechanic Mode; per-vehicle baselines, warm-up history, and preferred adapters.
- **TESTED:** static and bundle checks; automated regression coverage for diagnostic truth, provenance, Mode 01 recovery, health coverage, ranking/hysteresis, voice identifiers, warm-up tracking, fuel-trim gating, and storage relationships. Exact latest CI counts belong in the PR result after the final run.
- **PARTIAL:** Mechanic Mode exports a sanitised capability report and settings exports owner data. Dedicated diagnostic JSON, telemetry CSV, and trip GPX remain incomplete. Battery logic distinguishes resting and charging voltage; real cranking sampling is unvalidated. Ownership reports, event recorder, tyres, and post-drive briefing remain incomplete.
- **UNTESTED:** physical Harrier telemetry, production adapter over real drives, real CarPlay, iOS 27 hardware voice, accessibility, background endurance, and upgrade migration from an App Store database.
- **BLOCKED:** App Store release until Harrier, BLE, CarPlay, signed entitlement, migration, and privacy/export/deletion evidence is recorded in `RELEASE_VALIDATION.md`.
- **FUTURE:** Tata-specific PIDs, TPMS, door/boot state, manufacturer turbo/transmission/drive-mode/GPF telemetry, and additional production vehicles.

## Data truth

Unknown values remain absent, stale values retain timestamps, rejected samples stay diagnostic-only, simulation cannot enter production learning, estimated boost remains estimated, and an empty diagnostic code list is reassuring only after relevant supported requests succeed. Health says “Healthy” only for full assessed coverage; partial normal evidence says assessed systems look normal.

## Entitlements and external services

The repository declares the CarPlay driving-task scene and entitlement. A signed archive check and real head-unit test remain required. WeatherKit is disabled by configuration and entitlement, so weather remains unavailable in production. MapKit supplies road distance when available; terrain cannot be authoritative until a real elevation provider is validated.

## Vehicle capability matrix

- **MEASURED when supported and fresh:** standard OBD speed, RPM, coolant, load, intake and ambient temperature, MAP, BARO, MAF, timing, fuel level, trims, fuel-loop state, module voltage, MIL/readiness, and standard diagnostic codes.
- **ESTIMATED:** fuel range and journey reserve from trusted fuel/economy inputs; boost only from aligned fresh MAP minus BARO accepted by the estimator.
- **INFERRED:** thermal phase, learned comparisons, health and Hyperion conclusions, battery trend, and drive context.
- **UNAVAILABLE:** TPMS pressure, door/window/boot state, oil life, battery state of health, remote control, authoritative route elevation, and WeatherKit in production.
- **UNVALIDATED:** every Tata-specific signal and every standard PID on the named Harrier until a sanitised real-car session is recorded.

## Release blockers

1. Record the real Harrier capability bundle and plausible values.
2. Complete long-drive, background, interruption, ignition-cycle, and adapter recovery tests.
3. Validate CarPlay Simulator and a real head unit, including voice and urgent states.
4. Validate archive signing and the granted CarPlay entitlement.
5. Upgrade an existing installed database and verify the new persisted models.
6. Finish diagnostic/telemetry/trip exports and verify delete-all coverage.
7. Complete accessibility, privacy-copy, offline, and degraded-state review.
