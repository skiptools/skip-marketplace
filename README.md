# SkipMarketplace

This module provide support for interfacing with an app's
marketplace, such as the Google Play Store for Android
and the Apple App Store for iOS.

Currently, the framework provides the ability to request
a store rating for the app from the user. In the future,
this framework will provide the ability to perform
in-app purchases and subscription management.

## Setup

To include this framework in your project, add the following
dependency to your `Package.swift` file:

```swift
let package = Package(
    name: "my-package",
    products: [
        .library(name: "MyProduct", targets: ["MyTarget"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip-marketplace.git", "0.0.0"..<"2.0.0"),
    ],
    targets: [
        .target(name: "MyTarget", dependencies: [
            .product(name: "SkipMarketplace", package: "skip-marketplace")
        ])
    ]
)
```

## App Review Requests

You can use this library to request that the app marketplace show a prompt to the user requesting a rating for the app for the given marketplace.

```swift
import SkipMarketplace

// request that the system show an app review request at most once every month
Marketplace.current.requestReview(period: .days(31))
```

For guidance on how and when to make these sorts of requests, see the
relevant documentation for the 
[Apple App Store](https://developer.android.com/guide/playcore/in-app-review#when-to-request)
and
[Google PlayStore](https://developer.apple.com/design/human-interface-guidelines/ratings-and-reviews#Best-practices).

## Querying App Installation Source

Determining which source was used to install the app (Apple App store, Google Play Store, AltStore, F-Droid, etc.) can be useful for determining what billing mechanism to use. This can be done by querying the `Marketplace.current.installationSource` property like:

```swift
switch await Marketplace.current.installationSource {
case .appleAppStore: canUseNativeBillling = true
case .googlePlayStore: canUseNativeBillling = true
case .other(let id): canUseNativeBillling = false // handle other markerplaces here
default: canUseNativeBillling = false
}
```

## Listing and purchasing digital goods

### Android Configuration

You must set the `com.android.vending.BILLING` permission in your `AndroidManifest.xml` file like so:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="com.android.vending.BILLING"/>
</manifest>
```

## Building

This project is a free Swift Package Manager module that uses the
[Skip](https://skip.tools) plugin to transpile Swift into Kotlin.

Building the module requires that Skip be installed using
[Homebrew](https://brew.sh) with `brew install skiptools/skip/skip`.
This will also install the necessary build prerequisites:
Kotlin, Gradle, and the Android build tools.

## Testing

The module can be tested using the standard `swift test` command
or by running the test target for the macOS destination in Xcode,
which will run the Swift tests as well as the transpiled
Kotlin JUnit tests in the Robolectric Android simulation environment.

Parity testing can be performed with `skip test`,
which will output a table of the test results for both platforms.

## License

This software is licensed under the
[GNU Lesser General Public License v3.0](https://spdx.org/licenses/LGPL-3.0-only.html),
with a [linking exception](https://spdx.org/licenses/LGPL-3.0-linking-exception.html)
to clarify that distribution to restricted environments (e.g., app stores) is permitted.
