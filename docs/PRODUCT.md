# Product

## The idea

```
CAR DATA + ROAD DATA + WEATHER + DRIVER HISTORY + VEHICLE PROFILE + TRIP CONTEXT
                                    ↓
                        ACTIONABLE DRIVE INTELLIGENCE
```

Every screen is built to interpret rather than display. The test applied throughout:
*would a driver do something differently because of this?* If not, it does not earn
its place.

## Navigation: four tabs, not seven

The brief lists seven areas. Four of them are not things anyone opens daily, and
seven bottom tabs is how an app stops feeling designed.

| Tab | Why it is a tab |
|---|---|
| **Today** | Opened every day. Answers "is my car fine?" |
| **Drive** | Opened every drive. |
| **Trips** | Opened weekly. |
| **Vehicle** | Health, and the door to everything lower-frequency. |

Insights are surfaced on Today and expand to a full screen. Garage, Fuel,
Maintenance, Glovebox and Settings live behind the Vehicle tab. The Debug Center is
behind Settings, where a developer will look and a driver will not.

## Today

Vehicle health with a one-line explanation; range and fuel; last drive; weather; the
insights worth knowing; and what is due next.

```
Good morning
Harrier
Ready to drive — connected to your car

VEHICLE          ● Healthy
                 Everything DriveLayer can see looks normal.

RANGE  ~326 km   FUEL  58%
LAST DRIVE 42.6 km · 47 min · 12.8 km/L
WEATHER  29°  Rain expected about 22 km ahead

WORTH KNOWING
  BATTERY WATCH
  Battery voltage has been trending below your normal baseline.

NEXT SERVICE
  Periodic service — due in about 1120 km or 34 days.
```

The line under the vehicle name says what DriveLayer can currently see — phone only,
connected, or enhanced — which is more useful than a decorative subtitle.

## Drive Mode

One large number, four supporting ones, and at most three pieces of context.

```
RECORDING
78 km/h

DISTANCE 12.4 km   DURATION 18 min   ALTITUDE 912 m   RANGE ~326 km

CONTEXT
  LONG CLIMB     5.6 km remaining at about 5.4% average.
  HEAVY RAIN     Expected about 14 km ahead.
  ENGINE NORMAL  Temperature is within your normal range for a climb of this intensity.
```

When there is nothing to say, it says so rather than filling the space. Deeper
telemetry is one tap away and lists only what the vehicle actually reports — plus,
honestly, what it reports that DriveLayer cannot yet interpret.

## Trips

A list grouped by month with distance, duration and economy, and a summary of drives,
total distance and typical economy.

Trip detail is six sections — overview, comparison, efficiency, vehicle, terrain,
events — and each one disappears entirely when there is nothing behind it.

Repeated routes are matched on a coarse grid and compared against the driver's usual
run, with wording that never claims a cause:

> Fuel economy was about 13% lower than your usual run of this route, associated with
> about 6 more minutes of idling.

Three previous drives are required before "typical" means anything, and a drive that
is unremarkable produces no summary at all.

## Vehicle

Systems, not sensors. Engine, Battery, Fuel system, Diagnostics, Diesel usage,
Maintenance — each with a status, a one-line headline, and a detail screen showing
what the judgement was based on.

An unassessable system reads `Unknown` with a reason and a way to fix it, never
`Normal`. Trouble codes get plain-language explanations that separate the standard
definition from symptoms, things worth checking, and driving guidance — and repeat
that a code describes what the vehicle observed, not which part has failed.

## Diesel Guardian

The feature where honesty does the most work. DriveLayer can measure how you drive
and cannot measure your particulate filter, so it reports the first as fact and the
second as inference:

> **DIESEL USAGE**
> 75% of your last 8 drives were shorter than 8 km, and most appear not to have
> reached full operating temperature. DriveLayer can't read your particulate filter's
> actual condition — no standard OBD-II parameter reports it — so this describes your
> driving pattern, not the filter.
>
> *Diesels generally prefer an occasional longer run at steady speed. Your owner's
> manual has the manufacturer's guidance for this — follow that rather than a rule of
> thumb.*

It never says "your DPF is 68% full". It never offers a regeneration. And where
coolant temperature is unavailable, warm-up completion is marked `inferred` from
drive duration rather than passed off as measured.

## The copilot

On-device, deterministic, offline. Every sentence is badged **Measured**,
**Estimate**, **Inference** or **General information**.

> **"When was the last likely DPF regeneration?"**
>
> I can't tell you when your filter last regenerated. Standard OBD-II doesn't report
> soot load or regeneration status, and I won't guess at a number. *(Measured)*
>
> What I can tell you is that 72 percent of your recent drives were short journeys.
> *(Measured)*
>
> Most journeys this week were shorter than the engine's normal warm-up period.
> *(Inference)*
>
> For the filter's actual condition you'd need a workshop tool with manufacturer
> diagnostics.

Answers while driving are two sentences; the detailed version is on the phone while
parked.

## Onboarding

Six steps, two of which are compulsory. Welcome; add a vehicle; the three capability
levels; the two permissions, each explained before it is asked for; optional adapter
pairing; ready. It never blocks on an adapter, because the app is genuinely useful
without one.

## Every state, everywhere

Loading, success, partial, empty, unavailable, permission denied, disconnected,
error. `UnavailabilityReason` carries its own copy so the explanation lives next to
the condition that caused it, and no screen invents its own wording.

Never:

```
RPM 0    Coolant 0 °C    Battery 0 V
```

Always:

```
VEHICLE DATA
Connect a supported Bluetooth OBD-II adapter to unlock live engine
and vehicle information.
```
