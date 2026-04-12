import CoreGraphics
import Foundation
import AVFoundation

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case photo
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        }
    }
}

enum CameraLens: String, CaseIterable, Identifiable, Codable {
    case back
    case front

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back:
            return "Back"
        case .front:
            return "Front"
        }
    }

    var capturePosition: AVCaptureDevice.Position {
        switch self {
        case .back:
            return .back
        case .front:
            return .front
        }
    }
}

enum FlashPreference: String, CaseIterable, Identifiable, Codable {
    case auto
    case on
    case off

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var systemImage: String {
        switch self {
        case .auto:
            return "bolt.badge.a.fill"
        case .on:
            return "bolt.fill"
        case .off:
            return "bolt.slash.fill"
        }
    }

    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto:
            return .auto
        case .on:
            return .on
        case .off:
            return .off
        }
    }
}

enum AspectRatioOption: String, CaseIterable, Identifiable, Codable {
    case standard
    case classic
    case square
    case widescreen
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            return "4:3"
        case .classic:
            return "3:2"
        case .square:
            return "1:1"
        case .widescreen:
            return "16:9"
        case .vertical:
            return "9:16"
        }
    }

    var cropRatio: CGFloat {
        switch self {
        case .standard:
            return 4.0 / 3.0
        case .classic:
            return 3.0 / 2.0
        case .square:
            return 1.0
        case .widescreen:
            return 16.0 / 9.0
        case .vertical:
            return 9.0 / 16.0
        }
    }

}

enum NightModePreference: String, CaseIterable, Identifiable, Codable {
    case auto
    case on
    case off

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

struct CameraSettings: Equatable, Codable {
    var flash: FlashPreference = .auto
    var isLivePhotoEnabled = true
    var isExposureLocked = false
    var aspectRatio: AspectRatioOption = .standard
    var nightMode: NightModePreference = .auto

    init(
        flash: FlashPreference = .auto,
        isLivePhotoEnabled: Bool = true,
        isExposureLocked: Bool = false,
        aspectRatio: AspectRatioOption = .standard,
        nightMode: NightModePreference = .auto
    ) {
        self.flash = flash
        self.isLivePhotoEnabled = isLivePhotoEnabled
        self.isExposureLocked = isExposureLocked
        self.aspectRatio = aspectRatio
        self.nightMode = nightMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CameraSettings()
        flash = (try? container.decode(FlashPreference.self, forKey: .flash)) ?? defaults.flash
        isLivePhotoEnabled = (try? container.decode(Bool.self, forKey: .isLivePhotoEnabled)) ?? defaults.isLivePhotoEnabled
        isExposureLocked = (try? container.decode(Bool.self, forKey: .isExposureLocked)) ?? defaults.isExposureLocked
        aspectRatio = (try? container.decode(AspectRatioOption.self, forKey: .aspectRatio)) ?? defaults.aspectRatio
        nightMode = (try? container.decode(NightModePreference.self, forKey: .nightMode)) ?? defaults.nightMode
    }
}

struct CameraCapabilities: Equatable {
    var hasFlash = false
    var supportsLivePhoto = false
    var supportsLowLightBoost = false
    var supportsExposureLock = false
}

struct CameraRoute: Equatable {
    let mode: CaptureMode
    let lens: CameraLens
    let shouldStartRecording: Bool

    init(mode: CaptureMode, lens: CameraLens, shouldStartRecording: Bool = false) {
        self.mode = mode
        self.lens = lens
        self.shouldStartRecording = shouldStartRecording
    }

    init?(url: URL) {
        guard url.scheme == "cameraair" else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let modeValue = queryItems.first(where: { $0.name == "mode" })?.value ?? CaptureMode.photo.rawValue
        let lensValue = queryItems.first(where: { $0.name == "lens" })?.value ?? CameraLens.back.rawValue
        let shouldRecordValue = queryItems.first(where: { $0.name == "record" })?.value

        guard let mode = CaptureMode(rawValue: modeValue),
              let lens = CameraLens(rawValue: lensValue) else {
            return nil
        }

        self.mode = mode
        self.lens = lens
        self.shouldStartRecording = shouldRecordValue == "1"
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "cameraair"
        components.host = "capture"
        components.queryItems = [
            URLQueryItem(name: "mode", value: mode.rawValue),
            URLQueryItem(name: "lens", value: lens.rawValue),
            URLQueryItem(name: "record", value: shouldStartRecording ? "1" : "0")
        ]

        return components.url ?? URL(string: "cameraair://capture")!
    }
}
