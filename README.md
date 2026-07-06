# DigiaEngage WebEngage (DigiaEngageWebEngage)

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDigia-Technology-Private-Limited%2Fdigia_expr_swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Digia-Technology-Private-Limited/digia_engage_ios)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDigia-Technology-Private-Limited%2Fdigia_expr_swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Digia-Technology-Private-Limited/digia_engage_ios)
[![License: BSL 1.1](https://img.shields.io/badge/License-BSL%201.1-blue.svg)](LICENSE)

DigiaEngageWebEngage is an iOS CEP plugin that integrates the WebEngage SDK with the DigiaEngage platform. It exposes the `DigiaEngageWebEngage` library which bridges Digia's CEP plugin APIs to WebEngage for event routing and in-app personalization.

**Quick facts**
- **Package name:** DigiaEngageWebEngage
- **Bundled binaries:** `Frameworks/WebEngage.xcframework` (WebEngage)
- **Bundled WebEngage version:** 6.20.1 (from `Frameworks/WebEngage.xcframework`)
- **Swift tools version:** 6.0 (see `Package.swift`)
- **Minimum platform:** iOS 17.0

## Requirements

- iOS: 17.0+
- Swift tools: 6.0

## Installation

### Swift Package Manager

Add this package to your `Package.swift` or add it in Xcode via **File → Add Packages...**:

```swift
dependencies: [
    .package(
        url: "https://github.com/Digia-Technology-Private-Limited/digia_webengage_iOS.git",
        from: "1.0.0"
    ),
]
```

Then add the library to your app target:

```swift
.target(
    name: "YourAppTarget",
    dependencies: [
        .product(name: "DigiaEngageWebEngage", package: "digia_webengage_iOS"),
    ]
)
```

This package depends on the core Digia Engage SDK (`DigiaEngage`) which is declared as an SPM dependency in the package; you do not need to add the core SDK separately when using this package.

**Important:** This repository bundles the `WebEngage.xcframework` locally so SPM can resolve the WebEngage imports. Do not add another copy of WebEngage to your host app (via CocoaPods or another SPM package) as that will cause duplicate-symbol linker errors.

If your project uses CocoaPods for other dependencies and you prefer to integrate WebEngage via CocoaPods instead of using the bundled xcframework, make sure only one integration method is present in your final app binary.

## Usage

Register the plugin with DigiaEngage (example):

```swift
import DigiaEngage
import DigiaEngageWebEngage

// Register plugin during SDK initialization or app startup
Digia.register(WebEngagePlugin())
```

Refer to the source in `Sources/` for available APIs and integration details.

## Bundled frameworks

- `Frameworks/WebEngage.xcframework` — local binary target for the WebEngage SDK (CFBundleShortVersionString: 6.20.1).





## License

This project is distributed under the terms in `LICENSE`.

---

Built with ❤️ by Digia
