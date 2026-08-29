// swift-tools-version: 5.9
import PackageDescription

// DriveLayerCore is deliberately Foundation-only: no UIKit, SwiftUI, CoreBluetooth,
// CoreLocation, WeatherKit or SwiftData. That keeps every piece of product logic
// (OBD decoding, baselines, insights, trip maths, fuel, maintenance) testable with
// `swift test` on any platform, without a car, a phone, or even a Mac.
//
// Apple-framework implementations of the protocols declared here live in the iOS
// app target (App/DriveLayerApp), which compiles these same sources directly.
let package = Package(
    name: "DriveLayer",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "DriveLayerCore", targets: ["DriveLayerCore"])
    ],
    targets: [
        .target(name: "DriveLayerCore"),
        .testTarget(name: "DriveLayerCoreTests", dependencies: ["DriveLayerCore"])
    ]
)
