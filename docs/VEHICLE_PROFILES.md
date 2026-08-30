# Vehicle profiles

A `VehicleProfile` describes a *model*. A `Vehicle` is one driver's car. Two people
with the same Harrier share a profile and never share a Vehicle — trips, baselines,
fuel, maintenance and documents all belong to the Vehicle.

## Validation tiers

Every profile declares one, and it is shown to the driver in the Garage and during
onboarding.

### `validated`
Specifications confirmed against published documentation, **and** any
vehicle-specific telemetry in the profile verified on a real car of this model.
Only a `validated` profile may expose manufacturer-specific data, and only then does
the app report capability Level 3.

**No profile currently ships at this tier.**

## What is offered today

DriveLayer is a one-car app for now. `SupportedVehicles.offeredProfileIDs` lists the
profiles a driver may choose, and it currently holds one: the Tata Harrier below.

The rest of the catalog stays where it is. Narrowing what is *offered* is not the
same as narrowing what exists — the generic profiles are what a second car will be
built on, and the generic diesel one is the fixture the Diesel Guardian tests need.
Adding a car means adding its profile and putting its ID in that list; nothing else
in the app decides how many vehicles exist.

### `experimental`
Model-level specifications are known, but no vehicle-specific telemetry has been
proven. DriveLayer restricts itself to standard OBD-II data.

- **Tata Harrier — 1.5 TGDi Hyperion turbo petrol, Adventure X+** (`tata.harrier.2026.adventure-x-plus`)

  Rated power and torque are deliberately absent: the engine is recent enough that
  a half-remembered brochure figure would be an invention, and a wrong figure would
  quietly feed the load and economy wording. Tank capacity and the service interval
  are carried over from the diesel variant and are labelled `genericDefault`, not
  `publishedSpecification` — the UI shows that difference, and a driver can enter
  their own. Being a petrol, it declares no DPF extension points and Diesel Guardian
  reports `not applicable` for it.

### `generic`
No model-specific knowledge: standard OBD-II behaviour and generic engineering
defaults. Works with any OBD-II vehicle.

- **Generic diesel** (`generic.diesel`)
- **Generic petrol** (`generic.petrol`)

## Every number carries its source

`SpecSource` is attached to each specification, and the UI shows it:

| Source | Meaning |
|---|---|
| `publishedSpecification` | A published manufacturer figure for this model |
| `ownerManual` | Taken from the owner's manual by the driver |
| `userProvided` | The driver entered it |
| `genericDefault` | A generic engineering default, **not specific to this vehicle** |

This matters in practice. The Harrier profile's 50 L tank and 15,000 km service
interval are `publishedSpecification`; its air filter interval and its coolant and
voltage bands are `genericDefault`, and the app says so — the maintenance list marks
them "Generic default — check your manual", and an insight built on one carries lower
confidence.

## What the reference profile does and does not claim

The Tata Harrier profile is `experimental`, not `validated`, and its notes say why:

> Standard OBD-II data only. DriveLayer does not use unverified Tata-specific
> requests.
>
> Tank capacity and the periodic service interval are published figures — confirm
> them against your owner's manual.
>
> Temperature and voltage bands are generic diesel engineering defaults, not
> Tata-published limits. DriveLayer learns your car's own baselines from your drives.

`expectedStandardPIDs` is **empty**, deliberately. What a car reports is decided by
runtime capability discovery, never by a guess written into a profile.

## Operating ranges are scoped to an engine condition

A voltage range that does not say whether the engine is running is a false-alarm
generator: 14.1 V is normal while charging and abnormal at rest. So ranges carry an
`OperatingCondition` — `any`, `engineRunning`, `engineOff`, `warmedUp` — and the
health evaluator picks the right one from what the vehicle reports.

Bands escalate outermost-first, so a value can never be both `watch` and `critical`,
and a range with no bands at all evaluates to `unknown` rather than `normal`.

## Manufacturer capabilities

```swift
ManufacturerCapability(id: "dpf.soot-load", kind: .dpfSootLoad, displayName: "DPF soot load")
// validation defaults to .unvalidated, and validatedRequest is nil
```

These exist so the app can *show what enhanced support would add* while being explicit
that it is unavailable. The type refuses to carry a request unless `validation ==
.validated`, whatever the caller passes — and a test asserts it.

## Adding a profile

The following models are planned. They are **not** in the catalog, because a profile
with unsourced specifications is worse than no profile:

Tata Safari · Mahindra Scorpio-N · Mahindra XUV700 · Jeep Compass · Hyundai Creta ·
Kia Seltos · MG Hector · Volkswagen Taigun · Skoda Kushaq

Until one is added, any of these works today with the generic diesel or petrol
profile, plus a tank size the driver enters. That is a genuine, working level of
support.

To add one properly:

1. Add an entry to `VehicleProfileCatalog`.
2. Give every number a `SpecSource`. If you cannot source it, leave it `nil` — the
   app handles absent specs and asks the driver.
3. Set the tier to `generic` or `experimental`. `validated` requires verified
   vehicle-specific telemetry, not just good specifications.
4. Leave `expectedStandardPIDs` empty and `manufacturerCapabilities` unvalidated.
5. Add a case to `VehicleProfileTests.testCatalogueProfilesAreInternallyConsistent`
   if the profile needs anything beyond the shared invariants.

## Promoting a profile to `validated`

Requires all of:

- Specifications confirmed against published documentation or the owner's manual.
- At least one manufacturer-specific request verified on a real car of that model:
  reproducible across sessions, read-only, and with a scaling confirmed against a
  known reference.
- `evidenceNote` recorded on the capability explaining how it was verified.
- Tests covering the decoder for that request.

Anything less stays `experimental`. DriveLayer would rather show a driver less than
show them something it cannot stand behind.
