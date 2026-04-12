# Camera Air

A fast, minimal camera app for iOS built with SwiftUI.

## Features

- **Photo & Video Capture** — Switch seamlessly between photo and video modes
- **Front & Back Camera** — Quick lens switching with a single tap
- **Multiple Aspect Ratios** — Choose from 4:3, 3:2, 1:1, 16:9, or 9:16
- **Flash Control** — Auto, on, or off
- **Live Photos** — Enable or disable Live Photo capture
- **Night Mode** — Auto, on, or off for low-light situations
- **Exposure Lock** — Lock exposure for consistent shots

## App Intents & Shortcuts

Camera Air integrates with Siri and Shortcuts:

| Intent             | Description                                    |
| ------------------ | ---------------------------------------------- |
| **Open Camera**    | Launch in photo or video mode with chosen lens |
| **Capture Selfie** | Jump straight to the front camera              |
| **Start Video**    | Open in video mode and begin recording         |

## URL Scheme

Deep link directly into specific modes:

```
cameraair://open?mode=photo&lens=back
cameraair://open?mode=video&lens=front
```

## Requirements

- iOS 26.0+
- Xcode 17.0+

## Building

1. Open `CameraAir.xcodeproj` in Xcode
2. Select your target device or simulator
3. Build and run (⌘R)

## License

MIT
