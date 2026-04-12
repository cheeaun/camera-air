@preconcurrency import AVFoundation
@preconcurrency import Photos
import UIKit

final class CameraSessionController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var mode: CaptureMode = .photo
    @Published private(set) var lens: CameraLens = .back
    @Published private(set) var settings = CameraSettings()
    @Published private(set) var capabilities = CameraCapabilities()
    @Published private(set) var isRecording = false
    @Published private(set) var isCameraAccessDenied = false
    @Published private(set) var latestThumbnail: UIImage?
    @Published var latestCaptureAsset: PHAsset?
    @Published var errorMessage: String?

    let session = AVCaptureSession()

    private static let settingsKey = "CameraAir.Settings"

    private let sessionQueue = DispatchQueue(label: "CameraAir.SessionQueue")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

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
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let decoded = try? JSONDecoder().decode(CameraSettings.self, from: data) else { return }
        settings = decoded
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    func prepare() {
        guard !hasPrepared else { return }
        hasPrepared = true

        Task { [weak self] in
            guard let self else { return }

            let cameraGranted = await Self.requestAccess(for: .video)
            let microphoneGranted = await Self.requestAccess(for: .audio)

            self.publish {
                self.isCameraAccessDenied = !cameraGranted
            }

            guard cameraGranted else {
                self.publish {
                    self.errorMessage = "Camera access is unavailable."
                }
                return
            }

            self.configureSessionIfNeeded(includeAudio: microphoneGranted)
        }
    }

    func resumeSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
            self.startRecordingIfNeeded()
        }
    }

    func pauseSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            self.session.stopRunning()
        }
    }

    func setMode(_ mode: CaptureMode) {
        publish {
            self.mode = mode
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = mode == .photo ? .photo : .high
            self.session.commitConfiguration()
            self.updatePhotoOutputDimensions()
            self.applyCaptureSettings()
            self.startRecordingIfNeeded()
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
            guard let self else { return }
            let previousInput = self.currentVideoInput
            guard previousInput?.device.position != lens.capturePosition else { return }
            guard let device = self.discoverDevice(for: lens.capturePosition),
                  let replacementInput = try? AVCaptureDeviceInput(device: device) else {
                self.publish {
                    self.errorMessage = "This camera is not available."
                }
                return
            }

            self.session.beginConfiguration()
            if let previousInput {
                self.session.removeInput(previousInput)
            }

            if self.session.canAddInput(replacementInput) {
                self.session.addInput(replacementInput)
                self.currentVideoInput = replacementInput
            } else if let previousInput, self.session.canAddInput(previousInput) {
                self.session.addInput(previousInput)
                self.currentVideoInput = previousInput
            }
            self.session.commitConfiguration()

            self.applyCaptureSettings()
            self.refreshCapabilities()
            self.startRecordingIfNeeded()
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

        Task {
            let authorized = await Self.requestPhotoLibraryAccess(accessLevel: .readWrite)
            guard authorized else {
                self.showTransientError("Photo Library access is required to view captures.")
                self.isOpeningCapture = false
                return
            }

            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType IN %@", [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue])
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1

            let result = PHAsset.fetchAssets(with: options)

            guard let latestAsset = result.firstObject else {
                self.showTransientError("No captures found.")
                self.isOpeningCapture = false
                return
            }

            self.publish {
                self.latestCaptureAsset = latestAsset
                self.isOpeningCapture = false
            }
        }
    }

    func dismissLatestCapture() {
        publish {
            self.latestCaptureAsset = nil
        }
    }

    private func configureSessionIfNeeded(includeAudio: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            if let videoDevice = self.discoverDevice(for: self.lens.capturePosition),
               let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
               self.session.canAddInput(videoInput) {
                self.session.addInput(videoInput)
                self.currentVideoInput = videoInput
            }

            if includeAudio,
               let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               self.session.canAddInput(audioInput) {
                self.session.addInput(audioInput)
                self.currentAudioInput = audioInput
            }

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .speed
            }

            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }

            self.session.commitConfiguration()
            self.isConfigured = true
            self.updatePhotoOutputDimensions()
            self.applyCaptureSettings()
            self.session.startRunning()
            self.refreshCapabilities()
            self.startRecordingIfNeeded()
        }
    }

    private func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }

            let format: [String: Any]
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                format = [AVVideoCodecKey: AVVideoCodecType.hevc]
            } else {
                format = [AVVideoCodecKey: AVVideoCodecType.jpeg]
            }

            let photoSettings = AVCapturePhotoSettings(format: format)
            if self.capabilities.hasFlash {
                photoSettings.flashMode = self.settings.flash.avFlashMode
            }
            photoSettings.photoQualityPrioritization = .speed
            if self.photoOutput.maxPhotoDimensions.width > 0 {
                photoSettings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            }

            let livePhotoURL: URL?
            if self.photoOutput.isLivePhotoCaptureSupported && self.settings.isLivePhotoEnabled {
                livePhotoURL = Self.temporaryFileURL(pathExtension: "mov")
                photoSettings.livePhotoMovieFileURL = livePhotoURL
            } else {
                livePhotoURL = nil
            }

            let processor = PhotoCaptureProcessor(
                aspectRatio: self.settings.aspectRatio,
                livePhotoMovieURL: livePhotoURL,
                onThumbnailReady: { [weak self] image in
                    self?.updateThumbnail(image)
                },
                onError: { [weak self] message in
                    self?.showTransientError(message)
                },
                onFinish: { [weak self] in
                    self?.photoCaptureProcessor = nil
                }
            )

            self.photoCaptureProcessor = processor
            self.photoOutput.capturePhoto(with: photoSettings, delegate: processor)
        }
    }

    private func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.movieOutput.isRecording else { return }
            let outputURL = Self.temporaryFileURL(pathExtension: "mov")
            self.applyTorchState(isEnabled: self.settings.flash == .on)
            self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
            self.publish {
                self.isRecording = true
            }
        }
    }

    private func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    private func startRecordingIfNeeded() {
        guard pendingRoute?.shouldStartRecording == true, mode == .video, !movieOutput.isRecording else { return }
        pendingRoute = nil
        startRecording()
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
        let newCapabilities = CameraCapabilities(
            hasFlash: device?.hasFlash ?? false,
            supportsLivePhoto: photoOutput.isLivePhotoCaptureSupported,
            supportsLowLightBoost: device?.isLowLightBoostSupported ?? false,
            supportsExposureLock: device?.isExposureModeSupported(.locked) ?? false
        )

        publish {
            self.capabilities = newCapabilities
        }
    }

    private func discoverDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position
        ).devices.first
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

        guard error == nil else {
            showTransientError("Video capture failed.")
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        Task {
            let authorized = await Self.requestPhotoLibraryAccess()
            guard authorized else {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.showTransientError("Photo Library access is required to save video.")
                return
            }

            do {
                try await Self.saveVideoToLibrary(from: outputFileURL)
                let thumbnail = try? await Self.makeVideoThumbnail(from: outputFileURL)
                self.updateThumbnail(thumbnail)
            } catch {
                self.showTransientError("Unable to save the video.")
            }

            try? FileManager.default.removeItem(at: outputFileURL)
        }
    }

    fileprivate static func requestPhotoLibraryAccess(accessLevel: PHAccessLevel = .addOnly) async -> Bool {
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

    private static func saveVideoToLibrary(from url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
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
    private let onFinish: @Sendable () -> Void

    private var processedPhotoData: Data?

    init(
        aspectRatio: AspectRatioOption,
        livePhotoMovieURL: URL?,
        onThumbnailReady: @Sendable @escaping (UIImage?) -> Void,
        onError: @Sendable @escaping (String) -> Void,
        onFinish: @Sendable @escaping () -> Void
    ) {
        self.aspectRatio = aspectRatio
        self.livePhotoMovieURL = livePhotoMovieURL
        self.onThumbnailReady = onThumbnailReady
        self.onError = onError
        self.onFinish = onFinish
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else {
            onError("Photo capture failed.")
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            onError("Photo data is unavailable.")
            return
        }

        processedPhotoData = Self.croppedData(from: data, aspectRatio: aspectRatio)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard error == nil, let processedPhotoData else {
            onFinish()
            return
        }

        Task {
            let authorized = await CameraSessionController.requestPhotoLibraryAccess()
            guard authorized else {
                self.onError("Photo Library access is required to save photos.")
                self.cleanup()
                return
            }

            do {
                try await Self.savePhotoToLibrary(photoData: processedPhotoData, livePhotoMovieURL: livePhotoMovieURL)
                self.onThumbnailReady(UIImage(data: processedPhotoData))
            } catch {
                self.onError("Unable to save the photo.")
            }

            self.cleanup()
        }
    }

    private func cleanup() {
        if let livePhotoMovieURL {
            try? FileManager.default.removeItem(at: livePhotoMovieURL)
        }
        onFinish()
    }

    private static func savePhotoToLibrary(photoData: Data, livePhotoMovieURL: URL?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: photoData, options: nil)
                if let livePhotoMovieURL {
                    creationRequest.addResource(with: .pairedVideo, fileURL: livePhotoMovieURL, options: nil)
                }
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: NSError(domain: "CameraAir.PhotoSave", code: 1))
                }
            }
        }
    }

    private static func croppedData(from data: Data, aspectRatio: AspectRatioOption) -> Data {
        guard aspectRatio != .standard,
              let image = UIImage(data: data),
              let croppedImage = crop(image, to: aspectRatio.cropRatio),
              let croppedData = croppedImage.jpegData(compressionQuality: 0.94) else {
            return data
        }

        return croppedData
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
