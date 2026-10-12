# DigiaEngage WebEngage (DigiaEngageWebEngage)

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDigia-Technology-Private-Limited%2Fde_ios_webengage%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Digia-Technology-Private-Limited/de_ios_webengage)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDigia-Technology-Private-Limited%2Fde_ios_webengage%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Digia-Technology-Private-Limited/de_ios_webengage)
[![License: BSL 1.1](https://img.shields.io/badge/License-BSL%201.1-blue.svg)](LICENSE)

DigiaEngageWebEngage is an iOS CEP plugin that integrates the WebEngage SDK with the DigiaEngage platform. It exposes the `DigiaEngageWebEngage` library which bridges Digia's CEP plugin APIs to WebEngage for event routing and in-app campaigns.

**Quick facts**
- **Package name:** DigiaEngageWebEngage
- **WebEngage versions:** Swift package `>= 2.0.0, < 3.0.0`; CocoaPods SDK `>= 7.0.4, < 7.2.0`
- **Swift tools version:** 6.0 (see `Package.swift`)
- **Minimum platform:** iOS 15.0

## Requirements

- iOS: 15.0+
- Swift tools: 6.0
- DigiaEngage: `>= 4.0.0, < 5.0.0`
- WebEngage Swift package: `>= 2.0.0, < 3.0.0`
- WebEngage CocoaPods SDK: `>= 7.0.4, < 7.2.0`

WebEngage versions its Swift package independently from the native SDK inside
it. Its package tags `2.0.0` through `2.0.4` contain native SDK `7.0.0` through
`7.0.4`; CocoaPods uses the native SDK's own `7.x` version numbers.

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

**Important:** With SPM, this package brings in the official
`webengage-ios-sdk` package transitively; do not add a second WebEngage binary
through CocoaPods. With CocoaPods, the podspec resolves one shared
`WebEngage >= 7.0.4, < 7.2.0` dependency with the host app.

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
