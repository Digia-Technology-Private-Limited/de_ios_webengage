// swift-tools-version: 6.0
import PackageDescription

// ┌─────────────────────────────────────────────────────────────────────────────┐
// │  DigiaEngageWebEngage – iOS native CEP plugin for WebEngage                 │
// │                                                                             │
// │  SPM dependency (this package):                                             │
// │    .package(                                                                │
// │        url: "…/digia_engage_webengage.git",                                 │
// │        from: "1.0.0"                                                        │
// │    )                                                                        │
// │                                                                             │
// │  ⚠️  WebEngage 7.1.0 comes in through this package (WebEngage's own CDN     │
// │  binary). Do NOT also add WebEngage separately (CocoaPods or SPM) — that    │
// │  duplicates the framework's symbols in the host binary and the linker       │
// │  fails. This package is the only place WebEngage should be declared.        │
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
        // The sibling checkout, not a version tag: the published constraint predates
        // core's CEP v2 surface and resolves a core this package can no longer compile
        // against. Repoint at a tag once core publishes one carrying that contract.
        .package(path: "../core"),
    ],
    targets: [
        // WebEngage 7.1.0, the binary WebEngage's own webengage-ios-sdk package points at. No
        // tag of that package carries 7.1.0 yet (2.0.4 is 7.0.4), so the pin is the URL.
        .binaryTarget(
            name: "WebEngage",
            url: "https://we-sdk.webengage.com/ios/WebEngageCore/7.1.0/WebEngageCore.zip",
            checksum: "9b4bbc75e12fba962710363b3a45abe17e2a6493a2302ea5c2a336579885544d"
        ),
        .target(
            name: "DigiaEngageWebEngage",
            dependencies: [
                .product(name: "DigiaEngage", package: "core"),
                .target(name: "WebEngage"),
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
