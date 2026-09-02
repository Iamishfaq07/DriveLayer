# Privacy

## In one paragraph

DriveLayer has no account, no server, no sync and no analytics. Your drives,
telemetry, baselines, fuel log, maintenance history and documents are stored on your
device and stay there. The only network requests the app makes are to Apple's weather
service, and only when weather is configured and enabled.

## What is collected, and where it lives

| Data | Where | Protection | Retention |
|---|---|---|---|
| Vehicles, trips, fuel, maintenance, documents metadata | SwiftData, app container | Until first unlock | Until you delete it |
| Engine telemetry | One file per drive, app container | Until first unlock, excluded from iCloud backup | Your retention setting (30/90/180/365 days) |
| Document scans | App container | **Complete** file protection | Until you delete them |
| Baseline aggregates | SwiftData | Until first unlock | Pruned to your retention setting |
| Widget snapshot | Shared app group | Standard | Overwritten each analysis |

Telemetry is excluded from iCloud backup deliberately: nobody wants hundreds of
megabytes of engine samples in their backup, and it is regenerable by driving.

Documents get **complete** protection rather than the weaker until-first-unlock
level, because a registration certificate or insurance policy should be unreadable
whenever the phone is locked, and nothing in DriveLayer needs to read one in the
background.

## Location

Location is used for three things: recording drives, measuring terrain and gradient,
and working out where weather changes on the road ahead.

Fidelity follows what the app is doing, which is a privacy property as much as a
battery one:

- **Idle** — significant-change monitoring only.
- **Recording a drive** — ten-metre accuracy.
- **Drive Mode open** — best accuracy, only while you are looking at it.

Background location is only requested if you turn on automatic trip recording, and
the app explains what it buys before asking.

Route polylines are downsampled before storage — a point every 25 m or 20 s, not
every fix.

## What is never logged

Enforced through `PrivacyLog`, which is the only logging entry point:

- **Precise coordinates.** `PrivacyLog.coarse` rounds to roughly a kilometre, and
  even that is only used where a coordinate is genuinely needed in a log.
- **Registration numbers and VINs.** `Vehicle.redactedDescription` is what goes in a
  log; it contains neither.
- **Document numbers.** `DocumentRecord.redactedDescription` shows the last four
  characters and masks the rest.
- **Document contents.** Never logged at all.
- **Tokens or credentials.** There are none — there is no account.

## What is sent off the device

**Weather, and only weather.** When enabled, DriveLayer asks Apple's WeatherKit for
conditions at a location. That is the only outbound request the app makes.

**The copilot does not change that, and it now uses a language model.** DriveLayer
asks Apple's on-device system model (Foundation Models) through
`FoundationModelsCopilot`. That model runs on the iPhone itself: there is no request,
no API key, no account, and nothing about your car leaves the device to answer a
question. `requiresNetwork` on that provider is `false` and means it.

What the model is allowed to see is a `VehicleContextSnapshot` rendered as a flat
fact sheet — nothing else, ever. A snapshot is a few dozen summarised fields — health
statuses, trip summaries, fuel figures, recent insight headlines — with **no route,
no coordinates, no VIN, no registration and no telemetry stream**. A test asserts
exactly that. `CopilotProviding` takes a snapshot rather than telemetry precisely so
that a model provider physically cannot be handed data the snapshot does not contain.

What the model is allowed to *say* is checked rather than trusted. Every number in a
generated answer must be a number it was given; if it rounds one, converts one, does
arithmetic, or invents a reading outright, the answer is discarded and the
deterministic copilot answers instead. That check (`AnswerGuard`) is a pure function
in the core with tests written from the direction of an attack, because "a model
would not do that" is not a safety mechanism.

If the model is unavailable — an older iPhone, Apple Intelligence switched off, the
model still downloading — the deterministic `LocalCopilot` answers everything, as it
did before, and the app tells you which one is talking rather than quietly degrading.

## Your controls

In **Settings → Your data**:

- **Export this vehicle's data** — everything about one vehicle as readable JSON.
- **Delete all data** — every vehicle, drive, baseline, fuel entry, document and
  telemetry file, gone.
- **Keep engine history for** — 30, 90, 180 or 365 days. Not "forever": telemetry you
  have no use for is a liability, not a feature.

In the **Garage**, deleting a vehicle removes its trips, baselines, fuel entries,
maintenance items, documents and telemetry files — not just the row.

## Permissions

All optional. The app is useful with none of them.

| Permission | What it buys | Without it |
|---|---|---|
| Location (when in use) | Trip recording, terrain, gradient, route weather | Manual drives, no route or terrain |
| Location (always) | Drives that start and stop on their own | Start drives from the Drive tab |
| Motion | Accurate altitude, so gradient means something; road surface events | GPS altitude only, lower confidence |
| Bluetooth | Live engine data from an OBD-II adapter | Phone-only intelligence (Level 1) |
| Camera | Scanning documents into the glovebox | Type document details in |
| Microphone + speech | Asking a question out loud in CarPlay | Tap a question from the list instead |

Every permission string in `Info.plist` says what the data is used for and that it
stays on the device.

**The microphone is the newest of these and the easiest to get wrong, so it is worth
being specific.** DriveLayer listens only while the CarPlay voice screen is up, only
until it has a sentence or ten seconds pass, and never in the background. Recognition
uses `requiresOnDeviceRecognition`, and there is deliberately **no server fallback**:
on a phone that cannot recognise speech locally, DriveLayer refuses to listen and says
why, rather than sending audio to Apple to be transcribed. Nothing is recorded to
disk — audio buffers go to the recogniser and are released, and the transcript lives
only long enough to become a question. Siri, which answers through App Intents, needs
none of this.

## What DriveLayer will not do

- Sell or share vehicle or location data. There is no third party to share it with.
- Upload telemetry silently. There is no upload path.
- Require an account.
- Track you between vehicles or across apps.


## Destinations and route weather

Setting a destination is the one thing in DriveLayer that sends a location to a
server, and it only happens when a driver asks for it.

- Searching for a place sends the typed text and a coarse region to Apple's search
  service. Nothing about the search is stored — no history, no recent destinations.
- Looking up the road to the chosen place sends the start and end coordinates to
  Apple's directions service. DriveLayer keeps the returned geometry in memory to
  sample weather along, and discards everything else the response carries.
- The destination itself is held as a name and a coordinate, in memory, until the
  driver clears it or the drive ends. It is never written to disk and never leaves
  the device again.
- The road is looked up again at most every fifteen minutes while a destination is
  set, and after a failure at most every minute until one succeeds. It is not looked
  up once per second alongside the rest of the drive loop.
- With no destination set, none of this runs. The destination is dropped when the
  drive ends, so lookups stop with it rather than continuing for as long as the app
  is open.
