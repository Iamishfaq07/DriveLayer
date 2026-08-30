# CarPlay

## Posture

CarPlay is a separate product surface, not a mirrored iPhone screen. The phone app
can afford a scrolling screen of interpreted context; CarPlay gets four rows and a
short list of questions.

What the root template shows, in this order:

1. **The one urgent insight**, if there is one at `watch` or above.
2. **Vehicle** — health status and its one-line explanation.
3. **Range** — estimated, labelled as such.
4. **Weather ahead** — the next meaningful change, or current conditions.
5. **Terrain** — the climb or descent underway or coming up.
6. **Diesel** — usage status, on diesel vehicles.

Then **Ask copilot**: four questions whose answers are already computed. Selecting
one pushes an information template with the *spoken* form of the answer — two
sentences, not the detailed one — because it is being read at the wheel.

What CarPlay deliberately does not have: charts, scrolling telemetry, trip history,
settings, or any interaction that needs more than a glance. Refresh is on a
ten-second timer: frequent enough for status, slow enough to be ignorable.

## Templates used

`CPListTemplate` for the root, `CPInformationTemplate` for a pushed answer or insight
detail. Both are within what a driving-task app may present. No custom UI, no
unsupported template, and nothing that assumes a category DriveLayer has not been
granted.

## Enabling it

The CarPlay code ships and compiles. It is **not** wired up by default, because the
entitlement has to be granted by Apple and adding an ungranted entitlement breaks
code signing.

Once you have the entitlement:

**1. Add the entitlement.** Merge into `App/DriveLayerApp/Resources/DriveLayer.entitlements`:

```xml
<key>com.apple.developer.carplay-driving-task</key>
<true/>
```

The full set of gated entitlements is in `Capabilities.sample.entitlements`.

**2. Add the scene role.** Add to `App/DriveLayerApp/Resources/Info.plist`:

```xml
<key>UIApplicationSceneManifest</key>
<dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <true/>
    <key>UISceneConfigurations</key>
    <dict>
        <key>CPTemplateApplicationSceneSessionRoleApplication</key>
        <array>
            <dict>
                <key>UISceneClassName</key>
                <string>CPTemplateApplicationScene</string>
                <key>UISceneConfigurationName</key>
                <string>DriveLayer CarPlay</string>
                <key>UISceneDelegateClassName</key>
                <string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
            </dict>
        </array>
    </dict>
</dict>
```

**3. Regenerate and run.** `xcodegen generate`, then run on a device connected to
CarPlay or the CarPlay simulator (Xcode → I/O → External Displays → CarPlay).

Nothing else in the app changes. `CarPlayPresenter` reads the same
`DriveSessionCoordinator` the phone UI does, so it cannot drift out of step with what
the app believes.

## Requesting the entitlement

Apply at <https://developer.apple.com/carplay/>. DriveLayer's category is
**driving task**: it presents vehicle information relevant to the current drive. It
is not a navigation, audio, communication, parking, EV charging or fuelling app, and
asking for one of those categories to get the templates would be the wrong answer.

## Voice

Siri support ships through App Intents (`VehicleStatusIntent`, `NextServiceIntent`,
`LastDriveIntent`), which work in CarPlay without any additional entitlement. They
answer from the same published snapshot the widgets use, so Siri cannot produce a
number the app itself would not show:

> "How is my car in DriveLayer?"
>
> "Harrier is healthy. You have roughly 326 kilometres of estimated range. Battery
> voltage has been trending below your normal baseline."

The in-app copilot list on the CarPlay root is the interaction that works today for
everyone; free-form voice through `CPVoiceControlTemplate` is a later phase.
