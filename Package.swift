// swift-tools-version: 6.0
import PackageDescription

// ┌─────────────────────────────────────────────────────────────────────────────┐
// │  DigiaEngageWebEngage – iOS native CEP plugin for WebEngage                 │
// │                                                                             │
// │  SPM dependency (this package):                                             │
// │    .package(                                                                │
// │        url: "…/de_ios_webengage.git",                                       │
// │        from: "2.0.0"                                                        │
// │    )                                                                        │
// │                                                                             │
// │  WebEngage comes from its official Swift package. Do not add that package   │
// │  separately; SwiftPM resolves this transitive dependency for the host.      │
// └─────────────────────────────────────────────────────────────────────────────┘

let package = Package(
    name: "DigiaEngageWebEngage",
    platforms: [
        // Follows core, which requires iOS 15. Keep these in lockstep with
        // DigiaEngage's Package.swift and podspec — a plugin must never demand a
        // higher floor than the core it depends on, or it silently excludes apps
        // that can run the core perfectly well.
        .iOS(.v15),
    ],
    products: [
        // Only DigiaEngageWebEngage is exposed. WebEngage is an internal
        // dependency — the host app must NOT add WebEngage separately or it
        // will cause duplicate symbol linker errors.
        .library(
            name: "DigiaEngageWebEngage",
            targets: ["DigiaEngageWebEngage"]
        ),
    ],
    dependencies: [
        // 4.0.0 is the first core release carrying the CEP v2 contract this package
        // compiles against; a range, so a host app can take any later 4.x.
        .package(
            url: "https://github.com/Digia-Technology-Private-Limited/digia_engage_ios.git",
            from: "4.0.0"
        ),
        // WebEngage versions its Swift package independently from the native
        // binary it contains. Package 2.0.0...2.0.4 carry native SDK
        // 7.0.0...7.0.4 respectively. Keep the package below its next major.
        .package(
            url: "https://github.com/WebEngage/webengage-ios-sdk.git",
            "2.0.0"..<"3.0.0"
        ),
    ],
    targets: [
        .target(
            name: "DigiaEngageWebEngage",
            dependencies: [
                .product(name: "DigiaEngage", package: "digia_engage_ios"),
                .product(name: "WebEngageCore", package: "webengage-ios-sdk"),
            ],
            path: "Sources"
        ),
        // The seam's whole point: the plugin runs here with a fake bridge, so
        // no test needs a live WebEngage SDK (spec §10.5, plan N2 "seam rule").
        .testTarget(
            name: "DigiaEngageWebEngageTests",
            dependencies: ["DigiaEngageWebEngage"],
            path: "Tests/DigiaEngageWebEngageTests"
        ),
    ]
)
