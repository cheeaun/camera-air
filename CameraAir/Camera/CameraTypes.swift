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
    case portrait34 = "portrait34"
    case portrait916 = "portrait916"
    case square = "square"
    case classic32 = "classic32"
    case standard43 = "standard43"
    case widescreen169 = "widescreen169"

    // Legacy case mapping for stored settings
    case standard = "standard"
    case classic = "classic"
    case widescreen = "widescreen"
    case vertical = "vertical"

    static var allCases: [AspectRatioOption] {
        [.portrait34, .portrait916, .square, .classic32, .standard43, .widescreen169]
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait34:
            return "3:4"
        case .portrait916, .vertical:
            return "9:16"
        case .square:
            return "1:1"
        case .classic32, .classic:
            return "3:2"
        case .standard43, .standard:
            return "4:3"
        case .widescreen169, .widescreen:
            return "16:9"
        }
    }

    var cropRatio: CGFloat {
        switch self {
        case .portrait34:
            return 3.0 / 4.0
        case .portrait916, .vertical:
            return 9.0 / 16.0
        case .square:
            return 1.0
        case .classic32, .classic:
            return 3.0 / 2.0
        case .standard43, .standard:
            return 4.0 / 3.0
        case .widescreen169, .widescreen:
            return 16.0 / 9.0
        }
    }

    /// Normalize legacy values to current cases
    var normalized: AspectRatioOption {
        switch self {
        case .standard: return .standard43
        case .classic: return .classic32
        case .widescreen: return .widescreen169
        case .vertical: return .portrait916
        default: return self
        }
    }

    var isSquare: Bool {
        self == .square
    }

    func title(for orientation: AspectOrientation) -> String {
        title
    }

    func cropRatio(for orientation: AspectOrientation) -> CGFloat {
        cropRatio
    }

    func paired(for orientation: AspectOrientation) -> AspectRatioOption {
        switch orientation {
        case .portrait:
            switch self {
            case .standard43:
                return .portrait34
            case .widescreen169:
                return .portrait916
            case .portrait34, .portrait916:
                return normalized
            case .square, .classic32:
                return orientation.defaultAspectRatio
            case .standard, .classic, .widescreen, .vertical:
                return normalized.paired(for: orientation)
            }
        case .landscape:
            switch self {
            case .portrait34:
                return .standard43
            case .portrait916:
                return .widescreen169
            case .standard43, .widescreen169:
                return normalized
            case .square, .classic32:
                return orientation.defaultAspectRatio
            case .standard, .classic, .widescreen, .vertical:
                return normalized.paired(for: orientation)
            }
        case .square:
            return .square
        }
    }
}

enum AspectOrientation: String, CaseIterable, Identifiable, Codable {
    case portrait
    case landscape
    case square

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .portrait:
            return "rectangle.portrait"
        case .landscape:
            return "rectangle"
        case .square:
            return "square"
        }
    }

    var isSquare: Bool {
        self == .square
    }

    var selectableAspectRatios: [AspectRatioOption] {
        switch self {
        case .portrait:
            return [.portrait34, .portrait916]
        case .landscape:
            return [.standard43, .widescreen169]
        case .square:
            return [.square]
        }
    }

    var defaultAspectRatio: AspectRatioOption {
        selectableAspectRatios.first ?? .portrait34
    }

    func coercedAspectRatio(_ aspectRatio: AspectRatioOption) -> AspectRatioOption {
        let normalizedAspectRatio = aspectRatio.normalized
        if selectableAspectRatios.contains(normalizedAspectRatio) {
            return normalizedAspectRatio
        }

        switch (self, normalizedAspectRatio) {
        case (.portrait, .standard43):
            return .portrait34
        case (.portrait, .widescreen169):
            return .portrait916
        case (.landscape, .portrait34):
            return .standard43
        case (.landscape, .portrait916):
            return .widescreen169
        default:
            return defaultAspectRatio
        }
    }
}

enum NightModePreference: String, CaseIterable, Identifiable, Codable {
    case max
    case auto
    case off

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    static var cyclingOrder: [NightModePreference] { [.max, .auto, .off] }
}

enum ZoomLevel: String, CaseIterable, Identifiable, Codable {
    case wide
    case standard
    case telephoto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wide: return "0.5x"
        case .standard: return "1x"
        case .telephoto: return "2x"
        }
    }

    var factor: CGFloat {
        switch self {
        case .wide: return 0.5
        case .standard: return 1.0
        case .telephoto: return 2.0
        }
    }

    var systemImage: String {
        switch self {
        case .wide: return "minus.magnifyingglass"
        case .standard: return "1.magnifyingglass"
        case .telephoto: return "plus.magnifyingglass"
        }
    }
}

struct CameraSettings: Equatable, Codable {
    var flash: FlashPreference = .auto
    var isLivePhotoEnabled = true
    var isExposureLocked = false
    var aspectRatio: AspectRatioOption = .portrait34
    var aspectOrientation: AspectOrientation = .portrait
    var nightMode: NightModePreference = .max
    var zoomLevel: ZoomLevel = .standard
    var customZoomFactor: CGFloat = 1.0

    init(
        flash: FlashPreference = .auto,
        isLivePhotoEnabled: Bool = true,
        isExposureLocked: Bool = false,
        aspectRatio: AspectRatioOption = .portrait34,
        aspectOrientation: AspectOrientation = .portrait,
        nightMode: NightModePreference = .auto,
        zoomLevel: ZoomLevel = .standard,
        customZoomFactor: CGFloat = 1.0
    ) {
        self.flash = flash
        self.isLivePhotoEnabled = isLivePhotoEnabled
        self.isExposureLocked = isExposureLocked
        self.aspectRatio = aspectRatio
        self.aspectOrientation = aspectOrientation
        self.nightMode = nightMode
        self.zoomLevel = zoomLevel
        self.customZoomFactor = customZoomFactor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CameraSettings()
        flash = (try? container.decode(FlashPreference.self, forKey: .flash)) ?? defaults.flash
        isLivePhotoEnabled = (try? container.decode(Bool.self, forKey: .isLivePhotoEnabled)) ?? defaults.isLivePhotoEnabled
        isExposureLocked = (try? container.decode(Bool.self, forKey: .isExposureLocked)) ?? defaults.isExposureLocked
        // Normalize legacy aspect ratio values
        let rawAspectRatio = (try? container.decode(AspectRatioOption.self, forKey: .aspectRatio)) ?? defaults.aspectRatio
        aspectRatio = rawAspectRatio.normalized
        aspectOrientation = (try? container.decode(AspectOrientation.self, forKey: .aspectOrientation)) ?? defaults.aspectOrientation
        aspectRatio = aspectOrientation.coercedAspectRatio(aspectRatio)
        nightMode = (try? container.decode(NightModePreference.self, forKey: .nightMode)) ?? defaults.nightMode
        zoomLevel = (try? container.decode(ZoomLevel.self, forKey: .zoomLevel)) ?? defaults.zoomLevel
        customZoomFactor = (try? container.decode(CGFloat.self, forKey: .customZoomFactor)) ?? defaults.customZoomFactor
    }
}

struct CameraCapabilities: Equatable {
    var hasFlash = false
    var supportsLivePhoto = false
    var supportsLowLightBoost = false
    var supportsExposureLock = false
    var supportedZoomLevels: [ZoomLevel] = [.standard]
    var supportedZoomFactors: [CGFloat] = [1.0]
    var maxZoomFactor: CGFloat = 1.0
    var minZoomFactor: CGFloat = 1.0

    var selectableZoomRange: ClosedRange<CGFloat> {
        let lowerBound = supportedZoomFactors.first ?? 1.0
        let upperBound = supportedZoomFactors.last ?? lowerBound
        return lowerBound...max(upperBound, lowerBound)
    }
}

extension CGFloat {
    var cameraZoomLabel: String {
        let roundedValue = (Double(self) * 10).rounded() / 10
        if abs(roundedValue.rounded() - roundedValue) < 0.05 {
            return String(format: "%.0fx", roundedValue)
        }

        return String(format: "%.1fx", roundedValue)
    }
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
