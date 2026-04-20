@RTK.md

# Camera Air

iOS SwiftUI camera app (iOS 26.0+, Xcode 17.0+).

## Build

```bash
xcodebuild -scheme CameraAir -destination 'platform=iOS Simulator,name=iPhone 13 mini' build
```

## Test

```bash
xcodebuild test -scheme CameraAir -destination 'platform=iOS Simulator,name=iPhone 13 mini'
```

## Architecture

- `CameraAir/App/` — App entry (`CameraAirApp.swift`), root view (`CameraRootView.swift`)
- `CameraAir/Camera/` — Camera capture (`CameraSessionController.swift`, `CameraPreviewView.swift`, `CameraTypes.swift`)
- `CameraAir/AppIntents/` — Siri/Shortcuts integration (`CameraAppIntents.swift`)

## URL Scheme

```
cameraair://open?mode=photo&lens=back
cameraair://open?mode=video&lens=front
```

## Skills Available

- `app-intents` — App Intents for Siri/Shortcuts
- `swiftui-patterns` — SwiftUI MV and state management
- `swiftui-view-refactor` — SwiftUI view refactoring
- `swiftui-liquid-glass` — iOS 26+ Liquid Glass API
- `swiftui-performance` — SwiftUI performance auditing
- `ios-debugger-agent` — Xcode build/run/debug

Use `skill` tool to load any of these skills when working on related tasks.