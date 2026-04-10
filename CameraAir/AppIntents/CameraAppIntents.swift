import AppIntents

enum CameraModeAppEnum: String, CaseIterable, AppEnum {
    case photo
    case video

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Camera Mode")
    static let caseDisplayRepresentations: [CameraModeAppEnum: DisplayRepresentation] = [
        .photo: DisplayRepresentation(title: "Photo"),
        .video: DisplayRepresentation(title: "Video")
    ]
}

enum CameraLensAppEnum: String, CaseIterable, AppEnum {
    case back
    case front

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Camera Lens")
    static let caseDisplayRepresentations: [CameraLensAppEnum: DisplayRepresentation] = [
        .back: DisplayRepresentation(title: "Back"),
        .front: DisplayRepresentation(title: "Front")
    ]
}

struct OpenCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Camera"
    static let description = IntentDescription("Open Camera Air directly in a chosen capture mode.")

    @Parameter(title: "Mode")
    var mode: CameraModeAppEnum

    @Parameter(title: "Lens")
    var lens: CameraLensAppEnum

    init() {
        self.mode = .photo
        self.lens = .back
    }

    init(mode: CameraModeAppEnum, lens: CameraLensAppEnum) {
        self.mode = mode
        self.lens = lens
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        let route = CameraRoute(
            mode: CaptureMode(rawValue: mode.rawValue) ?? .photo,
            lens: CameraLens(rawValue: lens.rawValue) ?? .back
        )
        return .result(opensIntent: OpenURLIntent(route.url))
    }
}

struct CaptureSelfieIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Selfie"
    static let description = IntentDescription("Jump straight into the front camera for quick selfies.")

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        let route = CameraRoute(mode: .photo, lens: .front)
        return .result(opensIntent: OpenURLIntent(route.url))
    }
}

struct StartVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Video"
    static let description = IntentDescription("Open Camera Air in video mode and begin recording.")

    @Parameter(title: "Lens")
    var lens: CameraLensAppEnum

    init() {
        self.lens = .back
    }

    init(lens: CameraLensAppEnum) {
        self.lens = lens
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        let route = CameraRoute(
            mode: .video,
            lens: CameraLens(rawValue: lens.rawValue) ?? .back,
            shouldStartRecording: true
        )
        return .result(opensIntent: OpenURLIntent(route.url))
    }
}

struct CameraAirShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenCameraIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Launch \(.applicationName) camera",
                "Open \(.applicationName) in \(\.$mode)"
            ],
            shortTitle: "Open Camera",
            systemImageName: "camera.fill"
        )

        AppShortcut(
            intent: CaptureSelfieIntent(),
            phrases: [
                "Take a selfie with \(.applicationName)",
                "Open selfie mode in \(.applicationName)"
            ],
            shortTitle: "Selfie",
            systemImageName: "person.crop.square"
        )

        AppShortcut(
            intent: StartVideoIntent(),
            phrases: [
                "Record video with \(.applicationName)",
                "Start video in \(.applicationName)"
            ],
            shortTitle: "Start Video",
            systemImageName: "video.fill"
        )
    }
}
