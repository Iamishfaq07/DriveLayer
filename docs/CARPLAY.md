# CarPlay

## Posture

CarPlay is a separate product surface, not a mirrored iPhone screen. The phone app
can afford a scrolling screen of interpreted context; CarPlay gets a handful of
tiles, glanceable at a red light, and a short list of questions.

The root is a tab bar over three screens:

**Vehicle** (grid) — up to four tiles, in this order when present:

1. **The one urgent insight**, if there is one at `watch` or above. Its icon shape
   carries severity rather than topic, since that is the one thing worth reading
   without colour on this particular tile.
2. **Vehicle** — overall health status.
3. **Range** — estimated distance remaining, labelled as such.
4. **Hyperion** — engine assessment status, when there is anything assessed yet.

**Ahead** (grid) — up to two tiles:

1. **Weather** — the next meaningful change on the route, or current conditions.
2. **Terrain** — the climb or descent underway or coming up.

**Ask Harrier** (list) — four questions whose answers are already computed.

Tapping any tile or question pushes an information template with the fuller
sentence — the *spoken* form for a copilot answer, since it is being read at the
wheel. A grid tile shows the value at a glance; the push is where the explanation
lives, matching how the phone app and the widgets already separate "what" from
"why."

What CarPlay deliberately does not have: charts, scrolling telemetry, trip history,
settings, or any interaction that needs more than a glance. Refresh is on a
ten-second timer: frequent enough for status, slow enough to be ignorable.

**On graphics:** a grid of tinted icon tiles is the ceiling, not a design choice
short of one. `CPGridTemplate`, `CPListTemplate`, `CPInformationTemplate` and
`CPTabBarTemplate` are the entire vocabulary Apple gives a driving-task app — no
custom view, no chart, no gauge, no canvas. `CPMapTemplate`, the one CarPlay
template that allows genuinely custom drawing, is restricted to the Navigation
category, which DriveLayer is not and should not misrepresent itself as. A vehicle
manufacturer's own cluster (Tesla, BMW, and similar) is not a CarPlay app at all —
it is the car's own embedded software, unconstrained by any of this, which is why
it can look nothing like what a third-party app is permitted to show.

## Templates used

`CPGridTemplate` for the two tile screens, `CPListTemplate` for Ask Harrier and for
the root's implicit empty state, `CPInformationTemplate` for a pushed answer or
insight detail, `CPTabBarTemplate` to hold the three of them together. All four are
within what a driving-task app may present. No custom UI, no unsupported template,
and nothing that assumes a category DriveLayer has not been granted.

Tile colour reuses the same `SemanticStatus` → `Palette.status` vocabulary as the
phone app and the widgets, so a colour never means something different on CarPlay
than it does anywhere else. Weather and terrain have no status field of their own
the way vehicle health and Hyperion do; their tiles borrow the worst severity among
any matching, driving-safe insight instead of the presenter inventing a judgment,
and fall back to the app's plain accent colour when there is no such insight to
borrow from.

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
