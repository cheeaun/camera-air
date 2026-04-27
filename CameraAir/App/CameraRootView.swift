import SwiftUI
import Photos
import PhotosUI
import AVKit
import UIKit

@MainActor
enum CameraHaptics {
    private static weak var hostView: UIView?
    private static var activeGenerators: [UIImpactFeedbackGenerator] = []

    static func setHostView(_ view: UIView) {
        hostView = view
    }

    static func light() {
        impact(.light)
    }

    static func interface() {
        impact(.medium)
    }

    static func rigid() {
        impact(.rigid)
    }

    static func heavy() {
        impact(.heavy)
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator: UIImpactFeedbackGenerator
        if #available(iOS 17.5, *), let hostView {
            generator = UIImpactFeedbackGenerator(style: style, view: hostView)
        } else {
            generator = UIImpactFeedbackGenerator(style: style)
        }

        activeGenerators.append(generator)
        generator.prepare()
        generator.impactOccurred()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            activeGenerators.removeAll { $0 === generator }
        }
    }
}

private struct HapticHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        CameraHaptics.setHostView(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        CameraHaptics.setHostView(uiView)
    }
}

struct CameraRootView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var controller: CameraSessionController
    @State private var isSettingsExpanded = false
    @State private var isThumbnailPressed = false
    @State private var zoomSliderValue: CGFloat = 1.0

    init(controller: @autoclosure @escaping () -> CameraSessionController = CameraSessionController()) {
        _controller = StateObject(wrappedValue: controller())
    }

    var body: some View {
        ZStack {
            previewLayer
            chromeOverlay
            if controller.isCameraAccessDenied {
                permissionOverlay
            }
        }
        .background(HapticHostView().allowsHitTesting(false))
        .background(Color.black)
        .task {
            controller.prepare()
        }
        .onOpenURL { url in
            controller.handleDeepLink(url)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                controller.resumeSession()
            case .background, .inactive:
                controller.pauseSession()
            @unknown default:
                break
            }
        }
        .fullScreenCover(item: $controller.latestCaptureAsset) { asset in
            CaptureViewer(asset: asset) {
                controller.dismissLatestCapture()
            }
        }
        .sheet(isPresented: $controller.isRecentCapturesPresented) {
            RecentCapturesView(
                assets: controller.recentCaptureAssets,
                onDismiss: {
                    controller.dismissRecentCaptures()
                }
            )
        }
        .onAppear {
            zoomSliderValue = controller.settings.customZoomFactor
        }
        .onChange(of: controller.settings.customZoomFactor) { _, newValue in
            zoomSliderValue = newValue
        }
        .onChange(of: zoomSliderValue) { _, newValue in
            guard abs(controller.settings.customZoomFactor - newValue) > 0.01 else { return }
            controller.setCustomZoomFactor(newValue, animated: true)
        }
    }

    private var previewLayer: some View {
        GeometryReader { geometry in
            let screenSize = geometry.size
            let cropRatio = controller.settings.aspectRatio.cropRatio(for: controller.settings.aspectOrientation)
            let screenAspect = screenSize.width / max(screenSize.height, 1)

            let fitWidth: CGFloat
            let fitHeight: CGFloat
            if screenAspect > cropRatio {
                fitHeight = screenSize.height
                fitWidth = fitHeight * cropRatio
            } else {
                fitWidth = screenSize.width
                fitHeight = fitWidth / cropRatio
            }

            return CameraPreviewView(
                session: controller.session
            )
                .frame(width: fitWidth, height: fitHeight)
                .clipped()
                .position(x: screenSize.width / 2, y: screenSize.height / 2)
        }
        .overlay {
            LinearGradient(
                colors: [Color.black.opacity(0.68), .clear, .clear, Color.black.opacity(0.74)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(.snappy(duration: 0.28), value: controller.settings.aspectRatio)
        .ignoresSafeArea()
    }

    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 16)
            if isSettingsExpanded {
                settingsPanel
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            bottomBar
        }
        .padding(.top, 14)
        .padding(.bottom, 14)
        .animation(.snappy(duration: 0.28), value: isSettingsExpanded)
        .animation(.snappy(duration: 0.22), value: controller.mode)
        .animation(.snappy(duration: 0.22), value: controller.isRecording)
        .overlay {
            if isSettingsExpanded {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isSettingsExpanded = false
                    }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let message = controller.errorMessage ?? controller.toastMessage {
                ToastLabel(message: message)
                    .padding(.top, 84)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            FlashMenu(
                selection: controller.settings.flash,
                isEnabled: controller.capabilities.hasFlash,
                onSelect: { flash in
                    triggerInterfaceHaptic()
                    controller.setFlash(flash)
                }
            )

            AspectRatioControls(
                ratioText: controller.settings.aspectRatio.title(for: controller.settings.aspectOrientation),
                isRatioEnabled: !controller.settings.aspectOrientation.isSquare,
                orientation: controller.settings.aspectOrientation,
                onRatioTap: {
                    controller.cycleAspectRatio()
                    triggerInterfaceHaptic()
                },
                onOrientationTap: {
                    controller.cycleAspectOrientation()
                    triggerInterfaceHaptic()
                }
            )

            ToggleChip(
                accessibilityLabel: controller.settings.isExposureLocked ? "Exposure locked" : "Exposure",
                icon: "sun.max.fill",
                iconView: { isOn in
                    AnyView(ExposureLockIcon(isLocked: isOn))
                },
                isOn: controller.settings.isExposureLocked,
                isEnabled: controller.capabilities.supportsExposureLock
            ) {
                triggerInterfaceHaptic()
                controller.toggleExposureLock()
            }

            if controller.mode == .photo {
                ToggleChip(
                    accessibilityLabel: controller.settings.nightMode == .off ? "Night mode off" : "Night mode",
                    icon: "moon.dust",
                    iconView: { _ in
                        AnyView(
                            NightModeIcon(
                                mode: controller.settings.nightMode,
                                durationText: controller.nightModeMaxExposureDuration.map { Int($0.rounded()) }.map { "\($0)" }
                            )
                        )
                    },
                    isOn: controller.settings.nightMode != .off,
                    isEnabled: controller.capabilities.supportsLowLightBoost
                ) {
                    triggerInterfaceHaptic()
                    controller.cycleNightMode()
                }
                .highPriorityGesture(
                    TapGesture().onEnded {
                        guard controller.capabilities.supportsLowLightBoost else { return }
                        triggerInterfaceHaptic()
                        controller.cycleNightMode()
                    }
                )
                .contextMenu {
                    ForEach(NightModePreference.allCases) { option in
                        Button {
                            CameraHaptics.interface()
                            controller.setNightMode(option)
                        } label: {
                            if option == controller.settings.nightMode {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }

                ToggleChip(
                    accessibilityLabel: "Live photo",
                    icon: controller.settings.isLivePhotoEnabled ? "livephoto" : "livephoto.slash",
                    isOn: controller.settings.isLivePhotoEnabled,
                    isEnabled: controller.capabilities.supportsLivePhoto
                ) {
                    if controller.capabilities.supportsLivePhoto {
                        triggerInterfaceHaptic()
                        controller.toggleLivePhoto()
                    }
                }
            }

            Spacer(minLength: 0)

            ToggleChip(
                accessibilityLabel: isSettingsExpanded ? "Close settings" : "Open settings",
                icon: "gearshape",
                isOn: isSettingsExpanded,
                isEnabled: true
            ) {
                triggerInterfaceHaptic()
                isSettingsExpanded.toggle()
            }
        }
        .padding(.horizontal, 18)
    }

private var settingsPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 18) {
                // Night mode is now in the toggle chips
            }
        }
        .padding(.horizontal, 18)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            statusRow

            HStack(alignment: .center, spacing: 16) {
                thumbnailButton
                DualCaptureControl(
                    mode: controller.mode,
                    isRecording: controller.isRecording,
                    recordingDuration: controller.recordingDuration,
                    onPhotoTap: handlePhotoSnapTap,
                    onVideoTap: handleVideoSnapTap
                )
                lensButton
            }
            .padding(.horizontal, 22)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 0) {
            if controller.capabilities.supportedZoomFactors.count > 1 {
                ZoomFactorSlider(
                    value: $zoomSliderValue,
                    supportedFactors: controller.capabilities.supportedZoomFactors,
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            controller.commitZoomSelection()
                        }
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
    }

    private var thumbnailButton: some View {
        Button {
            triggerInterfaceHaptic()
            controller.openRecentCaptures()
        } label: {
            Group {
                if let image = controller.latestThumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.clear
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            }
            .modifier(ThumbnailGlassModifier())
        }
        .buttonStyle(.plain)
        .scaleEffect(isThumbnailPressed ? 0.92 : 1)
        .animation(.easeInOut(duration: 0.12), value: isThumbnailPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isThumbnailPressed = true }
                .onEnded { _ in isThumbnailPressed = false }
        )
    }

    private var lensButton: some View {
        Button {
            triggerInterfaceHaptic()
            controller.switchLens()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.system(size: 21, weight: .semibold))
                Text(controller.lens.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            }
            .modifier(ThumbnailGlassModifier())
        }
        .buttonStyle(.plain)
    }

    private func handlePhotoSnapTap() {
        guard !controller.isRecording else { return }
        CameraHaptics.light()
        if controller.mode == .photo {
            controller.performPrimaryAction()
        } else {
            controller.setMode(.photo)
        }
    }

    private func handleVideoSnapTap() {
        CameraHaptics.light()
        if controller.mode == .video {
            controller.performPrimaryAction()
        } else if !controller.isRecording {
            controller.setMode(.video)
        }
    }

    private func triggerInterfaceHaptic() {
        CameraHaptics.interface()
    }

    private var permissionOverlay: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                Label("Camera access is required", systemImage: "camera.badge.ellipsis")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))

                Text("Enable camera access in Settings to use photo and video capture.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.74))

                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.white, in: Capsule())
            }
        }
        .padding(22)
    }
}

private struct AspectRatioControls: View {
    let ratioText: String
    let isRatioEnabled: Bool
    let orientation: AspectOrientation
    let onRatioTap: () -> Void
    let onOrientationTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onRatioTap) {
                Text(ratioText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(isRatioEnabled ? 0.86 : 0.4))
                    .frame(minWidth: 48, minHeight: 38)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            .disabled(!isRatioEnabled)
            .contentShape(Capsule())
            .glassCapsule(interactive: true, isActive: false)

            Button(action: onOrientationTap) {
                AspectOrientationIcon(orientation: orientation)
                    .frame(width: 44, height: 38)
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .glassCapsule(interactive: true, isActive: true)
            .accessibilityLabel(Text("Aspect orientation \(orientation.rawValue)"))
            .animation(.snappy(duration: 0.25), value: orientation)
        }
    }
}

private struct AspectOrientationIcon: View {
    let orientation: AspectOrientation

    private var size: CGSize {
        switch orientation {
        case .portrait:
            return CGSize(width: 12, height: 18)
        case .landscape:
            return CGSize(width: 20, height: 12)
        case .square:
            return CGSize(width: 15, height: 15)
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(.white, lineWidth: 1.8)
            .frame(width: size.width, height: size.height)
    }
}

private struct DualCaptureControl: View {
    @Namespace private var activeRingNamespace

    let mode: CaptureMode
    let isRecording: Bool
    let recordingDuration: TimeInterval
    let onPhotoTap: () -> Void
    let onVideoTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            snapButton(for: .photo, action: onPhotoTap)
            snapButton(for: .video, action: onVideoTap)
        }
        .fixedSize()
    }

    private func snapButton(for buttonMode: CaptureMode, action: @escaping () -> Void) -> some View {
        let isActive = mode == buttonMode
        let isDisabledInactivePhotoWhileRecording = isRecording && buttonMode == .photo && !isActive

        return Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if isActive {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.82), lineWidth: 2)
                            .frame(width: 70, height: 70)
                            .matchedGeometryEffect(id: "active-snap-ring", in: activeRingNamespace)
                    }

                    Circle()
                        .fill(fillColor(for: buttonMode, isActive: isActive))
                        .frame(width: isActive ? 58 : 50, height: isActive ? 58 : 50)
                        .shadow(
                            color: buttonMode == .video && isActive ? Color.red.opacity(0.22) : .clear,
                            radius: 18,
                            y: 8
                        )

                    if buttonMode == .video && isActive && isRecording {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.92))
                            .frame(width: 26, height: 26)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 74, height: 74)
                .contentShape(Circle())

                VStack(spacing: 2) {
                    Text(buttonMode.title.uppercased())
                        .font(.system(size: 12, weight: isActive ? .medium : .regular, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(labelColor(isActive: isActive, isDisabled: isDisabledInactivePhotoWhileRecording))

                    if buttonMode == .video && isActive && isRecording {
                        Text(Self.formatDuration(recordingDuration))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(height: isRecording && buttonMode == .video && isActive ? 30 : 12, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabledInactivePhotoWhileRecording)
        .scaleEffect(isActive && isRecording ? 0.96 : 1)
        .animation(.snappy(duration: 0.24), value: mode)
        .animation(.snappy(duration: 0.2), value: isRecording)
        .accessibilityLabel(Text(buttonMode == .photo ? "Photo" : "Video"))
    }

    private func fillColor(for buttonMode: CaptureMode, isActive: Bool) -> Color {
        switch buttonMode {
        case .photo:
            return isActive ? Color.white.opacity(0.94) : Color.white.opacity(0.52)
        case .video:
            return isActive ? Color.red : Color(red: 0.62, green: 0.08, blue: 0.1).opacity(0.82)
        }
    }

    private func labelColor(isActive: Bool, isDisabled: Bool) -> Color {
        if isDisabled {
            return .white.opacity(0.26)
        }

        return isActive ? .white.opacity(0.84) : .white.opacity(0.38)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct ZoomFactorSlider: View {
    @Binding var value: CGFloat

    let supportedFactors: [CGFloat]
    let onEditingChanged: (Bool) -> Void
    @State private var isDragging = false
    @State private var dragX: CGFloat = 0
    @State private var dragHapticTick: Int = 0

    private let presetFactors: [CGFloat] = [0.5, 1.0, 10.0]
    private let tickCount = 40

    var body: some View {
        VStack(spacing: 1) {
            trackWithTicks
            triangleIndicator
            presetButtons
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        // Tick-based drag haptics use exponentially spaced ticks: sparse on the
        // wide-angle side, increasingly dense toward telephoto.
    }

    private var trackWithTicks: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let trackY: CGFloat = 16
            let labelY: CGFloat = isDragging ? trackY - 28 : trackY - 14

            ZStack(alignment: .top) {
                ForEach(0..<tickCount, id: \.self) { index in
                    let x = tickPosition(for: index, total: tickCount, in: width)
                    let isMajor = isTickMajor(index: index, total: tickCount)

                    Rectangle()
                        .fill(.white.opacity(isMajor ? 0.5 : 0.25))
                        .frame(width: 1, height: isMajor ? 6 : 4)
                        .position(x: x, y: trackY - (isMajor ? 3 : 2))
                }

                if isDragging || !isPresetZoom(value) {
                    Text(formattedZoomLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.0))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.28))
                        )
                        .position(x: currentLabelX(in: width), y: labelY)
                }
            }
            .animation(.easeIn(duration: 0.1), value: isDragging)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                            dragHapticTick = hapticTickIndex(for: value)
                            CameraHaptics.light()
                        }
                        dragX = gesture.location.x
                        let rawFactor = factor(for: gesture.location.x, in: width)
                        let clampedFactor = clamp(rawFactor, range: range)
                        value = clampedFactor

                        let newTick = hapticTickIndex(for: clampedFactor)
                        if newTick != dragHapticTick {
                            dragHapticTick = newTick
                            CameraHaptics.light()
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            if !isDragging {
                                dragX = 0
                            }
                        }
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 20)
    }

    private var triangleIndicator: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let indicatorX = labelX(for: value, in: width)
            Triangle()
                .fill(Color(red: 1.0, green: 0.85, blue: 0.0))
                .frame(width: 10, height: 8)
                .offset(x: indicatorX - 5, y: 0)
        }
        .frame(height: 10)
    }

    private var presetButtons: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .top) {
                ForEach(presetFactors, id: \.self) { factor in
                    let isActive = abs(factor - value) < 0.1
                    let position = labelX(for: factor, in: width)

                    Button {
                        CameraHaptics.interface()
                        withAnimation(.easeInOut(duration: 0.15)) {
                            value = factor
                            onEditingChanged(true)
                            onEditingChanged(false)
                        }
                    } label: {
                        Text(factor == 10 ? "10" : (factor == 1 ? "1" : "0.5"))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(isActive ? .black : .white)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(isActive ? Color(red: 1.0, green: 0.85, blue: 0.0) : Color.white.opacity(0.2))
                            )
                    }
                    .buttonStyle(.plain)
                    .position(x: position, y: 14)
                }
            }
        }
        .frame(height: 28)
    }

    private var formattedZoomLabel: String {
        if value >= 10 {
            return "10x"
        }
        if value >= 1 {
            return String(format: "%.1fx", value)
        }
        return String(format: "%.2fx", value)
    }

    private var range: ClosedRange<CGFloat> {
        0.5...10.0
    }

    private func isPresetZoom(_ zoom: CGFloat) -> Bool {
        presetFactors.contains { abs($0 - zoom) < 0.01 }
    }

    private func currentLabelX(in width: CGFloat) -> CGFloat {
        if isDragging, dragX > 0 {
            return min(max(dragX, 0), width)
        }
        return labelX(for: value, in: width)
    }

    private func factor(for locationX: CGFloat, in width: CGFloat) -> CGFloat {
        guard width > 0 else { return value }
        let clampedX = min(max(locationX, 0), width)
        let logLower = log(range.lowerBound)
        let logUpper = log(range.upperBound)
        let normalizedLogProgress = clampedX / width
        let logValue = logLower + (logUpper - logLower) * normalizedLogProgress
        return exp(logValue)
    }

    private func labelX(for factor: CGFloat, in width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let logLower = log(range.lowerBound)
        let logUpper = log(range.upperBound)
        let logRange = logUpper - logLower
        guard logRange > 0 else { return width / 2 }
        let logFactor = log(factor)
        let normalizedLogProgress = min(max((logFactor - logLower) / logRange, 0), 1)
        return normalizedLogProgress * width
    }

    private func factorForTick(index: Int, total: Int) -> CGFloat {
        let logLower = log(range.lowerBound)
        let logUpper = log(range.upperBound)
        let progress = CGFloat(index) / CGFloat(total - 1)
        let logProgress = sqrt(progress)
        let logFactor = logLower + (logUpper - logLower) * logProgress
        return exp(logFactor)
    }

    private func tickPosition(for index: Int, total: Int, in width: CGFloat) -> CGFloat {
        let logLower = log(range.lowerBound)
        let logUpper = log(range.upperBound)
        let progress = CGFloat(index) / CGFloat(total - 1)
        let logProgress = sqrt(progress)
        let logValue = logLower + (logUpper - logLower) * logProgress
        let normalizedLogProgress = (logValue - logLower) / (logUpper - logLower)
        return normalizedLogProgress * width
    }

    private func isTickMajor(index: Int, total: Int) -> Bool {
        let logLower = log(range.lowerBound)
        let logUpper = log(range.upperBound)
        let progress = CGFloat(index) / CGFloat(total - 1)
        let logProgress = sqrt(progress)
        let logFactor = logLower + (logUpper - logLower) * logProgress
        let factor = exp(logFactor)
        return abs(factor - 1.0) < 0.05 || index == 0 || index == total - 1
    }

    private func clamp(_ value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // Integer tick index used to drive drag haptics. This matches the visual
    // tick index used for rendering, so haptic feedback aligns with what the
    // user sees. Because the slider uses a log-like scale, this naturally
    // yields fewer haptic events at low zoom (0.5 → 1.0) and more at
    // high zoom (5 → 10).
    private func hapticTickIndex(for zoom: CGFloat) -> Int {
        let logLower = log(range.lowerBound)
        let logUpper = log(range.upperBound)
        let logFactor = log(max(zoom, range.lowerBound))
        let logProgress = (logFactor - logLower) / (logUpper - logLower)
        let progress = logProgress * logProgress  // reverse sqrt() from tickPosition
        return Int((progress * CGFloat(tickCount - 1)).rounded(.down))
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct FlashMenu: View {
    let selection: FlashPreference
    let isEnabled: Bool
    let onSelect: (FlashPreference) -> Void

    var body: some View {
        Menu {
            ForEach(FlashPreference.allCases) { option in
                Button {
                    CameraHaptics.interface()
                    onSelect(option)
                } label: {
                    if option == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Image(systemName: selection.systemImage)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.44))
                .frame(width: 44, height: 38)
        }
        .disabled(!isEnabled)
        .glassCapsule(interactive: true)
        .accessibilityLabel(Text("Flash \(selection.title)"))
    }
}



private struct NightModeIcon: View {
    let mode: NightModePreference
    var durationText: String?

    var body: some View {
        ZStack {
            Image(systemName: "moon.dust")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(mode == .off ? .white.opacity(0.5) : .white)
            modeOverlay
        }
    }

    @ViewBuilder
    private var modeOverlay: some View {
        switch mode {
        case .off:
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.65))
                    .frame(width: 14, height: 14)
                Image(systemName: "slash")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .offset(x: 5, y: -4)
        case .auto:
            EmptyView()
        case .max:
            if let durationText {
                Text(durationText)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: Capsule())
                    .offset(x: 5, y: -4)
            }
        }
    }
}

private struct ToggleChip: View {
    let accessibilityLabel: String
    let icon: String
    var iconView: ((Bool) -> AnyView)?
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    @ViewBuilder
    private var iconContent: some View {
        if let iconView = iconView {
            iconView(isOn)
        } else {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
    }

    var body: some View {
        Button(action: action) {
            iconContent
            .foregroundStyle(isEnabled ? .white : .white.opacity(0.46))
            .frame(width: 44, height: 38)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .glassCapsule(interactive: true, isActive: isOn)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}

private struct ExposureLockIcon: View {
    let isLocked: Bool

    var body: some View {
        ZStack {
            if isLocked {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Image(systemName: "lock.fill")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .offset(x: 6, y: 6)
            } else {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
        }
    }
}

private struct OptionStrip<Option: Hashable & Identifiable>: View {
    let title: String
    let options: [Option]
    let selection: Option
    let label: KeyPath<Option, String>
    let onSelect: (Option) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(options) { option in
                Button {
                    CameraHaptics.interface()
                    onSelect(option)
                } label: {
                    Text(option[keyPath: label])
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(selection == option ? .black : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(selection == option ? Color.white.opacity(0.92) : Color.white.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct StatusPill: View {
    let text: String
    let systemImage: String
    var isEnabled: Bool = true
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            if !text.isEmpty {
                Text(text)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(isEnabled ? 0.86 : 0.4))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassCapsule(interactive: true, isActive: isActive)
    }
}

private struct ToastLabel: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassCapsule(interactive: false)
    }
}

private struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassPanelModifier())
    }
}

private struct GlassPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(.regular.tint(Color.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct GlassCapsuleModifier: ViewModifier {
    let interactive: Bool
    let isActive: Bool

    func body(content: Content) -> some View {
        if interactive {
            content
                .glassEffect(.regular.tint(isActive ? Color.white.opacity(0.16) : Color.white.opacity(0.06)).interactive(), in: Capsule())
        } else {
            content
                .glassEffect(.regular.tint(isActive ? Color.white.opacity(0.16) : Color.white.opacity(0.06)), in: Capsule())
        }
    }
}

private extension View {
    func glassCapsule(interactive: Bool, isActive: Bool = false) -> some View {
        modifier(GlassCapsuleModifier(interactive: interactive, isActive: isActive))
    }
}

private enum GlassProminence {
    case regular
    case prominent
}

private struct ThumbnailGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(.regular.tint(Color.white.opacity(0.04)).interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private extension View {
    @ViewBuilder
    func glassEffectIfAvailable(prominence: GlassProminence = .regular) -> some View {
        switch prominence {
        case .regular:
            self.glassEffect(.regular.tint(Color.white.opacity(0.12)).interactive(), in: Circle())
        case .prominent:
            self.glassEffect(.regular.tint(Color.white.opacity(0.14)).interactive(), in: Circle())
        }
    }
}

extension PHAsset: @retroactive Identifiable {}

private struct RecentCapturesView: View {
    let assets: [PHAsset]
    let onDismiss: () -> Void

    @State private var isLibraryPickerPresented = false
    @State private var selectedAsset: PHAsset?

    private let gridColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    ContentUnavailableView(
                        "No Recent Captures",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Take a photo or video to see it here.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 2) {
                            ForEach(assets) { asset in
                                Button {
                                    CameraHaptics.interface()
                                    selectedAsset = asset
                                } label: {
                                    AssetGridThumbnail(asset: asset)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .background(Color.black.opacity(0.0001))
                }
            }
            .navigationTitle("Recent Captures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        CameraHaptics.interface()
                        onDismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("Done")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        CameraHaptics.interface()
                        isLibraryPickerPresented = true
                    } label: {
                        Image(systemName: "photo.stack")
                    }
                    .accessibilityLabel("Browse Photos")
                }
            }
        }
        .sheet(isPresented: $isLibraryPickerPresented) {
            LibraryPickerView { asset in
                selectedAsset = asset
            }
        }
        .fullScreenCover(item: $selectedAsset) { asset in
            CaptureViewer(asset: asset) {
                selectedAsset = nil
            }
        }
    }
}

private struct AssetGridThumbnail: View {
    let asset: PHAsset

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .overlay {
                                ProgressView()
                                    .tint(.white.opacity(0.75))
                            }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.width)
                .clipped()

                if asset.mediaType == .video {
                    Text(Self.formattedDuration(asset.duration))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                        .padding(.trailing, 5)
                        .padding(.bottom, 4)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.width)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: asset.localIdentifier) {
            image = await PhotoAssetLoader.image(
                for: asset,
                targetSize: CGSize(width: 360, height: 360),
                contentMode: .aspectFill
            )
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
        }

        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

private struct LibraryPickerView: UIViewControllerRepresentable {
    let onSelectAsset: (PHAsset) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectAsset: onSelectAsset)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onSelectAsset: (PHAsset) -> Void

        init(onSelectAsset: @escaping (PHAsset) -> Void) {
            self.onSelectAsset = onSelectAsset
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let identifier = results.first?.assetIdentifier else { return }
            let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard let asset = fetchedAssets.firstObject else { return }
            onSelectAsset(asset)
        }
    }
}

private struct CaptureViewer: View {
    let asset: PHAsset
    let onDismiss: () -> Void

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var dragOffset: CGFloat = 0

    private var preferredTargetSize: CGSize {
        CGSize(width: 2048, height: 2048) // Limit to 2048x2048 to prevent memory issues
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = max(value.translation.height, 0)
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 220 {
                    CameraHaptics.interface()
                    onDismiss()
                } else {
                    withAnimation(.snappy(duration: 0.2)) {
                        dragOffset = 0
                    }
                }
            }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(errorMessage)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else if asset.mediaType == .video {
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                } else {
                    ProgressView()
                        .tint(.white)
                }
            } else {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }

            if asset.mediaType != .video {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            CameraHaptics.interface()
                            onDismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 30))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.trailing, 18)
                    .padding(.top, 10)
                    Spacer()
                }
            }
        }
        .offset(y: dragOffset)
        .opacity(1 - min(dragOffset / 600, 0.35))
        .gesture(dismissDrag)
        .task {
            await loadAsset()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    @MainActor
    private func loadAsset() async {
        guard asset.localIdentifier.count > 0 else {
            self.errorMessage = "Invalid asset."
            return
        }

        if asset.mediaType == .video {
            let avAsset = await PhotoAssetLoader.videoAsset(for: asset)
            if let avAsset {
                do {
                    let tracks = try await avAsset.load(.tracks)
                    if !tracks.isEmpty {
                        let playerItem = AVPlayerItem(asset: avAsset)
                        self.player = AVPlayer(playerItem: playerItem)
                    } else {
                        self.errorMessage = "Unable to load video."
                    }
                } catch {
                    self.errorMessage = "Unable to load video."
                }
            } else {
                self.errorMessage = "Unable to load video."
            }
        } else {
            let result = await PhotoAssetLoader.image(for: asset, targetSize: preferredTargetSize)
            self.image = result
            if result == nil {
                self.errorMessage = "Unable to load image."
            }
        }
    }
}

private enum PhotoAssetLoader {
    static func videoAsset(for asset: PHAsset) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic

        let wrapper = await withCheckedContinuation { (continuation: CheckedContinuation<VideoAssetRequestResult, Never>) in
            let gate = PhotoRequestContinuationGate(continuation: continuation)
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                gate.resume(returning: VideoAssetRequestResult(asset: avAsset))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                gate.resume(returning: VideoAssetRequestResult(asset: nil))
            }
        }

        return wrapper.asset
    }

    static func image(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit
    ) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast

        let wrapper = await withCheckedContinuation { (continuation: CheckedContinuation<ImageRequestResult, Never>) in
            let gate = PhotoRequestContinuationGate(continuation: continuation)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                guard !isDegraded, !isCancelled else { return }
                gate.resume(returning: ImageRequestResult(image: image))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                gate.resume(returning: ImageRequestResult(image: nil))
            }
        }

        return wrapper.image
    }
}

private struct VideoAssetRequestResult: @unchecked Sendable {
    let asset: AVAsset?
}

private struct ImageRequestResult: @unchecked Sendable {
    let image: UIImage?
}

private final class PhotoRequestContinuationGate<Result: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?

    init(continuation: CheckedContinuation<Result, Never>) {
        self.continuation = continuation
    }

    func resume(returning result: Result) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
