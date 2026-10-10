# Changelog

All notable changes to Digia Engage WebEngage (iOS) are documented in this file.

## [2.0.0] - 2026-10-10

### New Features
- `DigiaEngageWebEngage` can now be installed as the CocoaPods pod `DigiaEngageWebEngage` as well as through Swift Package Manager; the pod depends on `DigiaEngage ~> 4.0` and `WebEngage` 7.1.0.

### Improvements
- WebEngage campaigns are now matched to Digia campaigns by campaign key, read from custom data under `digiaKey`, `digia_key`, `campaignKey`, `campaign_key` (and their dashed and `digiaCampaign…` forms) or from a `<template id="digia-config">` block of `<meta>` tags in the campaign HTML; the `command`, `viewId`, `type`, `placementKey` and `screenId` custom data and the `<digia …>` HTML tag are no longer read, so existing campaigns must be re-authored with a campaign key (breaking).
- Campaign variables are read from a `variables` object or JSON text (`args` is still accepted) or from the other `<meta>` entries of the `digia-config` block, with a top-level `variables` or `args` taking precedence over the block; values are flattened to text, with whole numbers as integers (`5`, not `5.0`) and booleans as `true` / `false`, and arrays, nested objects, nulls and empty strings are dropped.
- A campaign whose campaign-key field is blank or not text is suppressed in WebEngage and dropped by Digia, a `digia-config` block that names no key is suppressed and dropped, and a campaign with neither a key field nor a block is left to WebEngage.
- The plugin now pins WebEngage iOS SDK 7.1.0 exactly (it bundled 6.20.1): Swift Package Manager pulls the 7.1.0 binary itself and CocoaPods depends on the `WebEngage` pod at 7.1.0, so host apps on WebEngage 6.x must move to 7.1.0 and any CocoaPods constraint on `WebEngage` must allow it.
- The minimum iOS version is now 15 (it was 17).

### Bug Fixes
- A campaign that Digia dismissed, declined, or lost because the plugin was unregistered mid-display is no longer suppressed for the rest of the session; WebEngage can offer it again, one second after a Digia dismissal.
- Unregistering and re-registering the plugin no longer lets WebEngage render Digia campaigns with its own template; the in-app delegate now stays installed for the life of the process.
- A campaign WebEngage prepares while Digia is still initialising is now held and delivered once Digia is ready, and one prepared before any plugin is registered is dropped rather than suppressed for the rest of the session.
- The host app no longer crashes when a WebEngage version lacks a non-public API the plugin calls; the call is skipped instead.
- A campaign triggered just before a screen change is no longer lost: each screen change is held until the in-flight WebEngage in-app render reaches the plugin, for at most one second, so screen changes now reach WebEngage at least 100 ms later.
- A campaign variable authored as `1` or `0` no longer renders as `true` or `false`.
