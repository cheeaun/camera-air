import SwiftUI
import UIKit

struct CameraRootView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var controller = CameraSessionController()
    @State private var isSettingsExpanded = false

    var body: some View {
        ZStack {
            previewLayer
            chromeOverlay
            if controller.isCameraAccessDenied {
                permissionOverlay
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
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
    }

    private var previewLayer: some View {
        ZStack {
            CameraPreviewView(session: controller.session)
                .overlay(alignment: .center) {
                    AspectRatioGuide(aspectRatio: controller.settings.aspectRatio)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 36)
                }

            LinearGradient(
                colors: [Color.black.opacity(0.68), .clear, .clear, Color.black.opacity(0.74)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
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

            if controller.mode == .photo {
                ToggleChip(
                    title: "Live",
                    icon: controller.settings.isLivePhotoEnabled ? "livephoto" : "livephoto.slash",
                    isOn: controller.settings.isLivePhotoEnabled,
                    isEnabled: controller.capabilities.supportsLivePhoto
                ) {
                    controller.toggleLivePhoto()
                }
            }

            ToggleChip(
                title: controller.settings.isExposureLocked ? "Locked" : "Exposure",
                icon: controller.settings.isExposureLocked ? "camera.metering.center.weighted.average" : "camera.aperture",
                isOn: controller.settings.isExposureLocked,
                isEnabled: controller.capabilities.supportsExposureLock
            ) {
                controller.toggleExposureLock()
            }

            Spacer(minLength: 0)

            ToggleChip(
                title: "Settings",
                icon: isSettingsExpanded ? "slider.horizontal.3" : "line.3.horizontal.decrease.circle",
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
                    Label("Night Mode", systemImage: "moon.haze")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))

                    OptionStrip(
                        title: "Night Mode",
                        options: NightModePreference.allCases,
                        selection: controller.settings.nightMode,
                        label: \.title
                    ) { option in
                        controller.setNightMode(option)
                    }
                    .opacity(controller.capabilities.supportsLowLightBoost ? 1 : 0.45)
                    .allowsHitTesting(controller.capabilities.supportsLowLightBoost)
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 20) {
            statusRow
            ModeStrip(selection: controller.mode, onSelect: controller.setMode)
                .padding(.horizontal, 24)

            HStack(alignment: .center, spacing: 26) {
                thumbnailButton
                captureButton
                lensButton
            }
            .padding(.horizontal, 22)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusPill(text: controller.lens.title, systemImage: controller.lens == .back ? "camera.fill" : "camera.rotate")
            StatusPill(text: controller.settings.aspectRatio.title, systemImage: "rectangle.compress.vertical")
            if controller.mode == .photo && controller.settings.isLivePhotoEnabled {
                StatusPill(text: "Live", systemImage: "livephoto")
            }
            if controller.mode == .video {
                StatusPill(text: controller.isRecording ? "Recording" : "Ready", systemImage: controller.isRecording ? "record.circle.fill" : "video.fill")
            }
        }
        .padding(.horizontal, 20)
    }

    private var thumbnailButton: some View {
        Group {
            if let image = controller.latestThumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
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
    }

    private var captureButton: some View {
        Button {
            controller.performPrimaryAction()
        } label: {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 92, height: 92)

                Circle()
                    .strokeBorder(.white.opacity(0.42), lineWidth: 2)
                    .frame(width: 86, height: 86)

                if controller.mode == .video && controller.isRecording {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 34, height: 34)
                } else {
                    Circle()
                        .fill(controller.mode == .video ? Color.red : Color.white)
                        .frame(width: controller.mode == .video ? 62 : 68, height: controller.mode == .video ? 62 : 68)
                }
            }
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
                Text("Flip")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
        }
        .buttonStyle(.plain)
        .glassCapsule(interactive: true)
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
        HStack(spacing: 6) {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Text(mode.title.uppercased())
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(selection == mode ? .black : .white.opacity(0.86))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selection == mode {
                                Capsule()
                                    .fill(Color.white.opacity(0.92))
                                    .matchedGeometryEffect(id: "mode-selection", in: selectionNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .glassCapsule(interactive: false)
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
            HStack(spacing: 8) {
                Image(systemName: selection.systemImage)
                Text(selection.title)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(isEnabled ? .white : .white.opacity(0.44))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .disabled(!isEnabled)
        .glassCapsule(interactive: true)
    }
}

private struct ToggleChip: View {
    let title: String
    let icon: String
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(isEnabled ? .white : .white.opacity(0.46))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .glassCapsule(interactive: true, isActive: isOn)
    }
}

private struct OptionStrip<Option: Hashable & Identifiable>: View {
    let title: String
    let options: [Option]
    let selection: Option
    let label: KeyPath<Option, String>
    let onSelect: (Option) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                Button {
                    onSelect(option)
                } label: {
                    Text(option[keyPath: label])
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassCapsule(interactive: false)
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

private struct AspectRatioGuide: View {
    let aspectRatio: AspectRatioOption

    var body: some View {
        GeometryReader { proxy in
            if let ratio = aspectRatio.previewRatio {
                let size = fittedSize(for: proxy.size, aspectRatio: ratio)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [7, 9]))
                    .frame(width: size.width, height: size.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
    }

    private func fittedSize(for container: CGSize, aspectRatio: CGFloat) -> CGSize {
        let containerAspect = container.width / max(container.height, 1)
        if containerAspect > aspectRatio {
            let height = container.height * 0.8
            return CGSize(width: height * aspectRatio, height: height)
        } else {
            let width = container.width * 0.9
            return CGSize(width: width, height: width / aspectRatio)
        }
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
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular.tint(Color.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

private struct GlassCapsuleModifier: ViewModifier {
    let interactive: Bool
    let isActive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if interactive {
                content
                    .glassEffect(.regular.tint(isActive ? Color.white.opacity(0.16) : Color.white.opacity(0.06)).interactive(), in: Capsule())
            } else {
                content
                    .glassEffect(.regular.tint(isActive ? Color.white.opacity(0.16) : Color.white.opacity(0.06)), in: Capsule())
            }
        } else {
            if isActive {
                content
                    .background(Color.white.opacity(0.18), in: Capsule())
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
}

private extension View {
    func glassCapsule(interactive: Bool, isActive: Bool = false) -> some View {
        modifier(GlassCapsuleModifier(interactive: interactive, isActive: isActive))
    }
}
