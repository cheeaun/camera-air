@preconcurrency import AVFoundation
@preconcurrency import Photos
import UIKit

final class CameraSessionController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var mode: CaptureMode = .photo
    @Published private(set) var lens: CameraLens = .back
    @Published private(set) var settings = CameraSettings()
    @Published private(set) var capabilities = CameraCapabilities()
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var isCameraAccessDenied = false
    @Published private(set) var latestThumbnail: UIImage?
    @Published var latestCaptureAsset: PHAsset?
    @Published private(set) var lastCapturedAsset: PHAsset?
    @Published var errorMessage: String?

    let session = AVCaptureSession()

    private static let settingsKey = "CameraAir.Settings"
    private static let lastCapturedKey = "CameraAir.LastCaptured"

    private var lastCapturedLocalIdentifier: String? {
        get { UserDefaults.standard.string(forKey: Self.lastCapturedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastCapturedKey) }
    }

    private let sessionQueue = DispatchQueue(label: "CameraAir.SessionQueue")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

    private var recordingStartTime: Date?
    private var recordingTimer: Timer?

    private var currentVideoInput: AVCaptureDeviceInput?
    private var currentAudioInput: AVCaptureDeviceInput?
    private var photoCaptureProcessor: PhotoCaptureProcessor?
    private var isConfigured = false
    private var hasPrepared = false
    private var pendingRoute: CameraRoute?
    private var isOpeningCapture = false

    override init() {
        super.init()
        loadSettings()
        loadLastCapturedAsset()
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let decoded = try? JSONDecoder().decode(CameraSettings.self, from: data) else { return }
        settings = decoded
    }

    private func loadLastCapturedAsset() {
        guard let id = lastCapturedLocalIdentifier else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else {
            lastCapturedLocalIdentifier = nil
            return
        }
        lastCapturedAsset = asset
        loadThumbnailForAsset(asset)
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

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    func prepare() {
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
        publish {
            self.mode = mode
        }

        sessionQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.session.beginConfiguration()
            strongSelf.session.sessionPreset = mode == .photo ? .photo : .high
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
        publish {
            self.lens = lens
        }

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
            strongSelf.saveSettings()
            strongSelf.startRecordingIfNeeded()
        }
    }

    func setFlash(_ flash: FlashPreference) {
        publish {
            self.settings.flash = flash
        }
        saveSettings()
    }

    func toggleLivePhoto() {
        publish {
            self.settings.isLivePhotoEnabled.toggle()
        }
        saveSettings()
        sessionQueue.async { [weak self] in
            self?.applyCaptureSettings()
        }
    }

    func toggleExposureLock() {
        publish {
            self.settings.isExposureLocked.toggle()
        }
        saveSettings()
        sessionQueue.async { [weak self] in
            self?.applyCaptureSettings()
        }
    }

    func setAspectRatio(_ aspectRatio: AspectRatioOption) {
        publish {
            self.settings.aspectRatio = aspectRatio
        }
        saveSettings()
    }

    func cycleAspectRatio() {
        let allCases = AspectRatioOption.allCases
        guard let currentIndex = allCases.firstIndex(of: settings.aspectRatio) else { return }
        let nextIndex = (currentIndex + 1) % allCases.count
        setAspectRatio(allCases[nextIndex])
    }

    func setNightMode(_ nightMode: NightModePreference) {
        publish {
            self.settings.nightMode = nightMode
        }
        saveSettings()
        sessionQueue.async { [weak self] in
            self?.applyCaptureSettings()
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
            saveSettings()
        }
        sessionQueue.async { [weak self] in
            self?.applyZoomSettings(animated: animated)
        }
    }

    func commitZoomSelection() {
        saveSettings()
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
        guard !isOpeningCapture else { return }
        isOpeningCapture = true

        Task { @MainActor [weak self] in
            guard let strongSelf = self else { return }

            guard let asset = strongSelf.lastCapturedAsset else {
                strongSelf.showTransientError("No recent captures from this app.")
                strongSelf.isOpeningCapture = false
                return
            }

            // Verify the asset is still valid
            guard asset.localIdentifier.count > 0 else {
                strongSelf.showTransientError("Capture is no longer available.")
                strongSelf.isOpeningCapture = false
                return
            }

            strongSelf.publish {
                strongSelf.latestCaptureAsset = asset
            }
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
                strongSelf.session.addInput(audioInput)
                strongSelf.currentAudioInput = audioInput
            }

            if strongSelf.session.canAddOutput(strongSelf.photoOutput) {
                strongSelf.session.addOutput(strongSelf.photoOutput)
                strongSelf.photoOutput.maxPhotoQualityPrioritization = .speed
            }

            if strongSelf.session.canAddOutput(strongSelf.movieOutput) {
                strongSelf.session.addOutput(strongSelf.movieOutput)
            }

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
        sessionQueue.async { [weak self] in
            guard let strongSelf = self, strongSelf.isConfigured, strongSelf.session.isRunning else { return }

            // Prevent capturing if a capture is already in progress
            guard strongSelf.photoCaptureProcessor == nil else { return }

            // Temporarily set session preset to photo to ensure proper capture settings
            strongSelf.session.beginConfiguration()
            strongSelf.session.sessionPreset = .photo
            strongSelf.session.commitConfiguration()
            strongSelf.updatePhotoOutputDimensions()

            let format: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.jpeg]

            let photoSettings = AVCapturePhotoSettings(format: format)
            photoSettings.photoQualityPrioritization = .speed

            let livePhotoURL: URL?
            if strongSelf.photoOutput.isLivePhotoCaptureSupported && strongSelf.photoOutput.isLivePhotoCaptureEnabled && strongSelf.settings.isLivePhotoEnabled {
                livePhotoURL = Self.temporaryFileURL(pathExtension: "mov")
                photoSettings.livePhotoMovieFileURL = livePhotoURL
            } else {
                livePhotoURL = nil
            }

            let processor = PhotoCaptureProcessor(
                aspectRatio: strongSelf.settings.aspectRatio,
                livePhotoMovieURL: livePhotoURL,
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
                    }
                    owner.publish {
                        owner.photoCaptureProcessor = nil
                    }
                }
            )

            strongSelf.photoCaptureProcessor = processor
            strongSelf.photoOutput.capturePhoto(with: photoSettings, delegate: processor)
        }
    }

    private func startRecording() {
        sessionQueue.async { [weak self] in
            guard let strongSelf = self, strongSelf.isConfigured, !strongSelf.movieOutput.isRecording else { return }
            let outputURL = Self.temporaryFileURL(pathExtension: "mov")
            strongSelf.applyTorchState(isEnabled: strongSelf.settings.flash == .on)
            strongSelf.movieOutput.startRecording(to: outputURL, recordingDelegate: strongSelf)
            strongSelf.publish {
                strongSelf.isRecording = true
                strongSelf.recordingStartTime = Date()
                strongSelf.startRecordingTimer()
            }
        }
    }

    private func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let strongSelf = self, strongSelf.movieOutput.isRecording else { return }
            strongSelf.movieOutput.stopRecording()
        }
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
        photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported && settings.isLivePhotoEnabled

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

            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = settings.nightMode != .off
            }
        } catch {
            showTransientError("Unable to update camera settings.")
        }

        applyZoomSettings(animated: false)
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

        if let dimensions = format.supportedMaxPhotoDimensions.max(by: { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }) {
            photoOutput.maxPhotoDimensions = dimensions
        }
    }

    private func refreshCapabilities() {
        let device = currentVideoInput?.device
        let minZoom = displayZoomFactor(for: device?.minAvailableVideoZoomFactor ?? 1.0, on: device)
        let maxZoom = displayZoomFactor(for: device?.maxAvailableVideoZoomFactor ?? 1.0, on: device)
        let supportedZoomFactors = supportedPhysicalZoomFactors(for: device)
        let supportedZoomLevels = supportedZoomFactors.compactMap(Self.zoomLevel(for:))

        let newCapabilities = CameraCapabilities(
            hasFlash: device?.hasFlash ?? false,
            supportsLivePhoto: photoOutput.isLivePhotoCaptureSupported && (device?.position == .back), // Live Photos typically only supported on back camera
            supportsLowLightBoost: device?.isLowLightBoostSupported ?? false,
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

    private func supportedPhysicalZoomFactors(for device: AVCaptureDevice?) -> [CGFloat] {
        guard let device else { return [1.0] }

        let multiplier = zoomDisplayMultiplier(for: device)
        var factors = Set<CGFloat>([1.0])
        let constituentTypes = Set(device.constituentDevices.map(\.deviceType))
        let hasUltraWide = constituentTypes.contains(.builtInUltraWideCamera)
        let hasTelephoto = constituentTypes.contains(.builtInTelephotoCamera)

        if hasUltraWide {
            factors.insert(roundedZoomFactor(1.0 * multiplier))
        }

        for switchOverFactor in device.virtualDeviceSwitchOverVideoZoomFactors where hasTelephoto {
            let displayFactor = roundedZoomFactor(CGFloat(truncating: switchOverFactor) * multiplier)
            if displayFactor > 1.0 {
                factors.insert(displayFactor)
            }
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

    private func updateThumbnail(_ image: UIImage?) {
        publish {
            self.latestThumbnail = image
        }
    }

    private func updateLastCapturedAsset(_ asset: PHAsset) {
        lastCapturedLocalIdentifier = asset.localIdentifier
        publish {
            self.lastCapturedAsset = asset
        }
    }

    private func publish(_ updates: @Sendable @escaping () -> Void) {
        if Thread.isMainThread {
            updates()
        } else {
            DispatchQueue.main.async(execute: updates)
        }
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
                let asset = try await Self.saveVideoToLibrary(from: outputFileURL)
                let thumbnail = try? await Self.makeVideoThumbnail(from: outputFileURL)
                strongSelf.updateThumbnail(thumbnail)
                strongSelf.updateLastCapturedAsset(asset)
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
}

private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
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
            if let livePhotoMovieURL, !FileManager.default.fileExists(atPath: livePhotoMovieURL.path) {
                continuation.resume(throwing: NSError(domain: "CameraAir.PhotoSave", code: 3, userInfo: [NSLocalizedDescriptionKey: "Live photo movie file not found"]))
                return
            }

            let placeholderBox = PhotoLibraryPlaceholderBox()
            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: photoData, options: nil)
                if let livePhotoMovieURL {
                    creationRequest.addResource(with: .pairedVideo, fileURL: livePhotoMovieURL, options: nil)
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
        // Disable cropping to prevent memory issues
        return data
    }

    private static func crop(_ image: UIImage, to ratio: CGFloat) -> UIImage? {
        let sourceSize = image.size
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

        let renderer = UIGraphicsImageRenderer(size: cropRect.size)
        return renderer.image { _ in
            image.draw(at: CGPoint(x: -cropRect.origin.x, y: -cropRect.origin.y))
        }
    }
}

private final class PhotoLibraryPlaceholderBox: @unchecked Sendable {
    var placeholder: PHObjectPlaceholder?
}
