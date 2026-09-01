#!/usr/bin/env python3
"""Checks the bundle configuration that App Store validation rejects builds over.

Every rule here exists because a real TestFlight upload failed on it. That is the
bar for adding another: this is not a style checker, it is a list of things Apple
has already refused.

The reason it exists at all is that the failure mode is invisible locally. XcodeGen's
`info:` key is a *generator* - given a path it writes a plist there, overwriting what
was on disk - so the committed Info.plist can look perfectly correct while the plist
that reaches the bundle is near-empty. Six of the seven validation errors on the first
upload came from that single misunderstanding, and none were visible in a diff.

Run: python3 Tools/bundlecheck.py
"""
import pathlib
import plistlib
import struct
import sys
import zlib

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
problems: list[str] = []
notes: list[str] = []


def problem(message: str) -> None:
    problems.append(message)


def note(message: str) -> None:
    notes.append(message)


def check_project_spec() -> None:
    spec = yaml.safe_load((REPO / "project.yml").read_text(encoding="utf-8"))

    for name, target in (spec.get("targets") or {}).items():
        if target.get("type") not in {"application", "app-extension"}:
            continue

        settings = (target.get("settings") or {}).get("base") or {}

        # The rule this whole file is named for.
        if "info" in target:
            problem(f"{name}: has an `info:` block. XcodeGen will overwrite the "
                    "hand-written Info.plist with a generated one. Use INFOPLIST_FILE.")

        plist_path = settings.get("INFOPLIST_FILE")
        if not plist_path:
            problem(f"{name}: no INFOPLIST_FILE, so the build has no Info.plist.")
        elif not (REPO / plist_path).is_file():
            problem(f"{name}: INFOPLIST_FILE points at a missing file: {plist_path}")
        else:
            note(f"{name}: INFOPLIST_FILE -> {plist_path}")

        if settings.get("GENERATE_INFOPLIST_FILE") not in ("NO", False):
            problem(f"{name}: GENERATE_INFOPLIST_FILE must be NO; the plist is "
                    "maintained by hand.")

        if target.get("type") == "application":
            if settings.get("ASSETCATALOG_COMPILER_APPICON_NAME") != "AppIcon":
                problem(f"{name}: ASSETCATALOG_COMPILER_APPICON_NAME must be AppIcon.")


def check_app_plist() -> None:
    path = REPO / "App/DriveLayerApp/Resources/Info.plist"
    data = plistlib.loads(path.read_bytes())

    # "A value for the Info.plist key 'CFBundleIconName' is missing" (409)
    if data.get("CFBundleIconName") != "AppIcon":
        problem("Info.plist: CFBundleIconName must be AppIcon; App Store validation "
                "rejects an iOS 11+ build without it.")

    # "No orientations were specified" (409)
    if not data.get("UISupportedInterfaceOrientations"):
        problem("Info.plist: UISupportedInterfaceOrientations is required.")

    # "must provide the app's launch screen ... or using UILaunchScreen" (409)
    if "UILaunchScreen" not in data and "UILaunchStoryboardName" not in data:
        problem("Info.plist: UILaunchScreen (or UILaunchStoryboardName) is required.")

    # Keeps the bundle iPhone-only, which is what TARGETED_DEVICE_FAMILY says.
    if data.get("LSRequiresIPhoneOS") is not True:
        problem("Info.plist: LSRequiresIPhoneOS must be true, or the bundle is held "
                "to iPad's multitasking rules.")

    # "you need to include all of the ... orientations to support iPad
    # multitasking" (90474). An iPhone-only app is exempt, but only if the bundle
    # actually says iPhone-only. Apple reads UIDeviceFamily, so being iPhone-only
    # in one place and silent in the other is what got the build rejected.
    families = data.get("UIDeviceFamily")
    orientations = data.get("UISupportedInterfaceOrientations") or []
    ipad_capable = families is None or 2 in families
    all_four = {
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    }
    if ipad_capable and not all_four.issubset(set(orientations)):
        problem("Info.plist: the bundle is iPad-capable (UIDeviceFamily missing or "
                "includes 2) but does not declare all four orientations, which Apple "
                "requires for iPad multitasking. Either set UIDeviceFamily to [1] for "
                "iPhone only, or declare all four.")


def check_widget_plist() -> None:
    path = REPO / "App/DriveLayerWidgets/Info.plist"
    data = plistlib.loads(path.read_bytes())

    # "The NSExtensionPointIdentifier key must be present" (409)
    identifier = (data.get("NSExtension") or {}).get("NSExtensionPointIdentifier")
    if identifier != "com.apple.widgetkit-extension":
        problem("DriveLayerWidgets/Info.plist: NSExtension.NSExtensionPointIdentifier "
                "must be com.apple.widgetkit-extension.")


def check_icon() -> None:
    catalog = REPO / "App/DriveLayerApp/Resources/Assets.xcassets"
    icon_set = catalog / "AppIcon.appiconset"

    for required in (catalog / "Contents.json",
                     icon_set / "Contents.json",
                     icon_set / "icon-1024.png"):
        if not required.is_file():
            problem(f"missing: {required.relative_to(REPO)}")
            return

    data = (icon_set / "icon-1024.png").read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        problem("icon-1024.png is not a PNG.")
        return

    width, height, _, colour, _, _, interlace = struct.unpack(">IIBBBBB", data[16:29])

    # "does not contain an app icon ... of exactly '1024x1024' pixels" (409)
    if (width, height) != (1024, 1024):
        problem(f"icon-1024.png must be exactly 1024x1024, is {width}x{height}.")
    # An icon with an alpha channel is rejected outright.
    if colour not in (2, 0):
        problem("icon-1024.png must have no alpha channel (PNG colour type 2).")
    if interlace != 0:
        problem("icon-1024.png must not be interlaced.")

    # A corrupt icon fails validation too, so verify the CRCs.
    offset = 8
    while offset < len(data):
        (length,) = struct.unpack(">I", data[offset:offset + 4])
        tag = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        (crc,) = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])
        if crc != (zlib.crc32(tag + payload) & 0xFFFFFFFF):
            problem(f"icon-1024.png has a bad CRC on chunk {tag.decode(errors='replace')}.")
            return
        offset += 12 + length

    note(f"icon: 1024x1024, colour type {colour}, CRCs valid")


def check_release_runner() -> None:
    """Apple refuses uploads built against an SDK older than iOS 26."""
    path = REPO / ".github/workflows/release.yml"
    workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
    for job_name, job in (workflow.get("jobs") or {}).items():
        runner = job.get("runs-on", "")
        if runner in {"macos-15", "macos-14", "macos-13", "macos-latest"}:
            problem(f"release.yml: job '{job_name}' runs on {runner}, which ships an "
                    "SDK older than iOS 26. Apple rejects the upload. Use macos-26.")
        else:
            note(f"release.yml: '{job_name}' runs on {runner}")


for check in (check_project_spec, check_app_plist, check_widget_plist,
              check_icon, check_release_runner):
    try:
        check()
    except Exception as error:                      # a broken check is a failure
        problem(f"{check.__name__} raised {type(error).__name__}: {error}")

for line in notes:
    print(f"  {line}")

if problems:
    print()
    for line in problems:
        print(f"error: {line}")
    print(f"\nbundlecheck: {len(problems)} problem(s)")
    sys.exit(1)

print(f"\nbundlecheck: {len(notes)} check(s) passed, 0 problems")
