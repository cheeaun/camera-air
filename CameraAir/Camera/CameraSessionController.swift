@preconcurrency import AVFoundation
@preconcurrency import Photos
import ImageIO
import UIKit

final class CameraSessionController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var mode: CaptureMode = .photo
    @Published private(set) var lens: CameraLens = .back
    @Published private(set) var settings = CameraSettings()
    @Published private(set) var rememberLastSettings = CameraRememberLastSettings()
    @Published private(set) var capabilities = CameraCapabilities()
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var isCameraAccessDenied = false
    @Published private(set) var latestThumbnail: UIImage?
    @Published var latestCaptureAsset: PHAsset?
    @Published private(set) var recentCaptureAssets: [PHAsset] = []
    @Published var isRecentCapturesPresented = false
    @Published private(set) var lastCapturedAsset: PHAsset?
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    let session = AVCaptureSession()

    private static let settingsKey = "CameraAir.Settings"
    private static let rememberLastSettingsKey = "CameraAir.RememberLastSettings"
    private static let modeKey = "CameraAir.Mode"
    private static let lensKey = "CameraAir.Lens"
    private static let lastCapturedKey = "CameraAir.LastCaptured"
    private static let recentCapturedKey = "CameraAir.RecentCaptured"
    private static let maxRecentCaptureCount = 100

    private var lastCapturedLocalIdentifier: String? {
        get { UserDefaults.standard.string(forKey: Self.lastCapturedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastCapturedKey) }
    }

    private var recentCapturedLocalIdentifiers: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.recentCapturedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.recentCapturedKey) }
    }

    private let sessionQueue = DispatchQueue(label: "CameraAir.SessionQueue")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

    private var recordingStartTime: Date?
    private var recordingTimer: Timer?
    
    // Video data output for lightweight preview sampling (used for night badge estimation)
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "CameraAir.VideoOutputQueue")

    // Remember a user's Live Photo preference so we can restore it after night mode changes
    private var previousLivePhotoEnabled: Bool?
    private var currentVideoInput: AVCaptureDeviceInput?
    private var currentAudioInput: AVCaptureDeviceInput?
    private var photoCaptureProcessor: PhotoCaptureProcessor?
    private var recordingAspectRatio: AspectRatioOption?
    private var isConfigured = false
    private var hasPrepared = false
    private var pendingRoute: CameraRoute?
    private var isOpeningCapture = false

    private let displayZoomCeiling: CGFloat = 10.0
    private let livePhotoSupportOverride: Bool?

    override init() {
        let env = ProcessInfo.processInfo.environment
        if let overrideValue = env["CAMERA_AIR_UI_TEST_LIVE_PHOTO_SUPPORTED"] {
            livePhotoSupportOverride = (overrideValue as NSString).boolValue
        } else {
            livePhotoSupportOverride = nil
        }
        super.init()
        if let livePhotoSupportOverride {
            capabilities.supportsLivePhoto = livePhotoSupportOverride
        }
        loadRememberLastSettings()
        loadSettings()
        loadLastCapturedAsset()
    }

    var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    private func loadRememberLastSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.rememberLastSettingsKey),
              let decoded = try? JSONDecoder().decode(CameraRememberLastSettings.self, from: data) else { return }
        rememberLastSettings = decoded
    }

    private func loadSettings() {
        var loadedSettings = CameraSettings()
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(CameraSettings.self, from: data) {
            if rememberLastSettings.remembers(.flash) { loadedSettings.flash = decoded.flash }
            if rememberLastSettings.remembers(.aspectRatio) { loadedSettings.aspectRatio = decoded.aspectRatio }
            if rememberLastSettings.remembers(.orientation) {
                loadedSettings.aspectOrientation = decoded.aspectOrientation
                loadedSettings.aspectRatio = decoded.aspectOrientation.coercedAspectRatio(loadedSettings.aspectRatio)
            }
            if rememberLastSettings.remembers(.exposure) { loadedSettings.isExposureLocked = decoded.isExposureLocked }
            if rememberLastSettings.remembers(.nightMode) { loadedSettings.nightMode = decoded.nightMode }
            if rememberLastSettings.remembers(.livePhoto) { loadedSettings.isLivePhotoEnabled = decoded.isLivePhotoEnabled }
            if rememberLastSettings.remembers(.zoom) {
                loadedSettings.zoomLevel = decoded.zoomLevel
                loadedSettings.customZoomFactor = decoded.customZoomFactor
            }
            loadedSettings.aspectRatio = loadedSettings.aspectOrientation.coercedAspectRatio(loadedSettings.aspectRatio)
        }
        settings = loadedSettings

        if rememberLastSettings.remembers(.mode),
           let rawMode = UserDefaults.standard.string(forKey: Self.modeKey),
           let decodedMode = CaptureMode(rawValue: rawMode) {
            mode = decodedMode
        }
        if rememberLastSettings.remembers(.lens),
           let rawLens = UserDefaults.standard.string(forKey: Self.lensKey),
           let decodedLens = CameraLens(rawValue: rawLens) {
            lens = decodedLens
        }
    }

    private func loadLastCapturedAsset() {
        var identifiers = recentCapturedLocalIdentifiers
        if identifiers.isEmpty, let legacyIdentifier = lastCapturedLocalIdentifier {
            identifiers = [legacyIdentifier]
        }
        guard identifiers.isEmpty == false else { return }

        let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetByIdentifier: [String: PHAsset] = [:]
        fetchedAssets.enumerateObjects { asset, _, _ in
            assetByIdentifier[asset.localIdentifier] = asset
        }

        let orderedAssets = identifiers.compactMap { assetByIdentifier[$0] }
        recentCapturedLocalIdentifiers = orderedAssets.map(\.localIdentifier)

        guard let latestAsset = orderedAssets.first else {
            lastCapturedLocalIdentifier = nil
            return
        }

        lastCapturedAsset = latestAsset
        recentCaptureAssets = orderedAssets
        loadThumbnailForAsset(latestAsset)
    }

    private func loadThumbnailForAsset(_ asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true

        let targetSize = CGSize(width: 116, height: 116)
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            if let image {
                self?.updateThumbnail(image)
            }
        }
    }

    private func saveRememberLastSettings() {
        guard let data = try? JSONEncoder().encode(rememberLastSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.rememberLastSettingsKey)
    }

    private func saveSettings(for rememberedSetting: RememberedCameraSetting) {
        guard rememberLastSettings.remembers(rememberedSetting) else { return }
        if rememberedSetting == .mode {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            return
        }
        if rememberedSetting == .lens {
            UserDefaults.standard.set(lens.rawValue, forKey: Self.lensKey)
            return
        }

        let existingData = UserDefaults.standard.data(forKey: Self.settingsKey)
        let existingSettings = existingData.flatMap { try? JSONDecoder().decode(CameraSettings.self, from: $0) } ?? CameraSettings()
        var storedSettings = existingSettings

        switch rememberedSetting {
        case .flash:
            storedSettings.flash = settings.flash
        case .aspectRatio:
            storedSettings.aspectRatio = settings.aspectRatio
        case .orientation:
            storedSettings.aspectOrientation = settings.aspectOrientation
            storedSettings.aspectRatio = settings.aspectRatio
        case .exposure:
            storedSettings.isExposureLocked = settings.isExposureLocked
        case .nightMode:
            storedSettings.nightMode = settings.nightMode
        case .livePhoto:
            storedSettings.isLivePhotoEnabled = settings.isLivePhotoEnabled
        case .zoom:
            storedSettings.zoomLevel = settings.zoomLevel
            storedSettings.customZoomFactor = settings.customZoomFactor
        case .mode, .lens:
            break
        }

        guard let data = try? JSONEncoder().encode(storedSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    func setRememberLastSettingsEnabled(_ isEnabled: Bool) {
        guard rememberLastSettings.isEnabled != isEnabled else { return }
        publish {
            self.rememberLastSettings.isEnabled = isEnabled
        }
        saveRememberLastSettings()
    }

    func setRememberLastSetting(_ setting: RememberedCameraSetting, isEnabled: Bool) {
        guard rememberLastSettings.enabledSettings.contains(setting) != isEnabled else { return }
        publish {
            self.rememberLastSettings.setRemembers(setting, isEnabled: isEnabled)
        }
        saveRememberLastSettings()
        if isEnabled {
            saveSettings(for: setting)
        }
    }

    func prepare() {
        if isRunningUITests {
            return
        }
        guard !hasPrepared else { return }
        hasPrepared = true

        Task { [weak self] in
            guard let strongSelf = self else { return }

            let cameraGranted = await Self.requestAccess(for: .video)
            let microphoneGranted = await Self.requestAccess(for: .audio)

            strongSelf.publish {
                strongSelf.isCameraAccessDenied = !cameraGranted
            }

            guard cameraGranted else {
                strongSelf.publish {
                    strongSelf.errorMessage = "Camera access is unavailable."
                }
                return
            }

            strongSelf.configureSessionIfNeeded(includeAudio: microphoneGranted)
        }
    }

    func resumeSession() {
        sessionQueue.async { [weak self] in
            guard let strongSelf = self, strongSelf.isConfigured, !strongSelf.session.isRunning else { return }
            strongSelf.session.startRunning()
            strongSelf.startRecordingIfNeeded()
        }
    }

    func pauseSession() {
        sessionQueue.async { [weak self] in
            guard let strongSelf = self, strongSelf.session.isRunning else { return }
            if strongSelf.movieOutput.isRecording {
                strongSelf.movieOutput.stopRecording()
            }
            strongSelf.session.stopRunning()
        }
        stopRecordingTimer()
    }

    func setMode(_ mode: CaptureMode) {
        guard self.mode != mode else { return }
        publish {
            self.mode = mode
        }
        saveSettings(for: .mode)
        triggerSelectionFeedback()
        showTransientToast("\(mode.title) mode")

        sessionQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.session.beginConfiguration()
            strongSelf.session.sessionPreset = mode == .photo ? .photo : .high
            strongSelf.configureMovieOutput(for: mode)
            strongSelf.session.commitConfiguration()
            strongSelf.updatePhotoOutputDimensions()
            strongSelf.applyCaptureSettings()
            strongSelf.startRecordingIfNeeded()
        }
    }

    func switchLens() {
        setLens(lens == .back ? .front : .back)
    }

    func setLens(_ lens: CameraLens) {
        guard self.lens != lens else { return }
        publish {
            self.lens = lens
        }
        saveSettings(for: .lens)
        triggerSelectionFeedback()
        showTransientToast("\(lens.title) camera")

        sessionQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            let previousInput = strongSelf.currentVideoInput
            guard previousInput?.device.position != lens.capturePosition else { return }
            guard let device = strongSelf.discoverDevice(for: lens.capturePosition),
                  let replacementInput = try? AVCaptureDeviceInput(device: device) else {
                strongSelf.publish {
                    strongSelf.errorMessage = "This camera is not available."
                }
                return
            }

            strongSelf.session.beginConfiguration()
            if let previousInput {
                strongSelf.session.removeInput(previousInput)
            }

            if strongSelf.session.canAddInput(replacementInput) {
                strongSelf.session.addInput(replacementInput)
                strongSelf.currentVideoInput = replacementInput
            } else if let previousInput, strongSelf.session.canAddInput(previousInput) {
                strongSelf.session.addInput(previousInput)
                strongSelf.currentVideoInput = previousInput
            }
            strongSelf.session.commitConfiguration()

            strongSelf.refreshCapabilities()
            // Reset zoom to 1x when switching lenses
            strongSelf.publish {
                strongSelf.settings.zoomLevel = .standard
                strongSelf.settings.customZoomFactor = strongSelf.clampedDisplayZoomFactor(1.0)
            }
            strongSelf.applyCaptureSettings()
            strongSelf.saveSettings(for: .zoom)
            strongSelf.startRecordingIfNeeded()
        }
    }

    func setFlash(_ flash: FlashPreference) {
        guard settings.flash != flash else { return }
        publish {
            self.settings.flash = flash
        }
        saveSettings(for: .flash)
        triggerSelectionFeedback()
        showTransientToast("Flash \(flash.title.lowercased())")
    }

    func toggleLivePhoto() {
        let isEnabled = !settings.isLivePhotoEnabled
        publish {
            self.settings.isLivePhotoEnabled.toggle()
        }
        saveSettings(for: .livePhoto)
        triggerSelectionFeedback()
        showTransientToast(isEnabled ? "Live Photo on" : "Live Photo off")
        sessionQueue.async { [weak self] in
            self?.applyCaptureSettings()
        }
    }

    func toggleExposureLock() {
        let isLocked = !settings.isExposureLocked
        publish {
            self.settings.isExposureLocked.toggle()
        }
        saveSettings(for: .exposure)
        triggerSelectionFeedback()
        showTransientToast(isLocked ? "Exposure locked" : "Exposure unlocked")
        sessionQueue.async { [weak self] in
            self?.applyCaptureSettings()
        }
    }

    func setAspectRatio(_ aspectRatio: AspectRatioOption) {
        let normalizedAspectRatio = aspectRatio.normalized
        let nextOrientation: AspectOrientation = if normalizedAspectRatio.isSquare {
            .square
        } else if settings.aspectOrientation == .square {
            .portrait
        } else {
            settings.aspectOrientation
        }
        let nextAspectRatio = nextOrientation.coercedAspectRatio(normalizedAspectRatio)
        guard settings.aspectRatio != nextAspectRatio || settings.aspectOrientation != nextOrientation else { return }
        publish {
            self.settings.aspectRatio = nextAspectRatio
            self.settings.aspectOrientation = nextOrientation
        }
        saveSettings(for: .aspectRatio)
        saveSettings(for: .orientation)
        triggerSelectionFeedback()
        showTransientToast("Aspect ratio \(nextAspectRatio.title(for: nextOrientation))")
    }

    func cycleAspectRatio() {
        guard !settings.aspectOrientation.isSquare else { return }

        let allCases = settings.aspectOrientation.selectableAspectRatios
        let currentAspectRatio = settings.aspectOrientation.coercedAspectRatio(settings.aspectRatio)
        let currentIndex = allCases.firstIndex(of: currentAspectRatio) ?? 0
        let nextIndex = (currentIndex + 1) % allCases.count
        setAspectRatio(allCases[nextIndex])
    }

    func cycleAspectOrientation() {
        let currentOrientation = settings.aspectOrientation
        let nextOrientation: AspectOrientation
        let nextAspectRatio: AspectRatioOption
        switch currentOrientation {
        case .portrait:
            nextOrientation = .square
            nextAspectRatio = .square
        case .square:
            nextOrientation = .landscape
            nextAspectRatio = settings.aspectRatio.paired(for: nextOrientation)
        case .landscape:
            nextOrientation = .portrait
            nextAspectRatio = settings.aspectRatio.paired(for: nextOrientation)
        }

        publish {
            self.settings.aspectOrientation = nextOrientation
            self.settings.aspectRatio = nextOrientation.coercedAspectRatio(nextAspectRatio)
        }
        saveSettings(for: .aspectRatio)
        saveSettings(for: .orientation)
        triggerSelectionFeedback()
        showTransientToast("Orientation \(nextOrientation.rawValue)")
    }

    func setNightMode(_ nightMode: NightModePreference) {
        guard settings.nightMode != nightMode else { return }
        publish {
            self.settings.nightMode = nightMode
        }

        saveSettings(for: .nightMode)
        triggerSelectionFeedback()
        showTransientToast("Night mode \(nightMode.title.lowercased())")
        sessionQueue.async { [weak self] in
            self?.applyCaptureSettings()
        }
    }

    func cycleNightMode() {
        if settings.nightMode == .off {
            setNightMode(.auto)
        } else {
            setNightMode(.off)
        }
    }

    func setZoomLevel(_ zoomLevel: ZoomLevel) {
        setCustomZoomFactor(zoomLevel.factor, persist: true, animated: true)
    }

    func setCustomZoomFactor(_ factor: CGFloat, persist: Bool = false, animated: Bool = false) {
        let clampedFactor = clampedDisplayZoomFactor(factor)
        publish {
            self.settings.customZoomFactor = clampedFactor
            self.settings.zoomLevel = self.closestZoomLevel(for: clampedFactor)
        }
        if persist {
            saveSettings(for: .zoom)
        }
        sessionQueue.async { [weak self] in
            self?.applyZoomSettings(animated: animated)
        }
    }

    func commitZoomSelection() {
        saveSettings(for: .zoom)
    }

    func performPrimaryAction() {
        switch mode {
        case .photo:
            capturePhoto()
        case .video:
            isRecording ? stopRecording() : startRecording()
        }
    }

    func handleDeepLink(_ url: URL) {
        guard let route = CameraRoute(url: url) else { return }
        pendingRoute = route
        setMode(route.mode)
        setLens(route.lens)

        if route.shouldStartRecording {
            sessionQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.startRecordingIfNeeded()
            }
        }
    }

    func openLatestCapture() {
        guard let asset = recentCaptureAssets.first else {
            showTransientError("No recent captures from this app.")
            return
        }
        openCapture(asset)
    }

    func openRecentCaptures() {
        guard recentCaptureAssets.isEmpty == false else {
            showTransientError("No recent captures from this app.")
            return
        }
        publish {
            self.isRecentCapturesPresented = true
        }
    }

    func dismissRecentCaptures() {
        publish {
            self.isRecentCapturesPresented = false
        }
    }

    func openCapture(_ asset: PHAsset) {
        guard !isOpeningCapture else { return }
        isOpeningCapture = true

        Task { @MainActor [weak self] in
            guard let strongSelf = self else { return }

            guard asset.localIdentifier.count > 0 else {
                strongSelf.showTransientError("Capture is no longer available.")
                strongSelf.isOpeningCapture = false
                return
            }

            strongSelf.latestCaptureAsset = asset
            strongSelf.isOpeningCapture = false
        }
    }

    func dismissLatestCapture() {
        publish {
            self.latestCaptureAsset = nil
        }
    }

    private func configureSessionIfNeeded(includeAudio: Bool) {
        sessionQueue.async { [weak self] in
            guard let strongSelf = self, !strongSelf.isConfigured else { return }

            strongSelf.session.beginConfiguration()
            strongSelf.session.sessionPreset = .photo

            if let videoDevice = strongSelf.discoverDevice(for: strongSelf.lens.capturePosition),
               let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
               strongSelf.session.canAddInput(videoInput) {
                strongSelf.session.addInput(videoInput)
                strongSelf.currentVideoInput = videoInput
            }

            if includeAudio,
               let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               strongSelf.session.canAddInput(audioInput) {
                strongSelf.configureAudioSessionForHapticsDuringRecording()
                strongSelf.session.addInput(audioInput)
                strongSelf.currentAudioInput = audioInput
            }

            if strongSelf.session.canAddOutput(strongSelf.photoOutput) {
                strongSelf.session.addOutput(strongSelf.photoOutput)
                strongSelf.photoOutput.maxPhotoQualityPrioritization = .speed
            }

            // Add a lightweight video data output for preview-sampling (disabled delegate by default)
            if strongSelf.session.canAddOutput(strongSelf.videoDataOutput) {
                strongSelf.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                strongSelf.videoDataOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ]
                strongSelf.videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
                strongSelf.session.addOutput(strongSelf.videoDataOutput)
            }

            strongSelf.configureMovieOutput(for: strongSelf.mode)

            strongSelf.session.commitConfiguration()
            strongSelf.isConfigured = true
            strongSelf.updatePhotoOutputDimensions()
            strongSelf.session.startRunning()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                strongSelf.refreshCapabilities()
                strongSelf.applyCaptureSettings()
            }
            strongSelf.startRecordingIfNeeded()
        }
    }

    private func capturePhoto() {
        triggerCaptureFeedback()
        sessionQueue.async { [weak self] in
            guard let strongSelf = self, strongSelf.isConfigured, strongSelf.session.isRunning else { return }

            // Avoid reconfiguring the session on every shutter press; only ensure `.photo`
            // preset when it may still be `.high` after switching from video mode.
            if strongSelf.session.sessionPreset != .photo {
                strongSelf.session.beginConfiguration()
                strongSelf.session.sessionPreset = .photo
                strongSelf.session.commitConfiguration()
            }
            strongSelf.updatePhotoOutputDimensions()

            guard let maxPhotoDimensions = strongSelf.photoOutput.maxPhotoDimensionsIfSupported,
                  strongSelf.canCapturePhoto(with: maxPhotoDimensions) else {
                strongSelf.showTransientError("Photo capture is unavailable for this camera setup.")
                return
            }

            let photoSettings = AVCapturePhotoSettings()
            photoSettings.photoQualityPrioritization = .speed
            photoSettings.maxPhotoDimensions = maxPhotoDimensions

            let livePhotoURL: URL?
            if strongSelf.photoOutput.isLivePhotoCaptureSupported && strongSelf.photoOutput.isLivePhotoCaptureEnabled && strongSelf.settings.isLivePhotoEnabled {
                livePhotoURL = Self.temporaryFileURL(pathExtension: "mov")
                photoSettings.livePhotoMovieFileURL = livePhotoURL
            } else {
                livePhotoURL = nil
            }

            let makeProcessor = { (movieURL: URL?) -> PhotoCaptureProcessor in
                PhotoCaptureProcessor(
                    aspectRatio: strongSelf.settings.aspectRatio,
                    livePhotoMovieURL: movieURL,
                    onThumbnailReady: { [weak self] image in
                        self?.updateThumbnail(image)
                    },
                    onError: { [weak self] message in
                        self?.showTransientError(message)
                    },
                    onFinish: { [weak self] asset in
                        guard let owner = self else { return }
                        if let asset {
                            owner.updateLastCapturedAsset(asset)
                            owner.showTransientToast("Photo saved")
                        }
                        owner.publish {
                            owner.photoCaptureProcessor = nil
                        }
                    }
                )
            }

            var processor = makeProcessor(livePhotoURL)
            strongSelf.photoCaptureProcessor = processor
            var exceptionReason: NSString?
            let didStartCapture = CameraPhotoCaptureSafety.capturePhoto(
                with: strongSelf.photoOutput,
                settings: photoSettings,
                delegate: processor,
                exceptionReason: &exceptionReason
            )

            if didStartCapture {
                return
            }

            if let livePhotoURL {
                try? FileManager.default.removeItem(at: livePhotoURL)
            }
            processor = makeProcessor(nil)
            strongSelf.photoCaptureProcessor = processor
            let fallbackSettings = AVCapturePhotoSettings()
            fallbackSettings.photoQualityPrioritization = .speed
            var fallbackExceptionReason: NSString?
            let didStartFallbackCapture = CameraPhotoCaptureSafety.capturePhoto(
                with: strongSelf.photoOutput,
                settings: fallbackSettings,
                delegate: processor,
                exceptionReason: &fallbackExceptionReason
            )

            if didStartFallbackCapture {
                NSLog(
                    "CameraAir primary photo settings were rejected; fallback capture started. reason=%@",
                    exceptionReason ?? "unknown"
                )
                return
            }

            strongSelf.photoCaptureProcessor = nil
            NSLog(
                "CameraAir photo capture failed to start (primary=%@, fallback=%@)",
                exceptionReason ?? "unknown",
                fallbackExceptionReason ?? "unknown"
            )
            strongSelf.showTransientError("Photo capture failed to start.")
        }
    }

    private func startRecording() {
        triggerCaptureFeedback()
        sessionQueue.async { [weak self] in
            guard let strongSelf = self, strongSelf.isConfigured, !strongSelf.movieOutput.isRecording else { return }
            let outputURL = Self.temporaryFileURL(pathExtension: "mov")
            strongSelf.recordingAspectRatio = strongSelf.settings.aspectRatio
            strongSelf.applyTorchState(isEnabled: strongSelf.settings.flash == .on)
            strongSelf.movieOutput.startRecording(to: outputURL, recordingDelegate: strongSelf)
            strongSelf.publish {
                strongSelf.isRecording = true
                strongSelf.recordingStartTime = Date()
                strongSelf.startRecordingTimer()
            }
            strongSelf.showTransientToast("Recording started")
        }
    }

    private func stopRecording() {
        triggerHeavyHaptic()
        sessionQueue.async { [weak self] in
            guard let strongSelf = self, strongSelf.movieOutput.isRecording else { return }
            strongSelf.movieOutput.stopRecording()
        }
        showTransientToast("Recording stopped")
    }

    private func startRecordingIfNeeded() {
        guard pendingRoute?.shouldStartRecording == true, mode == .video, !movieOutput.isRecording else { return }
        pendingRoute = nil
        startRecording()
    }

    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let strongSelf = self, let startTime = strongSelf.recordingStartTime else { return }
            let duration = Date().timeIntervalSince(startTime)
            strongSelf.publish {
                strongSelf.recordingDuration = duration
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
        publish {
            self.recordingDuration = 0
        }
    }

    private func applyCaptureSettings() {
        // Live Photos include sound; Apple requires a microphone input on the session.
        photoOutput.isLivePhotoCaptureEnabled = Self.shouldEnableLivePhotoCapture(
            outputSupportsLivePhoto: photoOutput.isLivePhotoCaptureSupported,
            userWantsLivePhoto: settings.isLivePhotoEnabled,
            hasAudioInput: currentAudioInput != nil,
            livePhotoSupportOverride: livePhotoSupportOverride
        )

        guard let device = currentVideoInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if capabilities.supportsExposureLock {
                let desiredMode: AVCaptureDevice.ExposureMode = settings.isExposureLocked ? .locked : .continuousAutoExposure
                if device.isExposureModeSupported(desiredMode) {
                    device.exposureMode = desiredMode
                }
            }

            Self.applyLowLightBoost(to: device, enabled: settings.nightMode != .off)
        } catch {
            showTransientError("Unable to update camera settings.")
        }

        applyZoomSettings(animated: false)

        // Re-query capabilities after the session/active format is settled.
        // On iOS 26, low-light boost support depends on the active format,
        // which may not be finalized until the session has started running.
        DispatchQueue.main.async { [weak self] in
            self?.refreshCapabilities()
        }
    }

    private func configureAudioSessionForHapticsDuringRecording() {
        do {
            try AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
        } catch {
            NSLog("CameraAir failed to allow haptics during audio capture: %@", error.localizedDescription)
        }
    }

    private func configureMovieOutput(for mode: CaptureMode) {
        if mode == .photo {
            if session.outputs.contains(movieOutput) {
                session.removeOutput(movieOutput)
            }
            return
        }

        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
    }

    private func applyZoomSettings(animated: Bool) {
        guard let device = currentVideoInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.activeFormat.videoSupportedFrameRateRanges.isEmpty == false {
                let targetZoomFactor = clampedDeviceZoomFactor(for: settings.customZoomFactor, device: device)
                if animated {
                    device.cancelVideoZoomRamp()
                    device.ramp(toVideoZoomFactor: targetZoomFactor, withRate: 28)
                } else {
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = targetZoomFactor
                }
            }
        } catch {
            showTransientError("Unable to update zoom settings.")
        }
    }

    private func updatePhotoOutputDimensions() {
        guard let format = currentVideoInput?.device.activeFormat else { return }

        if let dimensions = Self.preferredPhotoDimensions(for: format) {
            photoOutput.maxPhotoDimensions = dimensions
        }
    }

    private func canCapturePhoto(with dimensions: CMVideoDimensions) -> Bool {
        guard let deviceFormat = currentVideoInput?.device.activeFormat else { return false }

        let supportedDimensions = deviceFormat.supportedMaxPhotoDimensions
        return supportedDimensions.contains(where: { $0.width == dimensions.width && $0.height == dimensions.height })
            && dimensions.width > 0
            && dimensions.height > 0
    }

    private static func preferredPhotoDimensions(for format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        format.supportedMaxPhotoDimensions.max(by: { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        })
    }

    private func refreshCapabilities() {
        let device = currentVideoInput?.device
        let minZoom = displayZoomFactor(for: device?.minAvailableVideoZoomFactor ?? 1.0, on: device)
        let maxZoom = min(displayZoomFactor(for: device?.maxAvailableVideoZoomFactor ?? 1.0, on: device), displayZoomCeiling)
        let supportedZoomFactors = supportedPhysicalZoomFactors(for: device)
        let supportedZoomLevels = supportedZoomFactors.compactMap(Self.zoomLevel(for:))

        let newCapabilities = CameraCapabilities(
            hasFlash: device?.hasFlash ?? false,
            supportsLivePhoto: Self.supportsLivePhotoInSession(
                outputSupportsLivePhoto: photoOutput.isLivePhotoCaptureSupported,
                hasAudioInput: currentAudioInput != nil,
                livePhotoSupportOverride: livePhotoSupportOverride
            ),
            supportsLowLightBoost: Self.deviceSupportsLowLightBoost(device),
            supportsExposureLock: device?.isExposureModeSupported(.locked) ?? false,
            supportedZoomLevels: supportedZoomLevels,
            supportedZoomFactors: supportedZoomFactors,
            maxZoomFactor: maxZoom,
            minZoomFactor: minZoom
        )

        let normalizedZoomFactor = clampedDisplayZoomFactor(settings.customZoomFactor, capabilities: newCapabilities)
        publish {
            self.capabilities = newCapabilities
            self.settings.customZoomFactor = normalizedZoomFactor
            self.settings.zoomLevel = self.closestZoomLevel(for: normalizedZoomFactor)
        }
    }

    private static func deviceSupportsLowLightBoost(_ device: AVCaptureDevice?) -> Bool {
        // Prefer checking the provided device (active camera) and its constituents.
        if let device {
            if Self.deviceOrFormatsSupportLowLightBoost(device) { return true }
            for constituent in device.constituentDevices
            where Self.deviceOrFormatsSupportLowLightBoost(constituent) {
                return true
            }
            return false
        }

        // Fallback: check available back cameras for low-light boost support.
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
            .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera
        ]
        let backDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        ).devices

        for backDevice in backDevices {
            if Self.deviceOrFormatsSupportLowLightBoost(backDevice) { return true }
            for constituent in backDevice.constituentDevices
            where Self.deviceOrFormatsSupportLowLightBoost(constituent) {
                return true
            }
        }

        return false
    }

    /// Returns true if the device or any of its constituents supports low-light boost.
    /// On iOS 26 `isLowLightBoostSupported` reflects the active format, so this
    /// must be re-queried after the session has started running.
    private static func deviceOrFormatsSupportLowLightBoost(_ device: AVCaptureDevice) -> Bool {
        device.isLowLightBoostSupported
    }

    private func discoverDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera]

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position
        ).devices.first
    }

    /// Applies `automaticallyEnablesLowLightBoostWhenAvailable` to the device
    /// and all of its constituent cameras that support low-light boost. The
    /// caller must already hold `lockForConfiguration` on `device`.
    private static func applyLowLightBoost(to device: AVCaptureDevice, enabled: Bool) {
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = enabled
        }
        for constituent in device.constituentDevices where constituent.isLowLightBoostSupported {
            do {
                try constituent.lockForConfiguration()
                constituent.automaticallyEnablesLowLightBoostWhenAvailable = enabled
                constituent.unlockForConfiguration()
            } catch {
                NSLog("CameraAir failed to configure low-light boost on %@: %@", constituent.localizedName, error.localizedDescription)
            }
        }
    }

    private func supportedPhysicalZoomFactors(for device: AVCaptureDevice?) -> [CGFloat] {
        guard let device else { return [1.0] }

        let multiplier = zoomDisplayMultiplier(for: device)
        var factors = Set<CGFloat>()
        let constituentTypes = Set(device.constituentDevices.map(\.deviceType))
        let hasUltraWide = constituentTypes.contains(.builtInUltraWideCamera)
        let hasTelephoto = constituentTypes.contains(.builtInTelephotoCamera)
        let minZoom = displayZoomFactor(for: device.minAvailableVideoZoomFactor, on: device)
        let maxZoom = min(displayZoomFactor(for: device.maxAvailableVideoZoomFactor, on: device), displayZoomCeiling)

        factors.insert(roundedZoomFactor(minZoom))
        factors.insert(roundedZoomFactor(maxZoom))
        factors.insert(1.0)

        if hasUltraWide {
            factors.insert(roundedZoomFactor(1.0 * multiplier))
        }

        for switchOverFactor in device.virtualDeviceSwitchOverVideoZoomFactors where hasTelephoto {
            let displayFactor = roundedZoomFactor(CGFloat(truncating: switchOverFactor) * multiplier)
            if displayFactor > minZoom && displayFactor < maxZoom {
                factors.insert(displayFactor)
            }
        }

        if maxZoom > 1.0 {
            factors.insert(roundedZoomFactor(maxZoom))
        }

        let sortedFactors = factors.sorted()
        return sortedFactors.isEmpty ? [1.0] : sortedFactors
    }

    private func clampedDisplayZoomFactor(_ factor: CGFloat, capabilities: CameraCapabilities? = nil) -> CGFloat {
        let range = (capabilities ?? self.capabilities).selectableZoomRange
        return min(max(factor, range.lowerBound), range.upperBound)
    }

    private func clampedDeviceZoomFactor(for displayFactor: CGFloat, device: AVCaptureDevice) -> CGFloat {
        let rawZoomFactor = displayFactor / zoomDisplayMultiplier(for: device)
        return min(max(rawZoomFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    private func displayZoomFactor(for deviceZoomFactor: CGFloat, on device: AVCaptureDevice?) -> CGFloat {
        guard let device else { return roundedZoomFactor(deviceZoomFactor) }
        return roundedZoomFactor(deviceZoomFactor * zoomDisplayMultiplier(for: device))
    }

    private func zoomDisplayMultiplier(for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) {
            return max(device.displayVideoZoomFactorMultiplier, 0.01)
        }

        return 1.0
    }

    private func closestZoomLevel(for factor: CGFloat) -> ZoomLevel {
        ZoomLevel.allCases.min(by: { abs($0.factor - factor) < abs($1.factor - factor) }) ?? .standard
    }

    private static func zoomLevel(for factor: CGFloat) -> ZoomLevel? {
        if factor <= 0.75 {
            return .wide
        }

        if factor >= 1.5 {
            return .telephoto
        }

        return .standard
    }

    private func roundedZoomFactor(_ factor: CGFloat) -> CGFloat {
        CGFloat((Double(factor) * 10).rounded() / 10)
    }

    private func applyTorchState(isEnabled: Bool) {
        guard let device = currentVideoInput?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if isEnabled && device.isTorchModeSupported(.on) {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else if device.isTorchModeSupported(.off) {
                device.torchMode = .off
            }
        } catch {
            showTransientError("Torch is unavailable on this camera.")
        }
    }

    private func showTransientError(_ message: String) {
        publish {
            self.errorMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard self?.errorMessage == message else { return }
            self?.errorMessage = nil
        }
    }

    private func showTransientToast(_ message: String) {
        publish {
            self.toastMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard self?.toastMessage == message else { return }
            self?.toastMessage = nil
        }
    }

    

    private func triggerSelectionFeedback() {
        Task { @MainActor in
            CameraHaptics.interface()
        }
    }

    private func triggerCaptureFeedback() {
        Task { @MainActor in
            CameraHaptics.rigid()
        }
    }

    private func triggerHeavyHaptic() {
        Task { @MainActor in
            CameraHaptics.heavy()
        }
    }

    private func updateThumbnail(_ image: UIImage?) {
        publish {
            self.latestThumbnail = image
        }
    }

    private func updateLastCapturedAsset(_ asset: PHAsset) {
        var identifiers = recentCapturedLocalIdentifiers.filter { $0 != asset.localIdentifier }
        identifiers.insert(asset.localIdentifier, at: 0)
        if identifiers.count > Self.maxRecentCaptureCount {
            identifiers = Array(identifiers.prefix(Self.maxRecentCaptureCount))
        }

        recentCapturedLocalIdentifiers = identifiers
        lastCapturedLocalIdentifier = asset.localIdentifier
        publish {
            self.lastCapturedAsset = asset
            self.recentCaptureAssets.removeAll { $0.localIdentifier == asset.localIdentifier }
            self.recentCaptureAssets.insert(asset, at: 0)
            if self.recentCaptureAssets.count > Self.maxRecentCaptureCount {
                self.recentCaptureAssets = Array(self.recentCaptureAssets.prefix(Self.maxRecentCaptureCount))
            }
        }
    }

    private func publish(_ updates: @Sendable @escaping () -> Void) {
        if Thread.isMainThread {
            updates()
        } else {
            DispatchQueue.main.async(execute: updates)
        }
    }

    /// Live Photo capture requires a microphone input on the capture session (see Apple’s
    /// “Capturing and saving Live Photos”). Enabling the pipeline without audio can cause
    /// `capturePhoto(with:delegate:)` to throw an `NSException`.
    private static func shouldEnableLivePhotoCapture(
        outputSupportsLivePhoto: Bool,
        userWantsLivePhoto: Bool,
        hasAudioInput: Bool,
        livePhotoSupportOverride: Bool?
    ) -> Bool {
        guard outputSupportsLivePhoto, userWantsLivePhoto else { return false }
        if let livePhotoSupportOverride {
            return livePhotoSupportOverride
        }
        return hasAudioInput
    }

    private static func supportsLivePhotoInSession(
        outputSupportsLivePhoto: Bool,
        hasAudioInput: Bool,
        livePhotoSupportOverride: Bool?
    ) -> Bool {
        if let livePhotoSupportOverride {
            return livePhotoSupportOverride
        }
        return outputSupportsLivePhoto && hasAudioInput
    }

    private static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    private static func temporaryFileURL(pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
    }
}

extension CameraSessionController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        applyTorchState(isEnabled: settings.flash == .on)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        applyTorchState(isEnabled: false)
        let aspectRatio = recordingAspectRatio ?? settings.aspectRatio
        recordingAspectRatio = nil
        publish {
            self.isRecording = false
        }
        stopRecordingTimer()

        guard error == nil else {
            showTransientError("Video capture failed.")
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        Task { @MainActor [weak self] in
            guard let strongSelf = self else {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }

            let authorized = await Self.requestPhotoLibraryAccess()
            guard authorized else {
                try? FileManager.default.removeItem(at: outputFileURL)
                strongSelf.showTransientError("Photo Library access is required to save video.")
                return
            }

            do {
                let videoURL = try await Self.croppedVideoURL(
                    from: outputFileURL,
                    aspectRatio: aspectRatio
                )
                let asset = try await Self.saveVideoToLibrary(from: videoURL)
                let thumbnail = try? await Self.makeVideoThumbnail(from: videoURL)
                strongSelf.updateThumbnail(thumbnail)
                strongSelf.updateLastCapturedAsset(asset)
                strongSelf.showTransientToast("Video saved")
                if videoURL != outputFileURL {
                    try? FileManager.default.removeItem(at: videoURL)
                }
            } catch {
                strongSelf.showTransientError("Unable to save the video.")
            }

            try? FileManager.default.removeItem(at: outputFileURL)
        }
    }

    fileprivate static func requestPhotoLibraryAccess(accessLevel: PHAccessLevel = .readWrite) async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: accessLevel) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: accessLevel) { status in
                    continuation.resume(returning: status == .authorized || status == .limited)
                }
            }
        default:
            return false
        }
    }

    private static func saveVideoToLibrary(from url: URL) async throws -> PHAsset {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PHAsset, Error>) in
            let placeholderBox = PhotoLibraryPlaceholderBox()
            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                placeholderBox.placeholder = creationRequest?.placeholderForCreatedAsset
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success, let placeholder = placeholderBox.placeholder {
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [placeholder.localIdentifier], options: nil)
                    if let asset = assets.firstObject {
                        continuation.resume(returning: asset)
                    } else {
                        continuation.resume(throwing: NSError(domain: "CameraAir.VideoSave", code: 2))
                    }
                } else {
                    continuation.resume(throwing: NSError(domain: "CameraAir.VideoSave", code: 1))
                }
            }
        }
    }

    private static func makeVideoThumbnail(from url: URL) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let result = try await generator.image(at: .zero)
        return UIImage(cgImage: result.image)
    }

    private static func croppedVideoURL(from url: URL, aspectRatio: AspectRatioOption) async throws -> URL {
        try await exportCroppedVideo(from: url, targetRatio: aspectRatio.normalized.cropRatio)
    }

    private static func exportCroppedVideo(from url: URL, targetRatio: CGFloat) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { return url }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformedBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let presentationSize = CGSize(
            width: abs(transformedBounds.width),
            height: abs(transformedBounds.height)
        )
        guard presentationSize.width > 0, presentationSize.height > 0 else { return url }

        let sourceRatio = presentationSize.width / presentationSize.height
        guard abs(sourceRatio - targetRatio) > 0.001 else { return url }

        var cropRect = CGRect(origin: .zero, size: presentationSize)
        if sourceRatio > targetRatio {
            cropRect.size.width = presentationSize.height * targetRatio
            cropRect.origin.x = (presentationSize.width - cropRect.width) / 2
        } else {
            cropRect.size.height = presentationSize.width / targetRatio
            cropRect.origin.y = (presentationSize.height - cropRect.height) / 2
        }
        cropRect = cropRect.integral

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return url
        }

        let duration = try await asset.load(.duration)
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: videoTrack,
            at: .zero
        )

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for audioTrack in audioTracks {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try? compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: audioTrack,
                at: .zero
            )
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        var normalizedTransform = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -transformedBounds.minX,
                y: -transformedBounds.minY
            )
        )
        normalizedTransform = normalizedTransform.concatenating(
            CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
        )

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(normalizedTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = cropRect.size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let outputURL = temporaryFileURL(pathExtension: "mov")
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return url
        }
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

        do {
            try await exportSession.export(to: outputURL, as: .mov)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        return outputURL
    }
}

private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private static let maxCroppedPhotoDimension = 3_000

    private let aspectRatio: AspectRatioOption
    private let livePhotoMovieURL: URL?
    private let onThumbnailReady: @Sendable (UIImage?) -> Void
    private let onError: @Sendable (String) -> Void
    private let onFinish: @Sendable (PHAsset?) -> Void

    private var processedPhotoData: Data?
    private var didFinish = false

    init(
        aspectRatio: AspectRatioOption,
        livePhotoMovieURL: URL?,
        onThumbnailReady: @Sendable @escaping (UIImage?) -> Void,
        onError: @Sendable @escaping (String) -> Void,
        onFinish: @Sendable @escaping (PHAsset?) -> Void
    ) {
        self.aspectRatio = aspectRatio
        self.livePhotoMovieURL = livePhotoMovieURL
        self.onThumbnailReady = onThumbnailReady
        self.onError = onError
        self.onFinish = onFinish
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            onError("Photo capture failed: \(error.localizedDescription)")
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            onError("Photo data is unavailable.")
            return
        }

        processedPhotoData = Self.croppedData(from: data, aspectRatio: aspectRatio)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard !didFinish else { return }
        didFinish = true

        if let error {
            onError("Photo capture failed: \(error.localizedDescription)")
            cleanup()
            return
        }

        guard let processedPhotoData else {
            onError("Photo processing failed.")
            cleanup()
            return
        }

        Task { @MainActor [weak self, processedPhotoData, livePhotoMovieURL] in
            guard let strongSelf = self else { return }

            let authorized = await CameraSessionController.requestPhotoLibraryAccess()
            guard authorized else {
                strongSelf.onError("Photo Library access is required to save photos.")
                strongSelf.cleanup()
                return
            }

            do {
                let asset = try await Self.savePhotoToLibrary(photoData: processedPhotoData, livePhotoMovieURL: livePhotoMovieURL)
                Task.detached { [processedPhotoData] in
                    if let image = UIImage(data: processedPhotoData) {
                        await MainActor.run {
                            strongSelf.onThumbnailReady(image)
                        }
                    }
                }
                strongSelf.onFinish(asset)
            } catch {
                strongSelf.onError("Unable to save the photo.")
                strongSelf.onFinish(nil)
            }
        }
    }

    private func cleanup() {
        if let livePhotoMovieURL {
            try? FileManager.default.removeItem(at: livePhotoMovieURL)
        }
        onFinish(nil)
    }

    private static func savePhotoToLibrary(photoData: Data, livePhotoMovieURL: URL?) async throws -> PHAsset {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PHAsset, Error>) in
            let pairedVideoURL: URL?
            if let livePhotoMovieURL, FileManager.default.fileExists(atPath: livePhotoMovieURL.path) {
                pairedVideoURL = livePhotoMovieURL
            } else {
                pairedVideoURL = nil
            }

            let placeholderBox = PhotoLibraryPlaceholderBox()
            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: photoData, options: nil)
                if let pairedVideoURL {
                    creationRequest.addResource(with: .pairedVideo, fileURL: pairedVideoURL, options: nil)
                }
                placeholderBox.placeholder = creationRequest.placeholderForCreatedAsset
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success, let placeholder = placeholderBox.placeholder {
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [placeholder.localIdentifier], options: nil)
                    if let asset = assets.firstObject {
                        continuation.resume(returning: asset)
                    } else {
                        continuation.resume(throwing: NSError(domain: "CameraAir.PhotoSave", code: 2))
                    }
                } else {
                    continuation.resume(throwing: NSError(domain: "CameraAir.PhotoSave", code: 1))
                }
            }
        }
    }

    private static func croppedData(from data: Data, aspectRatio: AspectRatioOption) -> Data {
        let normalizedAspectRatio = aspectRatio.normalized
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxCroppedPhotoDimension,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
              ),
              let croppedImage = crop(image, to: normalizedAspectRatio.cropRatio),
              let croppedData = jpegData(from: croppedImage) else {
            return data
        }

        return croppedData
    }

    private static func crop(_ image: CGImage, to ratio: CGFloat) -> CGImage? {
        let sourceSize = CGSize(width: image.width, height: image.height)
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let sourceAspect = sourceSize.width / sourceSize.height
        var cropRect = CGRect(origin: .zero, size: sourceSize)

        if sourceAspect > ratio {
            let width = sourceSize.height * ratio
            cropRect.origin.x = (sourceSize.width - width) / 2
            cropRect.size.width = width
        } else {
            let height = sourceSize.width / ratio
            cropRect.origin.y = (sourceSize.height - height) / 2
            cropRect.size.height = height
        }

        return image.cropping(to: cropRect.integral)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: 0.95,
                kCGImagePropertyOrientation: 1
            ] as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private extension AVCapturePhotoOutput {
    var maxPhotoDimensionsIfSupported: CMVideoDimensions? {
        maxPhotoDimensions.width > 0 && maxPhotoDimensions.height > 0 ? maxPhotoDimensions : nil
    }
}

private final class PhotoLibraryPlaceholderBox: @unchecked Sendable {
    var placeholder: PHObjectPlaceholder?
}
