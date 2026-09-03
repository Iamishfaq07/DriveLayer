# CarPlay

## Posture

CarPlay is a separate product surface, not a mirrored iPhone screen. The phone app
can afford a scrolling screen of interpreted context; CarPlay gets a handful of
tiles, glanceable at a red light, and a short list of questions.

The root is a tab bar over four screens:

**Vehicle** (grid) — up to four tiles, in this order when present:

1. **The one urgent insight**, if there is one at `watch` or above. Its icon shape
   carries severity rather than topic, since that is the one thing worth reading
   without colour on this particular tile.
2. **Vehicle** — overall health status.
3. **Battery** — the same voltage judgment the health screen and "How's the
   battery?" already give, not a new one.
4. **Hyperion** — engine assessment status, when there is anything assessed yet.

**Trip** (grid) — up to four tiles, kept apart from Vehicle so neither grid grows
past a glance:

1. **Range** — estimated distance remaining, labelled as such.
2. **Last drive** — distance, duration and economy from the most recently completed
   trip, read from the same snapshot the widgets and Siri already use.
3. **Next service** — what's due and when, from the same maintenance status the
   health screen shows.
4. **Running cost** — cost per distance, averaged over the fills that carry a price.
   No status colour: DriveLayer has no opinion about what a kilometre ought to cost.

**Ahead** (grid) — up to three tiles:

1. **Reachability** — whether the tank covers the road to the destination, as spare
   or shortfall. It leads this tab because it is the only tile here with a
   consequence: rain ahead changes how you drive, a shortfall changes whether you
   stop. It is also the tile that most belongs in the car rather than on the phone,
   because it answers a question that only exists while driving.
2. **Weather** — the next meaningful change on the route, or current conditions.
3. **Terrain** — the climb or descent underway or coming up.

**Ask Harrier** (list) — all of the copilot's example questions, each already
routing to a real answer rather than a stub. Nothing here is shortened for space;
a list scrolls.

Tapping any tile or question pushes an information template with the fuller
sentence — the *spoken* form for a copilot answer, since it is being read at the
wheel. A grid tile shows the value at a glance; the push is where the explanation
lives, matching how the phone app and the widgets already separate "what" from
"why."

**One exception to "tap to see more": a genuinely critical insight interrupts.**
`.watch` and `.attention` stay passive on the urgent tile, same as always. Only
`.critical` pops a modal `CPAlertTemplate` — once per distinct insight, not once
per ten-second refresh — because CarPlay review treats driver interruptions as a
safety question, not a feature to reach for. Dismissing it does not clear the
underlying tile; it just stops interrupting about the same thing twice.

What CarPlay deliberately does not have: charts, scrolling telemetry, trip history,
settings, or any interaction that needs more than a glance. Refresh is on a
ten-second timer: frequent enough for status, slow enough to be ignorable.

## What stays on the phone, and why

Not every screen can cross over, and two of them cannot for reasons that are Apple's
rather than this project's.

| Phone screen | On CarPlay? | Why |
|---|---|---|
| Reachability | **Yes** | Belongs in the car more than on the phone. |
| Running cost | **Yes** | A value and a label; a tile holds it. |
| Vehicle, battery, engine, range, service, last drive | **Yes** | All present as tiles. |
| Ask Harrier, including spoken questions | **Yes** | The list, plus voice on iOS 27. |
| The live drive | **Yes** | On the dashboard, as a Live Activity. |
| Trip map | **No — not possible** | A driving-task app gets no custom drawing. `CPMapTemplate` is the only template that can draw a map and it is restricted to the Navigation category. |
| Economy chart | **No — not possible** | Same ceiling: no canvas, no chart, no gauge. |
| Where you parked | **No — pointless** | You are sitting in the car. |
| Fuel entry, documents, settings, trip history | **No — by choice** | Typing a fill-up or scanning insurance at the wheel is exactly what CarPlay review exists to prevent. |

The first two are worth being blunt about, because no amount of work changes them:
Apple gives a driving-task app four templates and none of them draws anything. A map
or a chart on this app's CarPlay screen is not a thing that can be built, by anyone,
today.

**On graphics:** a grid of tinted icon tiles is the ceiling, not a design choice
short of one. `CPGridTemplate`, `CPListTemplate`, `CPInformationTemplate`,
`CPAlertTemplate` and `CPTabBarTemplate` are the entire vocabulary Apple gives a
driving-task app — no custom view, no chart, no gauge, no canvas. `CPMapTemplate`,
the one CarPlay template that allows genuinely custom drawing, is restricted to the
Navigation category, which DriveLayer is not and should not misrepresent itself as.
A vehicle manufacturer's own cluster (Tesla, BMW, and similar) is not a CarPlay app
at all — it is the car's own embedded software, unconstrained by any of this, which
is why it can look nothing like what a third-party app is permitted to show.

## The CarPlay Dashboard

The dashboard — the screen beside Maps — is a separate surface from the app's own
CarPlay templates, and DriveLayer reaches it **without the CarPlay framework at
all**. An earlier version of this document said the dashboard was unavailable
because `CPDashboardController` could not be confirmed for a driving-task app. That
was the wrong API to have been asking about: Apple's mechanism for third-party
dashboard content is WidgetKit and ActivityKit.

**Live Activity.** CarPlay renders a Live Activity using the `small` activity
family — the same size class the Apple Watch Smart Stack uses — so
`DriveActivityWidget` declares `.supplementalActivityFamilies([.small])` and
branches on `activityFamily` to draw a dashboard-scale layout. Nothing else was
needed: the drive Live Activity was already started, updated and ended by
`DriveSessionCoordinator`, so a drive in progress now appears on the dashboard on
its own, and the same small layout serves a future Watch app for free.

**Widgets.** A widget that supports `.systemSmall` is eligible for the CarPlay
dashboard automatically — it is opt-out (`.disfavoredLocations([.carPlay], for:)`),
not opt-in — and all four of DriveLayer's widgets already did. CarPlay draws them
StandBy-style: full colour, with the widget container background removed. Every
widget here already uses `.containerBackground(for: .widget)`, which is precisely
the modifier that lets the system take the background away, so they degrade
correctly rather than rendering a card that CarPlay has stripped the back off.

One constraint worth knowing before designing for this: there is currently **no API
to detect whether a widget is drawing in CarPlay or on the phone**. An Apple
engineer confirmed as much on the developer forums and pointed at an enhancement
request. So one layout has to work in both places; a CarPlay-specific widget design
is not on the table today.

Both surfaces need iOS 26 on the phone to appear on the dashboard. The `small`
activity family itself is iOS 18, which is why the deployment target is 18.0.

**On CarPlay's navigation depth:** a driving-task app's tab stack is capped at two
templates deep — a tab's own root, plus one push — which every grid tile here
already uses when it pushes an information template. `CPAlertTemplate` does not
draw against that budget, because it is presented modally rather than pushed; that
is the only reason there was room to add it without restructuring anything else.

## Templates used

`CPGridTemplate` for the tile screens, `CPListTemplate` for Ask Harrier and for the
root's implicit empty state, `CPInformationTemplate` for a pushed answer or insight
detail, `CPAlertTemplate` for the one interruption CarPlay allows, `CPTabBarTemplate`
to hold them all together. All are within what a driving-task app may present. No
custom UI, no unsupported template, and nothing that assumes a category DriveLayer
has not been granted.

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

**Free-form voice is no longer a later phase.** `CPVoiceControlTemplate` became
available to a driving-task app in iOS 27 — before that it was restricted to a few
categories DriveLayer is not one of — so "Ask a question" now sits at the top of the
Ask Harrier tab on iOS 27, above the pre-computed list. Speaking is the only entry
there that can produce a question the list does not already contain.

A spoken question goes to `FoundationModelsCopilot` rather than the rule matcher.
This is the one place the model earns its latency: a sentence someone actually said
will rarely match keywords, and the model falls back to the matcher by itself when it
cannot help. The answer is still checked by `AnswerGuard`, so speaking cannot get a
number past a check that typing could not.

**On the microphone.** Recognition is on-device and there is no server fallback: if
the phone cannot recognise speech locally, DriveLayer says so and declines to listen
rather than quietly uploading audio. CarPlay requires that recording only happen
while the voice template is on screen, which is also the honest thing to show — the
template appearing is the driver's evidence that the microphone opened, and it
disappearing is the evidence that it closed. Listening stops on a final result, after
ten seconds, or when the car disconnects, whichever comes first.

Siri, above, still works without any of this and without the microphone permission.
