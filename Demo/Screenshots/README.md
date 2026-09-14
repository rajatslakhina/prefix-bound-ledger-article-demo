# Screenshots

**No Simulator screenshot exists for this repo yet.** The build that produced this repo ran as an
unattended scheduled session; the computer-use grant for Xcode and Simulator cannot be approved in
that mode (the request was made twice and refused with "can't be approved during a scheduled run"),
so `Demo.xcodeproj` was never opened and the app was never launched here.

What *was* verified: `swift build` (0 warnings) and `swift test` (13/13) on Swift 6.0.3, Linux
aarch64. `LedgerDemoView.swift` is behind `#if canImport(SwiftUI)` and was reviewed by hand, not
compiled. If you run it and take a screenshot, a PR adding it here is very welcome.
