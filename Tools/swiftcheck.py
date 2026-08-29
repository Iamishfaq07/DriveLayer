#!/usr/bin/env python3
"""
swiftcheck — a static consistency checker for the DriveLayer sources.

This is NOT a Swift compiler and does not pretend to be one. It exists because the
development container has no Swift toolchain, and shipping unverified code is worse
than shipping code checked by something honest about its limits.

What it does check:
  * bracket balance, comment- and string-aware (nested block comments, multiline
    strings, raw strings, interpolation)
  * duplicate type declarations across the tree
  * references to types that are declared nowhere and are not known SDK symbols
  * member references of the form `Type.member` against the members that type
    actually declares anywhere in the tree
  * import rules per module directory (the pure core may not import UI or device
    frameworks)
  * banned-API rules that enforce the read-only safety policy
  * leftover TODO/FIXME markers

Exit code is non-zero when errors are found. Warnings do not fail the run.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections import defaultdict

# --------------------------------------------------------------------------------------
# Lexing: strip comments and string literals so later passes see code only.
# --------------------------------------------------------------------------------------


def strip_noncode(source: str):
    """Return (code_text, list_of_(line, char) positions preserved).

    Comments and string bodies are replaced with spaces so that offsets, and therefore
    line numbers, stay identical to the original.
    """
    out = []
    i = 0
    n = len(source)
    line = 1
    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""

        # Line comment
        if ch == "/" and nxt == "/":
            while i < n and source[i] != "\n":
                out.append(" ")
                i += 1
            continue

        # Block comment (Swift allows nesting)
        if ch == "/" and nxt == "*":
            depth = 0
            while i < n:
                if source[i] == "/" and i + 1 < n and source[i + 1] == "*":
                    depth += 1
                    out.append("  ")
                    i += 2
                    continue
                if source[i] == "*" and i + 1 < n and source[i + 1] == "/":
                    depth -= 1
                    out.append("  ")
                    i += 2
                    if depth == 0:
                        break
                    continue
                out.append("\n" if source[i] == "\n" else " ")
                i += 1
            continue

        # Raw string with any number of leading hashes
        if ch == "#":
            m = re.match(r'#+"', source[i:])
            if m:
                hashes = m.group(0).count("#")
                closing = '"' + "#" * hashes
                is_multiline = source.startswith('"""', i + hashes)
                if is_multiline:
                    closing = '"""' + "#" * hashes
                    j = source.find(closing, i + hashes + 3)
                else:
                    j = source.find(closing, i + hashes + 1)
                if j == -1:
                    j = n
                    end = n
                else:
                    end = j + len(closing)
                for k in range(i, end):
                    out.append("\n" if source[k] == "\n" else " ")
                i = end
                continue

        # Multiline string
        if source.startswith('"""', i):
            j = source.find('"""', i + 3)
            end = n if j == -1 else j + 3
            for k in range(i, end):
                out.append("\n" if source[k] == "\n" else " ")
            i = end
            continue

        # Regular string, honouring escapes and skipping interpolation bodies
        if ch == '"':
            out.append(" ")
            i += 1
            while i < n:
                if source[i] == "\\":
                    if i + 1 < n and source[i + 1] == "(":
                        depth = 0
                        out.append("  ")
                        i += 2
                        depth = 1
                        while i < n and depth > 0:
                            if source[i] == "(":
                                depth += 1
                            elif source[i] == ")":
                                depth -= 1
                            out.append("\n" if source[i] == "\n" else " ")
                            i += 1
                        continue
                    out.append("  ")
                    i += 2
                    continue
                if source[i] == '"':
                    out.append(" ")
                    i += 1
                    break
                out.append("\n" if source[i] == "\n" else " ")
                i += 1
            continue

        # Character-by-character passthrough
        out.append(ch)
        i += 1

    return "".join(out)


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


# --------------------------------------------------------------------------------------
# Declarations
# --------------------------------------------------------------------------------------

TYPE_DECL = re.compile(
    r"\b(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|final\s+|indirect\s+)*"
    r"(struct|class|enum|protocol|actor)\s+([A-Z][A-Za-z0-9_]*)"
)
EXTENSION_DECL = re.compile(r"\bextension\s+([A-Z][A-Za-z0-9_]*)")
TYPEALIAS_DECL = re.compile(r"\btypealias\s+([A-Z][A-Za-z0-9_]*)")
ENUM_CASE = re.compile(r"^\s*case\s+([a-z_][A-Za-z0-9_]*)", re.M)
MEMBER_DECL = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private(?:\(set\))?\s+|fileprivate\s+|open\s+|final\s+|"
    r"static\s+|class\s+|lazy\s+|weak\s+|unowned\s+|nonisolated\s+|override\s+|mutating\s+|"
    r"convenience\s+|required\s+|dynamic\s+|indirect\s+|@\w+\s+)*"
    r"(?:let|var|func|case)\s+([a-zA-Z_][A-Za-z0-9_]*)",
    re.M,
)

# Members every type may reference without declaring them.
SYNTHESISED_MEMBERS = {
    "allCases", "rawValue", "init", "self", "Type", "none", "some", "shared", "default",
    "id", "description", "debugDescription", "hashValue", "count", "first", "last",
    "max", "min", "zero", "nan", "infinity", "pi", "identity", "current", "now",
}


def collect_declarations(files):
    """Map type name -> set of member names, plus a record of where types are declared."""
    members = defaultdict(set)
    declared_at = defaultdict(list)
    all_types = set()

    for path, code in files.items():
        # Walk the file tracking brace depth so members attach to their enclosing type.
        stack = []  # (type_name, depth_at_open)
        depth = 0
        i = 0
        n = len(code)
        pending_type = None
        while i < n:
            ch = code[i]
            if ch == "{":
                if pending_type:
                    stack.append((pending_type, depth))
                    pending_type = None
                else:
                    stack.append((None, depth))
                depth += 1
                i += 1
                continue
            if ch == "}":
                depth -= 1
                if stack:
                    stack.pop()
                i += 1
                continue

            m = TYPE_DECL.match(code, i)
            if m:
                name = m.group(2)
                enclosing = next((owner for owner, _ in reversed(stack) if owner), None)
                # A nested type is a different type from a same-named one elsewhere,
                # so duplicates are tracked by qualified name.
                qualified = f"{enclosing}.{name}" if enclosing else name
                all_types.add(name)
                declared_at[qualified].append((path, line_of(code, i)))
                pending_type = name
                i = m.end()
                continue
            m = EXTENSION_DECL.match(code, i)
            if m:
                pending_type = m.group(1)
                i = m.end()
                continue
            m = TYPEALIAS_DECL.match(code, i)
            if m:
                all_types.add(m.group(1))
                declared_at[m.group(1)].append((path, line_of(code, i)))
                i = m.end()
                continue

            m = MEMBER_DECL.match(code, i)
            if m and stack:
                owner = next((name for name, _ in reversed(stack) if name), None)
                if owner:
                    members[owner].add(m.group(1))
                i = m.end()
                continue

            i += 1

    return all_types, members, declared_at


# --------------------------------------------------------------------------------------
# Known SDK symbols
# --------------------------------------------------------------------------------------

KNOWN = set(
    """
Any AnyObject AnyHashable Array ArraySlice Bool Character CharacterSet ClosedRange
Codable CodingKey CodingKeys Comparable CustomStringConvertible CustomDebugStringConvertible
Data Date DateComponents DateFormatter DateInterval DateIntervalFormatter Decimal Decodable Decoder
Dictionary Double Encodable Encoder Equatable Error Float Foundation Hashable Identifiable
Int Int8 Int16 Int32 Int64 IndexPath IndexSet Iterator IteratorProtocol JSONDecoder JSONEncoder
KeyPath Locale Measurement MeasurementFormatter Never NSLock NSNumber NSObject NSString
Notification NotificationCenter NumberFormatter Numeric Optional OptionSet
Range RandomNumberGenerator RangeReplaceableCollection RawRepresentable Result
Sequence Set String StringProtocol Substring Task TimeInterval TimeZone Timer
UInt UInt8 UInt16 UInt32 UInt64 URL URLComponents URLError URLRequest URLResponse URLSession UUID
UnitLength UnitSpeed UnitTemperature UnitVolume UnitPressure UnitDuration UnitAngle Unit Dimension
Void Collection BidirectionalCollection MutableCollection Strideable
Sendable Actor MainActor TaskGroup ThrowingTaskGroup AsyncStream AsyncThrowingStream
AsyncSequence Continuation CheckedContinuation Clock ContinuousClock SuspendingClock Duration
DispatchQueue DispatchTime DispatchWorkItem OperationQueue Operation Process ProcessInfo
FileManager FileHandle Bundle UserDefaults Progress Calendar Formatter
Logger OSLog OSLogType Signpost
Published ObservableObject State StateObject Binding Environment EnvironmentObject
ObservedObject Observable AppStorage SceneStorage FocusState Namespace
View Text Image Button Toggle Slider Stepper Picker List Section Form NavigationStack
NavigationLink NavigationSplitView NavigationPath TabView ScrollView LazyVStack LazyHStack
LazyVGrid LazyHGrid GridItem VStack HStack ZStack Spacer Divider Group GroupBox
Color Font Angle Animation Transaction Namespace Shape Path Rectangle RoundedRectangle
Circle Ellipse Capsule ContainerRelativeShape Gradient LinearGradient RadialGradient
AngularGradient Material ShapeStyle Alignment HorizontalAlignment VerticalAlignment
Edge EdgeInsets UnitPoint CGFloat CGPoint CGSize CGRect CGAffineTransform
App Scene WindowGroup Settings DocumentGroup ScenePhase UIApplication UIApplicationDelegate
UIViewController UIView UIColor UIFont UIImage UIScreen UIDevice UIImpactFeedbackGenerator
UINotificationFeedbackGenerator UIApplicationDelegateAdaptor UISceneConfiguration
UISceneSession UIWindowSceneDelegate UIScene UISceneConnectionOptions
ProgressView Label Menu ContextMenu Alert Sheet ToolbarItem ToolbarItemGroup
ContentUnavailableView Chart BarMark LineMark AreaMark PointMark RuleMark
AxisMarks AxisValueLabel AxisGridLine ChartProxy PlottableValue
SwiftData Model ModelContainer ModelContext ModelConfiguration Query Schema
PersistentModel PersistentIdentifier Attribute Relationship Transformable VersionedSchema
SchemaMigrationPlan MigrationStage
CLLocation CLLocationManager CLLocationCoordinate2D CLLocationManagerDelegate
CLAuthorizationStatus CLLocationDistance CLLocationSpeed CLLocationDegrees
CLLocationAccuracy CLActivityType CLPlacemark CLGeocoder CLRegion CLCircularRegion
CLMonitor CLVisit CLHeading
CMMotionManager CMAltimeter CMAltitudeData CMAbsoluteAltitudeData CMAcceleration
CMDeviceMotion CMMotionActivity CMMotionActivityManager CMPedometer CMAuthorizationStatus
CBCentralManager CBPeripheral CBService CBCharacteristic CBUUID CBManagerState
CBCentralManagerDelegate CBPeripheralDelegate CBCharacteristicWriteType
CBAdvertisementDataLocalNameKey CBConnectionEvent
WeatherService Weather CurrentWeather HourWeather DayWeather WeatherAvailability
WeatherMetadata Precipitation WeatherCondition WeatherSeverity WeatherAlert
CPTemplateApplicationSceneDelegate CPInterfaceController CPTemplate CPListTemplate
CPListSection CPListItem CPListImageRowItem CPInformationTemplate CPInformationItem
CPInformationRow CPGridTemplate CPGridButton CPAlertTemplate CPActionSheetTemplate
CPAlertAction CPNowPlayingTemplate CPTabBarTemplate CPPointOfInterestTemplate
CPMapTemplate CPTextButton CPBarButton CPTemplateApplicationScene CPInformationRating
WidgetKit Widget WidgetBundle WidgetConfiguration StaticConfiguration
AppIntentConfiguration TimelineProvider TimelineEntry Timeline TimelineEntryRelevance
IntentTimelineProvider WidgetFamily WidgetCenter AccessoryWidgetBackground
ActivityKit Activity ActivityAttributes ActivityContent ActivityUIDismissalPolicy
ActivityAuthorizationInfo ActivityConfiguration DynamicIsland DynamicIslandExpandedRegion
AppIntents AppIntent AppShortcut AppShortcutsProvider IntentDescription Parameter
IntentParameter EntityQuery AppEntity DisplayRepresentation TypeDisplayRepresentation
IntentResult ProvidesDialog ShowsSnippetView IntentDialog AppIntentsPackage
VisionKit VNDocumentCameraViewController VNDocumentCameraScan Vision VNRecognizeTextRequest
VNImageRequestHandler VNRecognizedTextObservation VNRequest
XCTest XCTestCase XCTestExpectation XCTAssertEqual XCTUnwrap XCTSkip
Keychain SecItemAdd SecItemCopyMatching FileProtectionType
Speech AVFoundation AVAudioSession AVSpeechSynthesizer AVSpeechUtterance
MapKit MKMapView MKCoordinateRegion MKPolyline Map MapPolyline MapCameraPosition
Charts Combine AnyCancellable PassthroughSubject CurrentValueSubject
Instruments SF Symbols
CaseIterable ExpressibleByStringLiteral ExpressibleByArrayLiteral ExpressibleByIntegerLiteral
LosslessStringConvertible AdditiveArithmetic BinaryInteger BinaryFloatingPoint FloatingPoint
SignedNumeric SignedInteger UnsignedInteger Self Element Value Key Wrapped Bound Output Failure
Content Body Configuration Entry Intent Attributes ContentState Placeholder Label Item Input
""".split()
)


# --------------------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------------------


def check_brackets(path, code, errors):
    pairs = {"}": "{", ")": "(", "]": "["}
    stack = []
    for i, ch in enumerate(code):
        if ch in "{([":
            stack.append((ch, line_of(code, i)))
        elif ch in ")}]":
            if not stack:
                errors.append(f"{path}:{line_of(code, i)}: unmatched closing '{ch}'")
                return
            open_ch, open_line = stack.pop()
            if open_ch != pairs[ch]:
                errors.append(
                    f"{path}:{line_of(code, i)}: '{ch}' closes '{open_ch}' opened at line {open_line}"
                )
                return
    if stack:
        open_ch, open_line = stack[-1]
        errors.append(f"{path}:{open_line}: '{open_ch}' is never closed")


IMPORT_RE = re.compile(r"^\s*import\s+([A-Za-z_][A-Za-z0-9_.]*)", re.M)

FORBIDDEN_CORE_IMPORTS = {
    "SwiftUI", "UIKit", "CoreBluetooth", "CoreLocation", "CoreMotion", "WeatherKit",
    "SwiftData", "WidgetKit", "ActivityKit", "CarPlay", "MapKit", "AppIntents",
    "VisionKit", "Vision", "Charts",
}

BANNED_PATTERNS = [
    (re.compile(r"\bwriteValue\s*\(", re.I), "direct characteristic writes must go through the OBD transport"),
    (re.compile(r"\bATSH\b|\bATCRA\b|\bATCAF0\b"), "raw CAN addressing commands are outside the read-only policy"),
    (re.compile(r'"\s*04\s*"'), "mode 04 (clear diagnostic information) is not permitted"),
    (re.compile(r"\bclearDTC|\bclearTroubleCodes|\bresetECU|\bflashECU|\bforceRegen", re.I),
     "write/control operations are outside the read-only policy"),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("roots", nargs="*", default=["Sources", "Tests", "App"])
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    roots = args.roots or ["Sources", "Tests", "App"]

    files = {}
    raw_files = {}
    for root in roots:
        for dirpath, _dirs, filenames in os.walk(root):
            for name in sorted(filenames):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, name)
                with open(path, encoding="utf-8") as handle:
                    raw = handle.read()
                raw_files[path] = raw
                files[path] = strip_noncode(raw)

    errors: list[str] = []
    warnings: list[str] = []

    if not files:
        print("swiftcheck: no Swift files found", file=sys.stderr)
        return 1

    for path, code in files.items():
        check_brackets(path, code, errors)

    all_types, members, declared_at = collect_declarations(files)

    # Generic parameter names and protocol associated types are legitimate type
    # references even though nothing declares them as a type.
    generic_names = set()
    generic_re = re.compile(r"\b(?:struct|class|enum|protocol|actor|func|typealias|extension)\s+[A-Za-z_][A-Za-z0-9_]*\s*<([^<>]*)>")
    associated_re = re.compile(r"\bassociatedtype\s+([A-Z][A-Za-z0-9_]*)")
    for code in files.values():
        for match in generic_re.finditer(code):
            for part in match.group(1).split(","):
                candidate = part.split(":")[0].strip()
                if re.fullmatch(r"[A-Z][A-Za-z0-9_]*", candidate):
                    generic_names.add(candidate)
        generic_names.update(associated_re.findall(code))
    all_types |= generic_names

    for name, places in declared_at.items():
        primary = [p for p in places]
        if len(primary) > 1:
            locations = ", ".join(f"{p}:{ln}" for p, ln in primary)
            errors.append(f"duplicate declaration of type '{name}' at {locations}")

    known = KNOWN | all_types

    # Unknown type references
    ident_re = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\b")
    for path, code in files.items():
        for match in ident_re.finditer(code):
            name = match.group(1)
            if name in known or len(name) <= 1:
                continue
            if name.isupper():  # constant-style identifiers such as RPM in doc text
                continue
            errors.append(f"{path}:{line_of(code, match.start())}: unknown type '{name}'")

    # Member references of the form Type.member
    member_re = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\.([a-z_][A-Za-z0-9_]*)\b")
    for path, code in files.items():
        for match in member_re.finditer(code):
            type_name, member = match.group(1), match.group(2)
            if type_name not in members:
                continue
            if member in SYNTHESISED_MEMBERS or member in members[type_name]:
                continue
            errors.append(
                f"{path}:{line_of(code, match.start())}: '{type_name}' has no member '{member}'"
            )

    # Import policy
    for path, raw in raw_files.items():
        imports = set(IMPORT_RE.findall(raw))
        if path.startswith(os.path.join("Sources", "DriveLayerCore")):
            for name in sorted(imports & FORBIDDEN_CORE_IMPORTS):
                # A guarded import is fine; an unconditional one is not.
                if f"canImport({name})" in raw:
                    continue
                errors.append(f"{path}: DriveLayerCore must not import {name}")

    # Safety policy
    for path, raw in raw_files.items():
        for pattern, reason in BANNED_PATTERNS:
            for match in pattern.finditer(raw):
                line = raw.count("\n", 0, match.start()) + 1
                errors.append(f"{path}:{line}: banned pattern — {reason}")

    # Leftover markers
    for path, raw in raw_files.items():
        for marker in ("TODO", "FIXME"):
            for match in re.finditer(rf"\b{marker}\b", raw):
                line = raw.count("\n", 0, match.start()) + 1
                warnings.append(f"{path}:{line}: leftover {marker}")

    for warning in warnings:
        print(f"warning: {warning}")
    for error in errors:
        print(f"error: {error}")

    file_count = len(files)
    type_count = len(all_types)
    print(
        f"\nswiftcheck: {file_count} files, {type_count} declared types, "
        f"{len(errors)} errors, {len(warnings)} warnings"
    )
    print("note: swiftcheck is a consistency checker, not a Swift compiler. "
          "Run `swift test` and an Xcode build on a Mac before trusting a change.")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
