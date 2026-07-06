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
// └─────────────────────────────────────────────────────────────────────────────┘

let package = Package(
    name: "DigiaEngageWebEngage",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        // Only DigiaEngageWebEngage is exposed. WebEngage is an internal
        // dependency — the host app must NOT add it separately or it will
        // cause duplicate symbol linker errors.
        .library(
            name: "DigiaEngageWebEngage",
            targets: ["DigiaEngageWebEngage"]
        ),
    ],
    dependencies: [
        // Digia Engage iOS SDK — available via Swift Package Manager.
        .package(
            url: "https://github.com/Digia-Technology-Private-Limited/digia_ios_core.git",
            from: "3.2.0"
        ),
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
    ]
)
