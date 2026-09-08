# Current status

Updated 2026-09-08. This file supersedes historical readiness claims in README, AUDIT and ROADMAP.

## Release decision: NO-GO

Version in project.yml: 0.1.0 (local build setting 1; TestFlight numbering is workflow-managed).
Only selectable production profile: Tata Harrier 2026 Adventure X+ 1.5L Hyperion turbo GDI petrol. Selection is not proof of hardware validation. No manufacturer-specific request has been validated by this work.

## Baseline evidence

Inspected baseline commit: e5c5e88bfef4fc2780d6791a17137321834646a4.
GitHub CI run 34204888927 passed the four existing jobs. Latest TestFlight run 34146454586 succeeded. Those runs predate this work.
Local Windows baseline: swiftcheck checked 168 files / 489 declared types, zero errors and warnings after installing PyYAML. bundlecheck: five checks passed. No local Swift, Xcode, iOS SDK or CarPlay Simulator is installed. iOS 27 API compatibility has not been verified.

## Current fix group: telemetry trust and polling

- Explicit trusted reads require good quality, finite values and nonnegative age within the caller's freshness window.
- Last-known entries remain available for labelled diagnostics, including first-frame rejection reasons.
- Live intelligence, trip inputs and downsampling use trusted reads.
- Fuel uses the original trusted sample timestamp and source; range retains simulation provenance.
- MAF and timing advance are mapped into production polling; diagnostic-only PIDs remain separate.
- A production baseline collector rejects non-measured samples and uncertain engine context, deduplicates sensor timestamps, and learns intake-minus-ambient separately for warmed contexts.
- Existing persisted model shapes and telemetry codec indices are unchanged.

Validation of this group: local static checks passed; new Swift regression tests have been added. CI execution results will be recorded after the run completes. Do not interpret added tests as executed tests.

## Capability status

IMPLEMENTED: read-only standard OBD decoding/discovery, trip recording, local storage, fuel log, maintenance/document records, on-device copilot fallback, CarPlay templates, widgets and Live Activity.
PARTIAL: contextual engine intelligence, baseline quality corrections, diagnostic workspace, contextual route/weather, voice lifecycle, ownership reports, multi-car adapter ownership, migration recovery.
BLOCKED BY HARDWARE: confirmed Harrier PID inventory, all Harrier-specific validation claims, long-drive BLE and real CarPlay validation.
BLOCKED BY API: route elevation source and source-backed exact-vehicle manual content need an approved source/integration; iOS 27 SDK validation requires an available Mac toolchain.
FUTURE: validated manufacturer telemetry, external TPMS integration, Watch after phone/CarPlay stability.

## Entitlements and services

CarPlay driving-task entitlement and CarPlay scene are declared in the repository. The successful release workflow checks signed entitlements; this is distinct from head-unit validation.
WeatherKit is disabled: DLWeatherKitEnabled is false and the production entitlements do not enable WeatherKit. Weather-related features must show unavailable.
Hardware evidence is not supplied in this checkout. See REAL_CAR_VALIDATION.md; unchecked scenarios remain release blockers.

## Remaining blockers

- Full repository audit and later implementation phases remain in progress; this is not an App Store readiness certificate.
- BLE timeout/callback cleanup, transient PID recovery, database opening recovery.
- CarPlay simulator matrix, installed iOS 27 API review, voice and alert lifecycle validation.
- Hardware, accessibility and sustained background operation evidence.
- Source-backed profile specifications/service schedules and privacy copy review.
