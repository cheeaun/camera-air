import SwiftUI
import Photos
import AVKit
import UIKit

struct CameraRootView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var controller = CameraSessionController()
    @State private var isSettingsExpanded = false
    @State private var isThumbnailPressed = false
    @State private var zoomSliderValue: CGFloat = 1.0

    var body: some View {
        ZStack {
            previewLayer
            chromeOverlay
            if controller.isCameraAccessDenied {
                permissionOverlay
            }
        }
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
            let cropRatio = controller.settings.aspectRatio.cropRatio
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

            return CameraPreviewView(session: controller.session)
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
            Spacer(minLength: 24)
            if isSettingsExpanded {
                settingsPanel
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            bottomBar
        }
        .padding(.top, 14)
        .padding(.bottom, 20)
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
            if let message = controller.errorMessage {
                ToastLabel(message: message)
                    .padding(.top, 84)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            FlashMenu(
                selection: controller.settings.flash,
                isEnabled: controller.capabilities.hasFlash,
                onSelect: controller.setFlash
            )

            ToggleChip(
                accessibilityLabel: controller.settings.isExposureLocked ? "Exposure locked" : "Exposure",
                icon: controller.settings.isExposureLocked ? "camera.metering.center.weighted.average" : "camera.aperture",
                isOn: controller.settings.isExposureLocked,
                isEnabled: controller.capabilities.supportsExposureLock
            ) {
                controller.toggleExposureLock()
            }

            if controller.mode == .photo {
                ToggleChip(
                    accessibilityLabel: "Live photo",
                    icon: controller.settings.isLivePhotoEnabled ? "livephoto" : "livephoto.slash",
                    isOn: controller.settings.isLivePhotoEnabled,
                    isEnabled: controller.capabilities.supportsLivePhoto
                ) {
                    controller.toggleLivePhoto()
                }
            }

            Spacer(minLength: 0)

            ToggleChip(
                accessibilityLabel: isSettingsExpanded ? "Close settings" : "Open settings",
                icon: "gearshape",
                isOn: isSettingsExpanded,
                isEnabled: true
            ) {
                isSettingsExpanded.toggle()
            }
        }
        .padding(.horizontal, 18)
    }

    private var settingsPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Aspect Ratio", systemImage: "aspectratio")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))

                    OptionStrip(
                        title: "Aspect Ratio",
                        options: AspectRatioOption.allCases,
                        selection: controller.settings.aspectRatio,
                        label: \.title
                    ) { option in
                        controller.setAspectRatio(option)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Low Light Boost", systemImage: "moon.haze")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))

                    if controller.capabilities.supportsLowLightBoost {
                        OptionStrip(
                            title: "Low Light Boost",
                            options: NightModePreference.allCases,
                            selection: controller.settings.nightMode,
                            label: \.title
                        ) { option in
                            controller.setNightMode(option)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                            Text("Not supported on this device. Night Mode is handled automatically by the camera system.")
                        }
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 20) {
            statusRow
            ModeStrip(selection: controller.mode, onSelect: controller.setMode)
                .padding(.horizontal, 24)

            HStack(alignment: .center, spacing: 16) {
                thumbnailButton
                captureButton
                lensButton
            }
            .padding(.horizontal, 22)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Button {
                controller.cycleAspectRatio()
            } label: {
                StatusPill(text: controller.settings.aspectRatio.title, systemImage: "rectangle.compress.vertical")
            }
            .buttonStyle(.plain)

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

            Spacer(minLength: 0)


        }
        .padding(.horizontal, 20)
    }

    private var thumbnailButton: some View {
        Button {
            controller.openLatestCapture()
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

    private var captureButton: some View {
        Button {
            controller.performPrimaryAction()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.4), lineWidth: 2)
                    .frame(width: 84, height: 84)

                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 78, height: 78)

                if controller.mode == .video && controller.isRecording {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 32, height: 32)

                    Text(formatDuration(controller.recordingDuration))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .fill(controller.mode == .video ? Color.red : Color.white)
                        .frame(width: controller.mode == .video ? 58 : 64, height: controller.mode == .video ? 58 : 64)
                }
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(controller.isRecording ? 0.94 : 1)
        .shadow(color: controller.mode == .video ? Color.red.opacity(0.22) : .white.opacity(0.12), radius: 24, y: 12)
    }

    private var lensButton: some View {
        Button {
            controller.switchLens()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
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

private struct ModeStrip: View {
    @Namespace private var selectionNamespace

    let selection: CaptureMode
    let onSelect: (CaptureMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Text(mode.title.uppercased())
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(selection == mode ? .white : .white.opacity(0.6))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selection == mode {
                                Capsule()
                                    .fill(Color.white.opacity(0.2))
                                    .matchedGeometryEffect(id: "mode-selection", in: selectionNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background {
            Capsule()
                .fill(Color.white.opacity(0.1))
        }
        .glassEffect(.regular.tint(Color.white.opacity(0.05)), in: Capsule())
    }
}

private struct ZoomFactorSlider: View {
    @Binding var value: CGFloat

    let supportedFactors: [CGFloat]
    let onEditingChanged: (Bool) -> Void
    @State private var touchStartLocation: CGFloat?
    @State private var didDrag = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                Text(value.cameraZoomLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 38, alignment: .trailing)

                GeometryReader { geometry in
                    Slider(
                        value: Binding(
                            get: { Double(value) },
                            set: { value = CGFloat($0) }
                        ),
                        in: Double(range.lowerBound)...Double(range.upperBound),
                        step: 0.05,
                        onEditingChanged: { editing in
                            if !editing {
                                // Snap to nearest factor when editing ends
                                value = nearestFactor(to: value)
                            }
                            onEditingChanged(editing)
                        }
                    )
                    .tint(.white)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                if touchStartLocation == nil {
                                    touchStartLocation = gesture.location.x
                                }

                                let start = touchStartLocation ?? gesture.location.x
                                let movedDistance = abs(gesture.location.x - start)
                                didDrag = didDrag || movedDistance > 8

                                let rawFactor = factor(for: gesture.location.x, in: geometry.size.width)
                                value = didDrag ? stepRoundedFactor(from: rawFactor) : rawFactor
                            }
                            .onEnded { _ in
                                if didDrag {
                                    value = stepRoundedFactor(from: value)
                                } else {
                                    value = nearestNiceFactor(to: value)
                                }

                                touchStartLocation = nil
                                didDrag = false
                                onEditingChanged(false)
                            }
                    )
                }
                .frame(height: 28)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    let laidOutLabels = laidOutZoomLabels(in: geometry.size.width)
                    ForEach(Array(laidOutLabels.enumerated()), id: \.offset) { _, label in
                        Text(label.text)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(abs(label.factor - value) < 0.05 ? .white : .white.opacity(0.55))
                            .frame(width: label.width, alignment: .center)
                            .position(x: label.centerX, y: 8)
                    }
                }
            }
            .frame(height: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCapsule(interactive: true)
    }

    private var range: ClosedRange<CGFloat> {
        let sorted = supportedFactors.sorted()
        let lowerBound = sorted.first ?? 1.0
        let upperBound = sorted.last ?? lowerBound
        return lowerBound...max(upperBound, lowerBound)
    }

    private func nearestFactor(to value: CGFloat) -> CGFloat {
        supportedFactors.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }

    private func nearestNiceFactor(to value: CGFloat) -> CGFloat {
        let niceFactors: [CGFloat] = [0.5, 1.0, 2.0, 3.0, 5.0, 10.0].filter {
            $0 >= Double(range.lowerBound) && $0 <= Double(range.upperBound)
        }.map { CGFloat($0) }

        let candidates = niceFactors.isEmpty ? supportedFactors : niceFactors
        return candidates.min(by: { abs($0 - value) < abs($1 - value) }) ?? nearestFactor(to: value)
    }

    private func stepRoundedFactor(from value: CGFloat) -> CGFloat {
        let step: CGFloat = 0.05
        let quantized = (value / step).rounded() * step
        return min(max(quantized, range.lowerBound), range.upperBound)
    }

    private func factor(for locationX: CGFloat, in width: CGFloat) -> CGFloat {
        guard width > 0 else { return value }

        let clampedX = min(max(locationX, 0), width)
        let progress = clampedX / width
        return range.lowerBound + (range.upperBound - range.lowerBound) * progress
    }

    private func labelX(for factor: CGFloat, in width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }

        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return width / 2 }

        let progress = min(max((factor - range.lowerBound) / span, 0), 1)
        return progress * width
    }

    private struct ZoomLabelLayout {
        let factor: CGFloat
        let text: String
        let width: CGFloat
        let centerX: CGFloat
    }

    private func laidOutZoomLabels(in width: CGFloat) -> [ZoomLabelLayout] {
        guard width > 0 else { return [] }

        let fontCharacterWidth: CGFloat = 5.4
        let minGap: CGFloat = 6
        let maxLabels = supportedFactors.sorted().map { factor -> (factor: CGFloat, text: String, width: CGFloat, targetX: CGFloat) in
            let text = factor.cameraZoomLabel
            let labelWidth = max(18, CGFloat(text.count) * fontCharacterWidth)
            return (factor, text, labelWidth, labelX(for: factor, in: width))
        }

        var laidOut: [ZoomLabelLayout] = []
        var previousRightEdge: CGFloat = -CGFloat.greatestFiniteMagnitude

        for label in maxLabels {
            let halfWidth = label.width / 2
            var centerX = min(max(label.targetX, halfWidth), width - halfWidth)
            if centerX - halfWidth < previousRightEdge + minGap {
                centerX = previousRightEdge + minGap + halfWidth
            }
            centerX = min(centerX, width - halfWidth)
            previousRightEdge = centerX + halfWidth

            laidOut.append(
                ZoomLabelLayout(
                    factor: label.factor,
                    text: label.text,
                    width: label.width,
                    centerX: centerX
                )
            )
        }

        return laidOut
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

private struct ToggleChip: View {
    let accessibilityLabel: String
    let icon: String
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(isEnabled ? .white : .white.opacity(0.46))
            .frame(width: 44, height: 38)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .glassCapsule(interactive: true, isActive: isOn)
        .accessibilityLabel(Text(accessibilityLabel))
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
            Text(text)
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

private struct CaptureViewer: View {
    let asset: PHAsset
    let onDismiss: () -> Void

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var errorMessage: String?

    private var preferredTargetSize: CGSize {
        CGSize(width: 2048, height: 2048) // Limit to 2048x2048 to prevent memory issues
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

            VStack {
                HStack {
                    Spacer()
                    Button {
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

    static func image(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
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
                contentMode: .aspectFit,
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
