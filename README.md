# DigiaEngage WebEngage (DigiaEngageWebEngage)

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDigia-Technology-Private-Limited%2Fde_ios_webengage%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Digia-Technology-Private-Limited/de_ios_webengage)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDigia-Technology-Private-Limited%2Fde_ios_webengage%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Digia-Technology-Private-Limited/de_ios_webengage)
[![License: BSL 1.1](https://img.shields.io/badge/License-BSL%201.1-blue.svg)](LICENSE)

DigiaEngageWebEngage is an iOS CEP plugin that integrates the WebEngage SDK with the DigiaEngage platform. It exposes the `DigiaEngageWebEngage` library which bridges Digia's CEP plugin APIs to WebEngage for event routing and in-app campaigns.

**Quick facts**
- **Package name:** DigiaEngageWebEngage
- **WebEngage version:** 7.1.0, pinned exactly (SPM binary target and CocoaPods)
- **Swift tools version:** 6.0 (see `Package.swift`)
- **Minimum platform:** iOS 15.0

## Requirements

- iOS: 15.0+
- Swift tools: 6.0

**iOS 15 is the package's deployment floor, not where campaigns run.** Digia Engage renders campaigns on iOS 17 and later. On earlier versions `Digia.initialize` and `Digia.register` do nothing, so the app builds and runs but shows no Digia campaigns.

## Installation

### Swift Package Manager

Add this package to your `Package.swift` or add it in Xcode via **File → Add Packages...**:

```swift
dependencies: [
    .package(
        url: "https://github.com/Digia-Technology-Private-Limited/de_ios_webengage.git",
        from: "2.0.0"
    ),
]
```

Then add the library to your app target:

```swift
.target(
    name: "YourAppTarget",
    dependencies: [
        .product(name: "DigiaEngageWebEngage", package: "de_ios_webengage"),
    ]
)
```

This package depends on the core Digia Engage SDK (`DigiaEngage`) which is declared as an SPM dependency in the package; you do not need to add the core SDK separately when using this package.

**Important:** With SPM, this package brings in WebEngage 7.1.0 as a binary target. Do not add another copy of WebEngage to your host app (via CocoaPods or another SPM package) as that will cause duplicate-symbol linker errors. With CocoaPods, the podspec depends on the `WebEngage` pod at 7.1.0.

## Usage

Pass the plugin's delegate to WebEngage when you initialize WebEngage in your `AppDelegate`.
Without it, WebEngage renders Digia campaigns itself:

```swift
WebEngage.sharedInstance().application(
    application,
    didFinishLaunchingWithOptions: launchOptions,
    notificationDelegate: DigiaWebEngagePlugin.notificationDelegate
)
```

Then register the plugin with DigiaEngage (example):

```swift
import DigiaEngage
import DigiaEngageWebEngage

// Register plugin during SDK initialization or app startup
Digia.register(DigiaWebEngagePlugin())
```

Refer to the source in `Sources/` for available APIs and integration details.





## License

This project is distributed under the terms in `LICENSE`.

---

Built with ❤️ by Digia
