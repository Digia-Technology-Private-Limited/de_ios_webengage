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
// │  ⚠️  PEER DEPENDENCY – Host app must add WebEngage separately:              │
// │    CocoaPods:  pod 'WebEngage'                                              │
// │    SPM:        https://github.com/WebEngage/WebEngage-iOS-SDK               │
// │                                                                             │
// │  WEPersonalization is bundled locally in this package.                      │
// └─────────────────────────────────────────────────────────────────────────────┘

let package = Package(
    name: "DigiaEngageWebEngage",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        // Only DigiaEngageWebEngage is exposed. WebEngage and WEPersonalization
        // are internal dependencies — the host app must NOT add WebEngage
        // separately or it will cause duplicate symbol linker errors.
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
        // WebEngage is CocoaPods-only — bundle the xcframework locally so SPM can resolve the import.
        .binaryTarget(
            name: "WebEngage",
            path: "Frameworks/WebEngage.xcframework"
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
