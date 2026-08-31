# Getting DriveLayer onto your phone

The `TestFlight` workflow archives, signs and uploads the app. Everything it
needs about your Apple account comes from repository secrets — nothing about the
developer account is committed.

This is the one part of DriveLayer that cannot be automated from a Linux
container: signing requires your certificate and your account. Below is
everything you have to do once, and then the button you press.

---

## 1. Apple Developer Program — required

TestFlight needs a paid membership (currently $99/year) at
<https://developer.apple.com/programs/>. A free account can install to your own
phone from Xcode, but it cannot upload to TestFlight and its builds expire after
seven days.

The membership also unlocks **WeatherKit**, which DriveLayer needs before route
weather returns anything. That is worth knowing before you decide it is
expensive: it is one purchase for both.

## 2. Register the identifiers

At <https://developer.apple.com/account/resources/identifiers/list>:

| What | Identifier |
|---|---|
| App ID | `com.drivelayer.app` |
| App ID (widget extension) | `com.drivelayer.app.widgets` |
| App Group | `group.com.drivelayer.app` |

The App Group is not optional. It is how the widgets read the snapshot the app
publishes; without it the widgets show placeholder data forever.

On `com.drivelayer.app`, enable these capabilities:

- **App Groups** — select `group.com.drivelayer.app`
- **WeatherKit** — needed for current and route weather
- **Background Modes** — location and Bluetooth are declared in `Info.plist`

On `com.drivelayer.app.widgets`, enable **App Groups** and select the same group.

Do **not** enable CarPlay yet. See §6.

## 3. Create the app record

At <https://appstoreconnect.apple.com/apps>, create a new iOS app using bundle ID
`com.drivelayer.app`. The name has to be unique across the App Store; if
"DriveLayer" is taken, anything works — it is only the listing name, and TestFlight
shows it to you alone.

## 4. Create the four secrets

In the repository: **Settings → Secrets and variables → Actions → New repository
secret**.

| Secret | Where it comes from |
|---|---|
| `APPLE_TEAM_ID` | <https://developer.apple.com/account> → Membership. Ten characters, e.g. `A1B2C3D4E5`. |
| `BUILD_CERTIFICATE_BASE64` | An **Apple Distribution** certificate exported from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy`. |
| `P12_PASSWORD` | The password you set when exporting that `.p12`. |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key with **App Manager** access. The Key ID is shown in the list. |
| `APP_STORE_CONNECT_ISSUER_ID` | On the same page, above the key list. A UUID. |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The `.p8` file that key downloads — **once only**. Paste its whole contents, `-----BEGIN PRIVATE KEY-----` line included. |

Creating the distribution certificate needs a Mac (Keychain Access → Certificate
Assistant → Request a Certificate from a Certificate Authority, then upload the
request at <https://developer.apple.com/account/resources/certificates/add>).
It is the only step that does. If you have no Mac at all, tell me and I will
document the OpenSSL route instead.

## 5. Press the button

**Actions → TestFlight → Run workflow.**

Leave both inputs alone the first time. The build number defaults to the workflow
run number, which always increases — App Store Connect rejects a build number it
has seen before, and that is the most common way a first upload fails.

It takes about fifteen minutes. Apple then processes the build for another five
to fifteen. When it appears in TestFlight, install it from the TestFlight app on
your phone.

**Internal testers need no review.** Add yourself as an internal tester and the
build is installable as soon as processing finishes. External testers need a
review pass, which is where background location will draw questions — you do not
need external testers to test your own car.

## 6. CarPlay, honestly

**CarPlay will not work in this build**, and adding the entitlement to the
repository would make signing fail rather than make CarPlay appear.

Apple grants the driving-task entitlement by application, at
<https://developer.apple.com/carplay/>. Once granted, `docs/CARPLAY.md` has the
two edits — an entitlement key and a scene declaration — and the code behind them
already compiles.

Until then: the phone app is fully usable in the car. Mount the phone, connect the
adapter, and Drive Mode does what CarPlay would, on the screen you have.

## 7. What to expect on the first real drive

This is the first time any of this meets hardware, so treat it as a shakedown
rather than a demo.

**Set up before you drive:**

- Pair the OBD-II adapter in **Settings → Adapter**, with the ignition on.
- Grant location **Always** if you want drives to record without opening the app.
  While Using is enough for a drive you start by hand.
- No adapter yet? **Settings → Adapter → Use the simulator** exercises the whole
  app — trips, insights, widgets — against a simulated car.

**What is most likely to go wrong**, since nothing here has met a real adapter:

- Cheap ELM327 clones lie about what they support, respond slowly, or drop the
  connection under load. The parser is tested hard against malformed responses,
  but no test replaces a real one.
- The Harrier's OBD support is unverified. **Settings → Capability levels** shows
  what your car actually reports versus what DriveLayer can interpret — that
  screen is the single most useful thing to send me after the first drive.
- Weather stays "not configured" until WeatherKit is enabled on the App ID and a
  build carrying that capability is installed.
- Baselines need several drives before insights say anything specific. A first
  drive reporting little is the design working, not a fault.

**Worth capturing:** the Capability levels screen, anything in the Debug Center
that looks wrong, and any number that seems implausible. A wrong number that
looks confident is the most important bug class in this app.
